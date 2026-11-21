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
use MT::Decimal;
use Shop::DB;
use Shop::State::Inventory;
use Shop::State::EventBus;
use Shop::Domain::Pricing;
use Shop::Domain::Cart;
use Shop::Domain::Checkout;
use Shop::Domain::Membership;
use Shop::Domain::Subscription;
use Shop::Payment::Mock;
use Shop::Metrics;
use Shop::Webhook::Server;

# ---------------------------------------------------------------------------
# Worker entrypoint (defined before MT::Image::freeze())
# ---------------------------------------------------------------------------
sub ops_worker {
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
        warn "ops_worker died: $@\n";
        MT::Channel->attach($port_ch_id)->send(-1);
    }
}

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

sub wait_for_event {
    my ($eb, $inbox, $type, $timeout_sec) = @_;
    $timeout_sec //= 0.5;
    my $deadline = time() + $timeout_sec;
    while (time() < $deadline) {
        my $evs = $eb->poll_inbox($inbox);
        for my $e (@$evs) {
            return $e if ($e->{type} // '') eq $type;
        }
        usleep(1000);
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Setup shared state before MT::Image::freeze()
# ---------------------------------------------------------------------------
my ($fh, $db_path) = tempfile(SUFFIX => '.db', UNLINK => 1);
close $fh;

my $db = Shop::DB->new({ driver => 'sqlite', path => $db_path });
ok($db->init_schema('sql/schema_sqlite.sql', 'sql/seed.sql'), 'SQLite schema + seed initialized');

my $metrics  = Shop::Metrics->new;
my $inv      = Shop::State::Inventory->new(metrics => $metrics);
is($inv->load_from_db($db), 12, 'Loaded 12 products into Inventory');

my $eb       = Shop::State::EventBus->new;
my $fp_alice = 'SHA256:member_alice';
my $fp_bob   = 'SHA256:member_bob';
my $inbox    = $eb->register_session('sess-alice', { user_fp => $fp_alice, username => 'alice' });

my $shutdown = MT::Cell->new(0);
my $port_ch  = MT::Channel->new(4);
my $inv_ids  = $inv->state_ids;
my $m_ids    = $metrics->state_ids;
my $eb_ids   = $eb->state_ids;
my $secret   = 'whsec_test_subs_secret';

Shop::Webhook::Server::prepare_for_freeze();
MT::Image::freeze();

# Seed users, default address, and saved payment method
my $alice = $db->upsert_user({
    fingerprint => $fp_alice,
    username    => 'alice',
    email       => 'alice@example.com',
    pubkey_type => 'ssh-ed25519',
});
$db->save_user_payment_method($fp_alice, 'pm_card_visa_4242', '4242', 'cus_alice_1');
my $alice_addr = $db->save_address({
    user_fp     => $fp_alice,
    label       => 'Home',
    recipient   => 'Alice',
    line1       => '100 Main St',
    city        => 'Austin',
    state       => 'TX',
    postal_code => '78701',
    country     => 'US',
    is_default  => 1,
});

$db->upsert_user({
    fingerprint => $fp_bob,
    username    => 'bob',
    email       => 'bob@example.com',
    pubkey_type => 'ssh-ed25519',
});

my $mem = Shop::Domain::Membership->new(
    db        => $db,
    event_bus => $eb,
    metrics   => $metrics,
);

my $co = Shop::Domain::Checkout->new(
    db         => $db,
    inventory  => $inv,
    event_bus  => $eb,
    payment    => Shop::Payment::Mock->new,
    metrics    => $metrics,
    membership => $mem,
);

my $sub_mgr = Shop::Domain::Subscription->new(
    db         => $db,
    inventory  => $inv,
    checkout   => $co,
    membership => $mem,
    event_bus  => $eb,
    metrics    => $metrics,
);

# ===========================================================================
# 1. Membership Tiers, Enrollment, Benefits, and Cancellation
# ===========================================================================
my $tiers = $mem->list_tiers;
is(scalar(@$tiers), 3, 'list_tiers returns 3 seeded membership tiers');
is_deeply([ map { $_->{code} } @$tiers ], [ 'FREE', 'PRO', 'FOUNDER' ], 'tiers ordered by price: FREE, PRO, FOUNDER');

my $b0 = $mem->benefits($fp_alice);
is($b0->{tier_code}, 'FREE', 'un-enrolled user defaults to FREE tier');
is($b0->{status}, 'NONE', 'un-enrolled status is NONE');
ok(ref($b0->{discount_pct}) && $b0->{discount_pct}->isa('MT::Decimal'), 'discount_pct is MT::Decimal');
is("$b0->{discount_pct}", '0.00', 'default discount_pct is 0.00');
is($b0->{free_shipping}, 0, 'default free_shipping is 0');

my $bad_enroll = $mem->enroll(user_fp => $fp_alice, tier_code => 'PLATINUM');
ok(!$bad_enroll->{ok}, 'unknown tier rejected');

my $en_pro = $mem->enroll(user_fp => $fp_alice, tier_code => 'PRO', stripe_sub_id => 'sub_stripe_pro_1');
ok($en_pro->{ok}, 'enrolled alice in PRO');
is($en_pro->{benefits}{tier_code}, 'PRO', 'PRO benefits tier_code');
is("$en_pro->{benefits}{discount_pct}", '10.00', 'PRO discount_pct is 10.00');
is($en_pro->{benefits}{free_shipping}, 1, 'PRO has free_shipping');
is($en_pro->{benefits}{priority_fulfillment}, 1, 'PRO has priority_fulfillment');
is($en_pro->{benefits}{status}, 'ACTIVE', 'PRO status is ACTIVE');

my $ev_mem = wait_for_event($eb, $inbox, 'membership_updated', 0.5);
ok($ev_mem, 'EventBus delivered membership_updated on enroll');
is($ev_mem->{tier_code}, 'PRO', 'membership_updated tier_code is PRO');
is($ev_mem->{status}, 'ACTIVE', 'membership_updated status is ACTIVE');

# ===========================================================================
# 2. Automatic MT::Decimal Member Discount + Free Shipping in Pricing & Checkout
# ===========================================================================
# Order under $75: 2 x AC-MUG ($19.95) = $39.90
# Without membership: discount 0.00, shipping 7.95, tax 3.29, total 51.14
my $p_nomem = Shop::Domain::Pricing::calculate([
    { sku => 'AC-MUG', name => 'Mug', price => '19.95', qty => 2 },
]);
is("$p_nomem->{discount}", '0.00', 'no-membership discount is 0.00');
is("$p_nomem->{shipping}", '7.95', 'no-membership shipping is 7.95');
is("$p_nomem->{total}",    '51.14', 'no-membership total unchanged at 51.14');

# With PRO membership (10% off + free shipping):
# subtotal = 39.90, discount = 3.99, taxable = 35.91, tax = 35.91 * 0.0825 = 2.962575 -> 2.96, shipping = 0.00, total = 38.87
my $b_pro = $mem->benefits($fp_alice);
my $p_pro = Shop::Domain::Pricing::calculate(
    [{ sku => 'AC-MUG', name => 'Mug', price => '19.95', qty => 2 }],
    membership => $b_pro,
);
is("$p_pro->{subtotal}",        '39.90', 'PRO subtotal 39.90');
is("$p_pro->{discount}",        '3.99',  'PRO 10% discount = 3.99 exact MT::Decimal');
is("$p_pro->{member_discount}", '3.99',  'member_discount = 3.99');
is("$p_pro->{tax}",             '2.96',  'PRO tax on 35.91 = 2.96');
is("$p_pro->{shipping}",        '0.00',  'PRO free shipping overrides 7.95');
is($p_pro->{free_shipping},     1,       'PRO free_shipping flag = 1');
is("$p_pro->{total}",           '38.87', 'PRO total = 38.87');

# Checkout place_order automatically applies alice's active PRO benefits
my $cart = Shop::Domain::Cart->new(user_fp => $fp_alice, inventory => $inv, db => $db);
ok($cart->add('AC-MUG', 2)->{ok}, 'added 2x AC-MUG to cart');
my $ord_pro = $co->place_order(cart => $cart, user => $alice, address => $alice_addr, payment_token => 'tok_visa');
ok($ord_pro->{ok}, 'place_order with PRO membership succeeded');
is($ord_pro->{order}{discount}, '3.99',  'persisted order discount reflects PRO 10%');
is($ord_pro->{order}{shipping}, '0.00',  'persisted order shipping is 0.00 for PRO');
is($ord_pro->{order}{total},    '38.87', 'persisted order total is 38.87 for PRO');

# Cancel membership -> benefits drop back to 0% and no free shipping
my $can_mem = $mem->cancel(user_fp => $fp_alice);
ok($can_mem->{ok}, 'canceled alice membership');
is($can_mem->{benefits}{status}, 'CANCELED', 'canceled status reported');
is("$can_mem->{benefits}{discount_pct}", '0.00', 'canceled discount_pct is 0.00');
is($can_mem->{benefits}{free_shipping}, 0, 'canceled free_shipping is 0');

my $ev_can = wait_for_event($eb, $inbox, 'membership_updated', 0.5);
ok($ev_can && $ev_can->{status} eq 'CANCELED', 'EventBus delivered CANCELED membership_updated');

# Upgrade to FOUNDER (20% off + free shipping) for subscription tests
my $en_fnd = $mem->enroll(user_fp => $fp_alice, tier_code => 'FOUNDER', stripe_sub_id => 'sub_stripe_fnd_1');
ok($en_fnd->{ok}, 'enrolled alice in FOUNDER');
is("$en_fnd->{benefits}{discount_pct}", '20.00', 'FOUNDER discount_pct is 20.00');

# Drain prior events
$eb->poll_inbox($inbox);

# ===========================================================================
# 3. Recurring Subscriptions: Create, Pause, Resume, Skip, Ownership, Cancel
# ===========================================================================
# AC-MUG base price is 19.95; with FOUNDER 20% off -> discount 3.99 -> unit_price 15.96
my $c_sub = $sub_mgr->create(
    user_fp       => $fp_alice,
    sku           => 'AC-MUG',
    qty           => 2,
    interval_days => 30,
    next_bill_at  => '2026-05-01 12:00:00',
    stripe_sub_id => 'sub_stripe_recur_1',
);
ok($c_sub->{ok}, 'created recurring subscription');
my $sub1 = $c_sub->{subscription};
like($sub1->{id}, qr/^SUB-/, 'subscription id generated');
is($sub1->{unit_price}, '15.96', 'subscription unit_price reflects FOUNDER 20% discount (19.95 - 3.99 = 15.96)');
is($sub1->{status}, 'ACTIVE', 'new subscription is ACTIVE');
is($sub1->{next_bill_at}, '2026-05-01 12:00:00', 'next_bill_at stored');

# Wrong user cannot pause
my $bad_pause = $sub_mgr->pause($sub1->{id}, $fp_bob);
ok(!$bad_pause->{ok}, 'non-owner cannot pause subscription');

my $p_res = $sub_mgr->pause($sub1->{id}, $fp_alice);
ok($p_res->{ok}, 'owner paused subscription');
is($p_res->{subscription}{status}, 'PAUSED', 'status is PAUSED');

my $r_res = $sub_mgr->resume($sub1->{id}, $fp_alice);
ok($r_res->{ok}, 'owner resumed subscription');
is($r_res->{subscription}{status}, 'ACTIVE', 'status is ACTIVE after resume');

my $sk_res = $sub_mgr->skip_next($sub1->{id}, $fp_alice);
ok($sk_res->{ok}, 'owner skipped next delivery');
is($sk_res->{subscription}{next_bill_at}, '2026-05-31 12:00:00', 'skip_next advanced next_bill_at by 30 days');

my $list_a = $sub_mgr->list_user($fp_alice);
is(scalar(@$list_a), 1, 'list_user returns 1 subscription for alice');
is(scalar(@{ $sub_mgr->list_user($fp_bob) }), 0, 'list_user returns 0 for bob');

# ===========================================================================
# 4. MRR Summary Calculation (MT::Decimal exact)
# ===========================================================================
# Active members: 1 (FOUNDER = 24.99)
# Active subscriptions: 1 (AC-MUG, qty=2, unit_price=15.96, interval=30d -> 31.92)
# Total MRR = 24.99 + 31.92 = 56.91
my $mrr = $sub_mgr->mrr_summary;
is($mrr->{active_members},       1,       'MRR active_members == 1');
is($mrr->{active_subscriptions}, 1,       'MRR active_subscriptions == 1');
is("$mrr->{membership_mrr}",     '24.99', 'MRR membership_mrr == 24.99');
is("$mrr->{subscription_mrr}",   '31.92', 'MRR subscription_mrr == 31.92');
is("$mrr->{total_mrr}",          '56.91', 'MRR total_mrr == 56.91');

# ===========================================================================
# 5. Idempotent process_due_renewals (2nd run must NOT double-bill)
# ===========================================================================
my $due_ts = '2026-05-31 12:00:00';
my $orders_before = scalar(@{ $db->list_orders($fp_alice) });

my $ren1 = $sub_mgr->process_due_renewals(as_of => $due_ts);
ok($ren1->{ok}, 'first process_due_renewals succeeded');
is(scalar(@{ $ren1->{renewed} }), 1, 'first run renewed 1 subscription');
is(scalar(@{ $ren1->{skipped} }), 0, 'first run skipped 0');
is(scalar(@{ $ren1->{failed} }),  0, 'first run failed 0');

my $ord_id_1 = $ren1->{renewed}[0]{order_id};
ok(defined $ord_id_1 && length $ord_id_1, 'renewal created order ' . ($ord_id_1 // ''));
is($ren1->{renewed}[0]{next_bill_at}, '2026-06-30 12:00:00', 'next_bill_at advanced by 30d');

my $sub_after = $db->get_subscription($sub1->{id});
is($sub_after->{last_order_id}, $ord_id_1, 'last_order_id persisted on subscription');
is($sub_after->{next_bill_at}, '2026-06-30 12:00:00', 'DB next_bill_at updated');

my $ev_ren = wait_for_event($eb, $inbox, 'subscription_renewed', 0.5);
ok($ev_ren, 'EventBus delivered subscription_renewed to alice');
is($ev_ren->{sub_id},   $sub1->{id}, 'subscription_renewed sub_id matches');
is($ev_ren->{order_id}, $ord_id_1,   'subscription_renewed order_id matches');
is($ev_ren->{sku},      'AC-MUG',    'subscription_renewed sku matches');

# 2nd run at same as_of -> 0 due, 0 renewed
my $ren2 = $sub_mgr->process_due_renewals(as_of => $due_ts);
is(scalar(@{ $ren2->{renewed} }), 0, '2nd run at same as_of does not double-bill');

# Even if DB next_bill_at were rolled back to the same cycle timestamp, idempotency lock blocks double-billing
$db->update_subscription($sub1->{id}, next_bill_at => $due_ts);
my $ren3 = $sub_mgr->process_due_renewals(as_of => $due_ts);
is(scalar(@{ $ren3->{renewed} }), 0, 'idempotent lock blocks double-billing for same cycle');
is(scalar(@{ $ren3->{skipped} }), 1, 'same cycle recorded in skipped');

my $orders_after = scalar(@{ $db->list_orders($fp_alice) });
is($orders_after, $orders_before + 1, 'exactly 1 renewal order created in DB');

# Cancel a separate subscription and verify cancel works
my $c_sub2 = $sub_mgr->create(user_fp => $fp_alice, sku => 'AC-MUG', qty => 1, interval_days => 14);
ok($c_sub2->{ok}, 'created second subscription');
my $can_sub2 = $sub_mgr->cancel($c_sub2->{subscription}{id}, $fp_alice);
ok($can_sub2->{ok}, 'canceled second subscription');
is($can_sub2->{subscription}{status}, 'CANCELED', 'second subscription is CANCELED');

# ===========================================================================
# 6. Live mojolicious-mt HTTP Server: GET /api/memberships & Stripe Webhooks
# ===========================================================================
my $wh_worker = MT::Worker::spawn(
    'main::ops_worker',
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
ok($ops_port > 0, "mojolicious-mt server listening on 127.0.0.1:$ops_port");

# GET /api/memberships
my ($st_mt, $body_mt) = http_req($ops_port, 'GET', '/api/memberships');
is($st_mt, 200, 'GET /api/memberships returned 200 OK');
my $mt_j = JSON::PP->new->utf8(1)->decode($body_mt);
ok($mt_j->{ok}, 'GET /api/memberships ok is true');
is($mt_j->{count}, 3, 'GET /api/memberships count == 3');
is_deeply([ map { $_->{code} } @{ $mt_j->{tiers} } ], [ 'FREE', 'PRO', 'FOUNDER' ], 'GET /api/memberships returns FREE, PRO, FOUNDER');

$eb->poll_inbox($inbox);

# POST /webhooks/stripe: invoice.paid
my $inv_payload = JSON::PP->new->utf8(1)->encode({
    id   => 'evt_inv_paid_001',
    type => 'invoice.paid',
    data => {
        object => {
            id           => 'in_test_001',
            subscription => 'sub_stripe_pro_99',
            amount_paid  => 999,
            period_end   => time() + 30 * 86400,
            metadata     => {
                user_fp         => $fp_alice,
                tier_code       => 'PRO',
                subscription_id => $sub1->{id},
            },
        },
    },
});
my ($st_ip, $body_ip) = http_req(
    $ops_port, 'POST', '/webhooks/stripe',
    {
        'Content-Type'     => 'application/json',
        'Stripe-Signature' => Shop::Webhook::Server::sign_stripe_payload($inv_payload, $secret),
    },
    $inv_payload,
);
is($st_ip, 200, 'POST /webhooks/stripe invoice.paid returned 200 OK');
my $ip_j = JSON::PP->new->utf8(1)->decode($body_ip);
is($ip_j->{event_type}, 'invoice.paid', 'invoice.paid event_type echoed');
is($ip_j->{status}, 'ACTIVE', 'invoice.paid status is ACTIVE');
is($db->get_membership($fp_alice)->{tier_code}, 'PRO', 'invoice.paid updated membership tier to PRO');
is($db->get_membership($fp_alice)->{status}, 'ACTIVE', 'invoice.paid membership status is ACTIVE');

my $ev_ip_mem = wait_for_event($eb, $inbox, 'membership_updated', 0.5);
ok($ev_ip_mem && $ev_ip_mem->{status} eq 'ACTIVE', 'invoice.paid pushed membership_updated on EventBus');

# POST /webhooks/stripe: customer.subscription.updated (paused)
my $upd_payload = JSON::PP->new->utf8(1)->encode({
    id   => 'evt_sub_upd_001',
    type => 'customer.subscription.updated',
    data => {
        object => {
            id       => 'sub_stripe_pro_99',
            status   => 'paused',
            metadata => {
                user_fp         => $fp_alice,
                tier_code       => 'PRO',
                subscription_id => $sub1->{id},
            },
        },
    },
});
my ($st_up, $body_up) = http_req(
    $ops_port, 'POST', '/webhooks/stripe',
    {
        'Content-Type'     => 'application/json',
        'Stripe-Signature' => Shop::Webhook::Server::sign_stripe_payload($upd_payload, $secret),
    },
    $upd_payload,
);
is($st_up, 200, 'POST /webhooks/stripe customer.subscription.updated returned 200 OK');
is($db->get_subscription($sub1->{id})->{status}, 'PAUSED', 'customer.subscription.updated set subscription PAUSED');

# POST /webhooks/stripe: customer.subscription.deleted
$eb->poll_inbox($inbox);
my $del_payload = JSON::PP->new->utf8(1)->encode({
    id   => 'evt_sub_del_001',
    type => 'customer.subscription.deleted',
    data => {
        object => {
            id       => 'sub_stripe_pro_99',
            status   => 'canceled',
            metadata => {
                user_fp         => $fp_alice,
                tier_code       => 'PRO',
                subscription_id => $sub1->{id},
            },
        },
    },
});
my ($st_del, $body_del) = http_req(
    $ops_port, 'POST', '/webhooks/stripe',
    {
        'Content-Type'     => 'application/json',
        'Stripe-Signature' => Shop::Webhook::Server::sign_stripe_payload($del_payload, $secret),
    },
    $del_payload,
);
is($st_del, 200, 'POST /webhooks/stripe customer.subscription.deleted returned 200 OK');
is($db->get_membership($fp_alice)->{status}, 'CANCELED', 'customer.subscription.deleted marked membership CANCELED');
is($db->get_subscription($sub1->{id})->{status}, 'CANCELED', 'customer.subscription.deleted marked subscription CANCELED');

my $ev_del = wait_for_event($eb, $inbox, 'membership_updated', 0.5);
ok($ev_del && $ev_del->{status} eq 'CANCELED', 'customer.subscription.deleted pushed CANCELED membership_updated on EventBus');

# Clean shutdown of ops worker
$shutdown->set(1);
MT::Worker::join($wh_worker);
pass('mojolicious-mt ops worker shut down cleanly');

# ===========================================================================
# 7. Live IBM Db2 + Live IBM Informix SP_ONLY Verification (SHOP_TEST_DOCKER=1)
# ===========================================================================
SKIP: {
    skip 'Set SHOP_TEST_DOCKER=1 to run live Db2 + Informix SP_ONLY subscription tests', 2
        unless $ENV{SHOP_TEST_DOCKER};

    my @live_backends = (
        { name => 'Db2 SP_ONLY',      cfg => { driver => 'db2',      gateway_url          => $ENV{DB2_GATEWAY_URL}      // 'http://127.0.0.1:50050' } },
        { name => 'Informix SP_ONLY', cfg => { driver => 'informix', informix_gateway_url => $ENV{INFORMIX_GATEWAY_URL} // 'http://127.0.0.1:50051' } },
    );

    my $run_id = sprintf('%d%03d', time() % 100000, int(rand(1000)));

    for my $be (@live_backends) {
        subtest "Live $be->{name}" => sub {
            my $ldb = Shop::DB->new($be->{cfg});
            plan skip_all => "$be->{name} gateway not reachable" unless $ldb->health;

            my $lmem = Shop::Domain::Membership->new(db => $ldb);
            my $lsub = Shop::Domain::Subscription->new(db => $ldb, inventory => $inv, membership => $lmem);

            my $ltiers = $lmem->list_tiers;
            is(scalar(@$ltiers), 3, "$be->{name}: 3 seeded membership tiers");

            my $lfp = "SHA256:t13_$run_id";
            $ldb->upsert_user({
                fingerprint => $lfp,
                username    => "t13_$run_id",
                email       => "t13_$run_id\@example.com",
                pubkey_type => 'ssh-ed25519',
            });

            my $len = $lmem->enroll(user_fp => $lfp, tier_code => 'PRO', stripe_sub_id => "sub_live_$run_id");
            ok($len->{ok}, "$be->{name}: enroll PRO succeeded via SP_ONLY");
            is("$len->{benefits}{discount_pct}", '10.00', "$be->{name}: PRO discount_pct is 10.00");

            my $lcr = $lsub->create(
                user_fp       => $lfp,
                sku           => 'AC-MUG',
                qty           => 1,
                interval_days => 30,
                next_bill_at  => '2026-07-01 00:00:00',
            );
            ok($lcr->{ok}, "$be->{name}: create subscription succeeded via SP_ONLY");
            my $lid = $lcr->{subscription}{id};
            is(Shop::Domain::Pricing::money($lcr->{subscription}{unit_price}), '17.95', "$be->{name}: PRO 10% unit_price (19.95 - 2.00 = 17.95)");

            ok($lsub->pause($lid, $lfp)->{ok}, "$be->{name}: pause subscription");
            ok($lsub->resume($lid, $lfp)->{ok}, "$be->{name}: resume subscription");
            my $lsk = $lsub->skip_next($lid, $lfp);
            ok($lsk->{ok}, "$be->{name}: skip_next subscription");
            is($lsk->{subscription}{next_bill_at}, '2026-07-31 00:00:00', "$be->{name}: next_bill_at advanced 30d");

            my $lmrr = $lsub->mrr_summary;
            cmp_ok($lmrr->{active_members},       '>=', 1, "$be->{name}: active_members >= 1");
            cmp_ok($lmrr->{active_subscriptions}, '>=', 1, "$be->{name}: active_subscriptions >= 1");
            ok(ref($lmrr->{total_mrr}) && $lmrr->{total_mrr}->isa('MT::Decimal'), "$be->{name}: total_mrr is MT::Decimal");

            # Cleanup test records to keep live DB clean
            ok($lsub->cancel($lid, $lfp)->{ok}, "$be->{name}: cancel test subscription");
            ok($lmem->cancel(user_fp => $lfp)->{ok}, "$be->{name}: cancel test membership");
        };
    }
}

done_testing;
