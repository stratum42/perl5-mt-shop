#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use IO::Socket::INET;
use Time::HiRes qw(time usleep);
use JSON::PP ();

use lib 'lib';
use lib 'xs/Shop-SSH-Crypto/blib/lib';
use lib 'xs/Shop-SSH-Crypto/blib/arch';

use MT;
use MT::Cell;
use MT::Channel;
use Shop::SSH::Crypto;
use Shop::SSH::Wire;
use Shop::DB;
use Shop::Cache::KeyDB;
use Shop::State::Inventory;
use Shop::State::EventBus;
use Shop::Domain::Cart;
use Shop::Domain::Checkout;
use Shop::Payment::Mock;
use Shop::Metrics;
use Shop::Webhook::Server;

# ---------------------------------------------------------------------------
# Worker entrypoints (defined before MT::Image::freeze())
# ---------------------------------------------------------------------------
sub metrics_inc_worker {
    my ($cells_id, $rl_id, $n_iters, $done_id) = @_;
    my $m = Shop::Metrics->attach({ cells_id => $cells_id, ratelimit_id => $rl_id });
    for (1 .. $n_iters) {
        $m->inc('ssh_connections_total', 1);
        $m->inc('ssh_egress_wire_bytes', 10);
    }
    MT::Channel->attach($done_id)->send(1);
}

sub webhook_server_worker {
    my ($db_path, $products_id, $inv_cells_id, $cells_id, $rl_id, $sessions_id, $shutdown_id, $port_ch_id, $secret) = @_;
    my $ok = eval {
        my $db      = Shop::DB->new({ driver => 'sqlite', path => $db_path });
        my $metrics = Shop::Metrics->attach({ cells_id => $cells_id, ratelimit_id => $rl_id });
        my $inv     = Shop::State::Inventory->attach({ products_id => $products_id, cells_id => $inv_cells_id }, metrics => $metrics);
        my $eb      = Shop::State::EventBus->attach({ sessions_id => $sessions_id });
        my $sd      = MT::Cell->attach($shutdown_id);

        my $srv = Shop::Webhook::Server->new(
            host           => '127.0.0.1',
            port           => 0,
            db             => $db,
            inventory      => $inv,
            metrics        => $metrics,
            event_bus      => $eb,
            webhook_secret => $secret,
            shutdown_cell  => $sd,
        );
        $srv->listen;
        MT::Channel->attach($port_ch_id)->send($srv->port);
        $srv->run;
        1;
    };
    if (!$ok) {
        warn "webhook_server_worker died: $@\n";
        MT::Channel->attach($port_ch_id)->send(-1);
    }
}

# Helper HTTP/1.1 client for live Webhook::Server tests
sub http_req {
    my ($port, $method, $path, $headers, $body) = @_;
    $headers ||= {};
    $body    //= '';
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 3,
    ) or die "HTTP connect to 127.0.0.1:$port failed: $!\n";
    binmode($sock);

    my $req = "$method $path HTTP/1.1\r\n"
            . "Host: 127.0.0.1:$port\r\n"
            . "Connection: close\r\n";
    for my $k (keys %$headers) {
        $req .= "$k: $headers->{$k}\r\n";
    }
    $req .= "Content-Length: " . length($body) . "\r\n\r\n" . $body;
    print $sock $req;

    local $/;
    my $raw = <$sock> // '';
    close $sock;

    my ($hdr, $resp_body) = split /\r\n\r\n/, $raw, 2;
    my ($status) = ($hdr // '') =~ m{^HTTP/\d+\.\d+\s+(\d+)};
    return (int($status // 0), $resp_body // '');
}

# ---------------------------------------------------------------------------
# Setup shared state BEFORE MT::Image::freeze()
# ---------------------------------------------------------------------------
my ($fh, $db_path) = tempfile(SUFFIX => '.db', UNLINK => 1);
close $fh;

my $db = Shop::DB->new({ driver => 'sqlite', path => $db_path });
ok($db->init_schema('sql/schema_sqlite.sql', 'sql/seed.sql'), 'SQLite schema + seed initialized');

my $metrics = Shop::Metrics->new;
my $inv     = Shop::State::Inventory->new(metrics => $metrics);
is($inv->load_from_db($db), 12, 'Loaded 12 products into Inventory');

my $eb    = Shop::State::EventBus->new;
my $inbox = $eb->register_session('sess-buyer', { user_fp => 'SHA256:buyer1', username => 'alice' });

my $shutdown = MT::Cell->new(0);
my $port_ch  = MT::Channel->new(4);
my $done_ch  = MT::Channel->new(8);

my $inv_ids = $inv->state_ids;
my $m_ids   = $metrics->state_ids;
my $eb_ids  = $eb->state_ids;
my $secret  = 'whsec_test_stripe_secret_123';

# Freeze image for multi-worker tests
Shop::Webhook::Server::prepare_for_freeze();
MT::Image::freeze();

# ===========================================================================
# 1. Cross-Worker Shop::Metrics Atomic Counters, Prometheus Output, Rate Limit
# ===========================================================================
$metrics->inc('ssh_kex_pq_total', 3);
$metrics->set('ssh_active_sessions', 2);

my @mworkers;
for (1 .. 4) {
    push @mworkers, MT::Worker::spawn(
        'main::metrics_inc_worker',
        $m_ids->{cells_id},
        $m_ids->{ratelimit_id},
        250,
        $done_ch->id,
    );
}
MT::Worker::join($_) for @mworkers;
$done_ch->recv for (1 .. 4);

is($metrics->get('ssh_connections_total'), 1000, '4 workers x 250 atomic inc == 1000');
is($metrics->get('ssh_egress_wire_bytes'), 10000, '4 workers x 250 x 10 wire bytes == 10000');
is($metrics->get('ssh_kex_pq_total'), 3, 'ssh_kex_pq_total == 3');
is($metrics->get('ssh_active_sessions'), 2, 'ssh_active_sessions == 2');

my $prom = $metrics->prometheus_text;
like($prom, qr/# TYPE ssh_kex_pq_total counter\nssh_kex_pq_total 3\n/, 'Prometheus text includes ssh_kex_pq_total');
like($prom, qr/# TYPE ssh_active_sessions gauge\nssh_active_sessions 2\n/, 'Prometheus text includes ssh_active_sessions gauge');
like($prom, qr/ssh_connections_total 1000\n/, 'Prometheus text includes cross-worker ssh_connections_total');

# Per-IP lock-free rate limiter
my ($a1, $r1) = $metrics->check_rate_limit('10.0.0.42', 3);
is($a1, 1, 'rate limit call 1 allowed');
is($r1, 2, 'rate limit remaining == 2');
ok($metrics->check_rate_limit('10.0.0.42', 3), 'rate limit call 2 allowed');
ok($metrics->check_rate_limit('10.0.0.42', 3), 'rate limit call 3 allowed');
my ($a4, $r4) = $metrics->check_rate_limit('10.0.0.42', 3);
is($a4, 0, 'rate limit call 4 blocked');
is($r4, 0, 'rate limit remaining == 0 when blocked');
is($metrics->get('ssh_auth_blocked_total'), 1, 'blocked request incremented ssh_auth_blocked_total');

# ===========================================================================
# 2. Ed25519-Signed Cryptographic Order Receipts & Tamper Rejection
# ===========================================================================
my ($sk64, $pk32) = Shop::SSH::Crypto::ed25519_keypair();
my $hostkey = { type => 'ssh-ed25519', sk => $sk64, pk => $pk32 };

my $user = $db->upsert_user({
    fingerprint => 'SHA256:buyer1',
    username    => 'alice',
    email       => 'alice@example.com',
    pubkey_type => 'ssh-ed25519',
});
my $addr = $db->save_address({
    user_fp     => 'SHA256:buyer1',
    label       => 'Home',
    recipient   => 'Alice',
    line1       => '42 Quantum Way',
    city        => 'Austin',
    state       => 'TX',
    postal_code => '78701',
    country     => 'US',
    is_default  => 1,
});

my $co = Shop::Domain::Checkout->new(
    db        => $db,
    inventory => $inv,
    event_bus => $eb,
    payment   => Shop::Payment::Mock->new,
    hostkey   => $hostkey,
    metrics   => $metrics,
);

my $cart = Shop::Domain::Cart->new(user_fp => 'SHA256:buyer1', inventory => $inv, db => $db);
ok($cart->add('VT-220', 1)->{ok}, 'added VT-220 to cart');
is($metrics->get('inventory_cas_ok_total'), 1, 'Inventory CAS reserve incremented inventory_cas_ok_total');

my $placed = $co->place_order(cart => $cart, user => $user, address => $addr, payment_token => 'tok_visa');
ok($placed->{ok}, 'place_order succeeded');
my $ord = $placed->{order};
like($ord->{receipt_hash}, qr/^[0-9a-f]{64}$/, 'order has 64-hex SHA-256 receipt_hash');
ok(length($ord->{receipt_sig}) > 60, 'order has base64 Ed25519 receipt_sig');
ok(Shop::Domain::Checkout::verify_receipt($ord, $pk32), 'offline Ed25519 receipt verification PASSED with raw pk32');
ok(Shop::Domain::Checkout->verify_receipt($ord, $hostkey), 'offline Ed25519 receipt verification PASSED with hostkey hashref');

# Tamper rejection tests
my %tampered_total = %$ord;
$tampered_total{total} = '0.01';
ok(!Shop::Domain::Checkout::verify_receipt(\%tampered_total, $pk32), 'tampered total REJECTED');

my %tampered_addr = %$ord;
$tampered_addr{shipping_address} = '999 Attacker Ave';
ok(!Shop::Domain::Checkout::verify_receipt(\%tampered_addr, $pk32), 'tampered shipping_address REJECTED');

my ($other_sk, $other_pk) = Shop::SSH::Crypto::ed25519_keypair();
ok(!Shop::Domain::Checkout::verify_receipt($ord, $other_pk), 'wrong hostkey public key REJECTED');

# ===========================================================================
# 3. 1-Keystroke quick_reorder with Saved Payment Method + Default Address
# ===========================================================================
my $no_pm = $co->quick_reorder(user_fp => 'SHA256:buyer1', sku => 'AC-MUG', qty => 1);
ok(!$no_pm->{ok}, 'quick_reorder fails gracefully when no saved payment method');
like($no_pm->{error}, qr/payment method/i, 'clear error for missing payment method');

my $u_saved = $db->save_user_payment_method('SHA256:buyer1', 'pm_card_visa_4242', '4242', 'cus_test_123');
is($u_saved->{default_payment_method}, 'pm_card_visa_4242', 'saved default_payment_method persisted');
is($u_saved->{default_payment_last4},  '4242', 'saved default_payment_last4 persisted');
is($u_saved->{stripe_customer_id},     'cus_test_123', 'saved stripe_customer_id persisted');

my $qr_res = $co->quick_reorder(user_fp => 'SHA256:buyer1', sku => 'AC-MUG', qty => 2);
ok($qr_res->{ok}, '1-keystroke quick_reorder succeeded');
is($qr_res->{order}{status}, 'paid', 'quick_reorder order status is paid');
is($qr_res->{order}{items}[0]{sku}, 'AC-MUG', 'quick_reorder item SKU matches');
is($qr_res->{order}{items}[0]{qty}, 2, 'quick_reorder item qty == 2');
ok(Shop::Domain::Checkout::verify_receipt($qr_res->{order}, $pk32), 'quick_reorder order has valid Ed25519 receipt');
is($metrics->get('orders_total'), 2, 'orders_total metric == 2');

# Drain prior order_placed events from buyer inbox
$eb->poll_inbox($inbox);

# ===========================================================================
# 4. Live In-Process Shop::Webhook::Server in MT::Worker
# ===========================================================================
# Create a pending order awaiting Stripe webhook confirmation
my $pending_ord = $db->create_order(
    {
        id               => 'ORD-PENDING-9999',
        user_fp          => 'SHA256:buyer1',
        username         => 'alice',
        status           => 'pending',
        subtotal         => '429.00',
        discount         => '0.00',
        tax              => '35.39',
        shipping         => '0.00',
        total            => '464.39',
        promo_code       => '',
        payment_method   => 'stripe',
        payment_ref      => 'cs_test_webhook_9999',
        shipping_address => 'Alice | 42 Quantum Way',
    },
    [
        { sku => 'VT-220', name => 'DEC VT220', qty => 1, unit_price => '429.00', line_total => '429.00' },
    ],
);
is($pending_ord->{status}, 'pending', 'pending order created in DB');

my $wh_worker = MT::Worker::spawn(
    'main::webhook_server_worker',
    $db_path,
    $inv_ids->{products_id},
    $inv_ids->{cells_id},
    $m_ids->{cells_id},
    $m_ids->{ratelimit_id},
    $eb_ids->{sessions_id},
    $shutdown->id,
    $port_ch->id,
    $secret,
);
my $ops_port = $port_ch->recv;
ok($ops_port > 0, "Webhook::Server listening on 127.0.0.1:$ops_port in MT::Worker");

# GET /healthz
my ($st_h, $body_h) = http_req($ops_port, 'GET', '/healthz');
is($st_h, 200, 'GET /healthz returned 200 OK');
my $health_j = JSON::PP->new->utf8(1)->decode($body_h);
ok($health_j->{ok}, 'GET /healthz ok is true');
is($health_j->{engine},  'mojolicious-mt',   'GET /healthz reports mojolicious-mt engine');
is($health_j->{reactor}, 'Mojo::Reactor::MT', 'GET /healthz reports Mojo::Reactor::MT');
ok($health_j->{accel},   'GET /healthz reports Mojo::MT::Accel active');

# GET /api/catalog
my ($st_cat, $body_cat) = http_req($ops_port, 'GET', '/api/catalog');
is($st_cat, 200, 'GET /api/catalog returned 200 OK');
my $cat_j = JSON::PP->new->utf8(1)->decode($body_cat);
ok($cat_j->{ok}, 'GET /api/catalog ok is true');
cmp_ok($cat_j->{count}, '>=', 12, 'GET /api/catalog returned >= 12 products');
ok((grep { ($_->{sku} // '') eq 'VT-220' } @{ $cat_j->{items} }), 'GET /api/catalog contains VT-220');

my ($st_cat_q, $body_cat_q) = http_req($ops_port, 'GET', '/api/catalog?q=VT-220');
is($st_cat_q, 200, 'GET /api/catalog?q=VT-220 returned 200 OK');
my $cat_q = JSON::PP->new->utf8(1)->decode($body_cat_q);
is($cat_q->{count}, 1, 'GET /api/catalog?q=VT-220 filtered to 1 item');
is($cat_q->{items}[0]{sku}, 'VT-220', 'GET /api/catalog?q=VT-220 returned VT-220');

# GET /metrics
my ($st_m, $body_m) = http_req($ops_port, 'GET', '/metrics');
is($st_m, 200, 'GET /metrics returned 200 OK');
like($body_m, qr/ssh_kex_pq_total 3\n/, 'GET /metrics serves live Shop::Metrics Prometheus counters');

# POST /webhooks/stripe with BAD signature -> rejected
my $wh_payload = JSON::PP->new->utf8(1)->encode({
    id   => 'evt_test_001',
    type => 'checkout.session.completed',
    data => {
        object => {
            id                  => 'cs_test_webhook_9999',
            client_reference_id => 'ORD-PENDING-9999',
            payment_status      => 'paid',
        },
    },
});

my ($st_bad, $body_bad) = http_req(
    $ops_port, 'POST', '/webhooks/stripe',
    { 'Content-Type' => 'application/json', 'Stripe-Signature' => 't=' . time() . ',v1=' . ('0' x 64) },
    $wh_payload,
);
is($st_bad, 400, 'POST /webhooks/stripe with bad signature rejected with 400');
is($db->get_order('ORD-PENDING-9999')->{status}, 'pending', 'order remains pending after bad signature');

# POST /webhooks/stripe with VALID HMAC-SHA256 signature -> accepted + <50ms EventBus push!
my $valid_sig = Shop::Webhook::Server::sign_stripe_payload($wh_payload, $secret);
my $t_wh_start = time();
my ($st_ok, $body_ok) = http_req(
    $ops_port, 'POST', '/webhooks/stripe',
    { 'Content-Type' => 'application/json', 'Stripe-Signature' => $valid_sig },
    $wh_payload,
);
is($st_ok, 200, 'POST /webhooks/stripe with valid HMAC-SHA256 signature returned 200 OK');

my $paid_ev;
my $deadline = $t_wh_start + 0.5;
while (time() < $deadline) {
    my $evs = $eb->poll_inbox($inbox);
    for my $e (@$evs) {
        if (($e->{type} // '') eq 'payment_confirmed') {
            $paid_ev = $e;
            last;
        }
    }
    last if $paid_ev;
    usleep(1000);
}
my $push_ms = (time() - $t_wh_start) * 1000;

ok($paid_ev, 'EventBus delivered payment_confirmed event to buyer inbox');
is($paid_ev->{order_id}, 'ORD-PENDING-9999', 'payment_confirmed order_id matches');
is($paid_ev->{order_number}, 'ORD-PENDING-9999', 'payment_confirmed order_number matches');
is($paid_ev->{total}, '464.39', 'payment_confirmed total matches');
cmp_ok($push_ms, '<', 50, sprintf('EventBus push latency %.2fms < 50ms', $push_ms));

is($db->get_order('ORD-PENDING-9999')->{status}, 'paid', 'DB order status updated to paid by webhook');
is($metrics->get('webhooks_processed_total'), 1, 'webhooks_processed_total incremented to 1');

# Duplicate webhook with same event ID -> idempotent 200, no double increment
my ($st_dup, $body_dup) = http_req(
    $ops_port, 'POST', '/webhooks/stripe',
    { 'Content-Type' => 'application/json', 'Stripe-Signature' => $valid_sig },
    $wh_payload,
);
is($st_dup, 200, 'duplicate webhook returned 200 OK');
like($body_dup, qr/"duplicate"\s*:\s*true/, 'duplicate webhook flagged as duplicate');
is($metrics->get('webhooks_processed_total'), 1, 'duplicate webhook did not double-increment counter');

# Clean shutdown of webhook worker
$shutdown->set(1);
MT::Worker::join($wh_worker);
pass('Webhook::Server worker shut down cleanly');

# ===========================================================================
# 5. Optional Live KeyDB Session Resume Test (when KeyDB reachable)
# ===========================================================================
SKIP: {
    my $kdb = Shop::Cache::KeyDB->new(
        host    => $ENV{KEYDB_HOST} // '127.0.0.1',
        port    => $ENV{KEYDB_PORT} // 6380,
        timeout => 1,
    );
    skip 'KeyDB not reachable on KEYDB_PORT (default 6380)', 4 unless $kdb->ping;

    my $state = { view => 'catalog', selected_sku => 'VT-220', promo => 'PERLMT20' };
    ok($kdb->save_session_state('SHA256:buyer1', $state, 60), 'KeyDB save_session_state succeeded');
    my $loaded = $kdb->load_session_state('SHA256:buyer1');
    is($loaded->{view}, 'catalog', 'KeyDB load_session_state restored view');
    is($loaded->{selected_sku}, 'VT-220', 'KeyDB load_session_state restored selected_sku');
    is($loaded->{promo}, 'PERLMT20', 'KeyDB load_session_state restored promo');
    $kdb->clear_session_state('SHA256:buyer1');
}

done_testing;
