#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use IO::Socket::INET;
use Time::HiRes qw(time usleep);

use lib 'lib';
use lib 'xs/Shop-SSH-Crypto/blib/lib';
use lib 'xs/Shop-SSH-Crypto/blib/arch';

use MT;
use MT::Cell;
use MT::Channel;
use MT::Decimal;
use Shop::Domain::JSON qw(encode_json decode_json);
use Shop::DB;
use Shop::Cache::KeyDB;
use Shop::State::Inventory;
use Shop::State::EventBus;
use Shop::Domain::Pricing;
use Shop::Domain::Cart;
use Shop::Domain::Checkout;
use Shop::Shipping::Shippo;
use Shop::Tax::Nexus;
use Shop::Metrics;
use Shop::Webhook::Server;

# ---------------------------------------------------------------------------
# Lightweight in-memory KeyDB fallback if live KeyDB is unavailable
# ---------------------------------------------------------------------------
{
    package LocalMockKeyDB;
    sub new { bless { store => {}, ttl => {} }, shift }
    sub get { my ($self, $k) = @_; return $self->{store}{$k}; }
    sub set { my ($self, $k, $v, $ttl) = @_; $self->{store}{$k} = $v; $self->{ttl}{$k} = $ttl; return 'OK'; }
    sub del { my ($self, @ks) = @_; my $n = 0; for (@ks) { $n++ if defined delete $self->{store}{$_}; } return $n; }
    sub publish { return 1; }
}

# ---------------------------------------------------------------------------
# Worker entrypoint (defined BEFORE MT::Image::freeze())
# ---------------------------------------------------------------------------
sub shippo_webhook_worker {
    my ($db_path, $cells_id, $rl_id, $sessions_id, $shutdown_id, $port_ch_id, $shippo_secret) = @_;
    my $ok = eval {
        my $db      = Shop::DB->new({ driver => 'sqlite', path => $db_path });
        my $metrics = Shop::Metrics->attach({ cells_id => $cells_id, ratelimit_id => $rl_id });
        my $eb      = Shop::State::EventBus->attach({ sessions_id => $sessions_id });
        my $sd      = MT::Cell->attach($shutdown_id);

        my $srv = Shop::Webhook::Server->new(
            host                  => '127.0.0.1',
            port                  => 0,
            db                    => $db,
            metrics               => $metrics,
            event_bus             => $eb,
            shippo_webhook_secret => $shippo_secret,
            shutdown_cell         => $sd,
        );
        $srv->listen;
        MT::Channel->attach($port_ch_id)->send($srv->port);
        $srv->run;
        1;
    };
    if (!$ok) {
        warn "shippo_webhook_worker died: $@\n";
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

# ---------------------------------------------------------------------------
# Setup SQLite + shared state BEFORE MT::Image::freeze()
# ---------------------------------------------------------------------------
my ($fh, $db_path) = tempfile(SUFFIX => '.db', UNLINK => 1);
close $fh;

my $db = Shop::DB->new({ driver => 'sqlite', path => $db_path });
ok($db->init_schema('sql/schema_sqlite.sql', 'sql/seed.sql'), 'SQLite schema + seed initialized');

my $metrics = Shop::Metrics->new;
my $inv     = Shop::State::Inventory->new(metrics => $metrics);
ok($inv->load_from_db($db) >= 12, 'Loaded seeded products into Inventory');

my $eb    = Shop::State::EventBus->new;
my $inbox = $eb->register_session('sess-logistics', { user_fp => 'SHA256:ship_buyer', username => 'ada' });

my $shutdown = MT::Cell->new(0);
my $port_ch  = MT::Channel->new(4);

# Freeze interpreter image for live MT::Worker webhook server test
Shop::Webhook::Server::prepare_for_freeze();
MT::Image::freeze();

# Connect KeyDB if live, else use LocalMockKeyDB
my $kdb = Shop::Cache::KeyDB->new(prefix => 't11:' . time() . ':');
my $using_live_kdb = $kdb->ping ? 1 : 0;
$kdb = LocalMockKeyDB->new unless $using_live_kdb;

# =========================================================================
# 1. Shippo: Closest-Warehouse Selection, Validation, Rates + KeyDB Cache, Labels
# =========================================================================
my $shippo = Shop::Shipping::Shippo->new(api_token => '', keydb => $kdb, cache_ttl => 21600);
my $warehouses = $db->list_warehouses;
is(scalar(@$warehouses), 3, '3 seeded warehouses returned from DB');

my $wh_tx = $shippo->pick_warehouse('78701', $warehouses);
is($wh_tx->{code}, 'DAL1', 'Austin TX (78701) routes to DAL1 (75201)');

my $wh_ny = $shippo->pick_warehouse('10001', $warehouses);
is($wh_ny->{code}, 'NYC1', 'Manhattan NY (10001) routes to NYC1 (07102)');

my $wh_ca = $shippo->pick_warehouse('94107', $warehouses);
is($wh_ca->{code}, 'SFO1', 'San Francisco CA (94107) routes to SFO1 (94607)');

my $wh_wa = $shippo->pick_warehouse('98101', $warehouses);
is($wh_wa->{code}, 'SFO1', 'Seattle WA (98101) routes to SFO1 (94607)');

# Address validation
my $valid_addr = {
    recipient   => 'Ada Lovelace',
    line1       => '100 Congress Ave',
    city        => 'Austin',
    state       => 'TX',
    postal_code => '78701',
    country     => 'US',
};
my $v_ok = $shippo->validate_address($valid_addr);
is($v_ok->{ok},    1, 'Valid US address passes validation');
is($v_ok->{valid}, 1, 'valid flag == 1');

my $v_bad = $shippo->validate_address({ line1 => '1', city => '', state => 'ZZ', postal_code => 'abc' });
is($v_bad->{ok},    0, 'Invalid US address rejected');
is($v_bad->{valid}, 0, 'valid flag == 0');

# Rate lookup + KeyDB caching
my $r1 = $shippo->get_rates(
    from      => $wh_tx,
    to        => $valid_addr,
    weight_oz => 24,
);
is($r1->{ok},        1, 'get_rates succeeded');
is($r1->{cached},    0, 'First get_rates call is a cache miss');
is($r1->{cache_key}, 'shippo:rate:75201:78701:24', 'Exact Shippo rate cache key');
is(scalar(@{ $r1->{rates} }), 3, 'Returns 3 carrier rates');
is($r1->{rates}[0]{service}, 'USPS Ground Advantage', 'Rate 0 is USPS Ground Advantage');
is($r1->{rates}[1]{service}, 'UPS Ground',            'Rate 1 is UPS Ground');
is($r1->{rates}[2]{service}, 'FedEx 2Day',            'Rate 2 is FedEx 2Day');
ok(ref($r1->{rates}[0]{amount}) && $r1->{rates}[0]{amount}->isa('MT::Decimal'), 'Rate amount is exact MT::Decimal');
ok($r1->{rates}[0]{estimated_days} > 0, 'ETA days populated');
ok($r1->{rates}[0]{amount} < $r1->{rates}[1]{amount}, 'USPS cheaper than UPS');
ok($r1->{rates}[1]{amount} < $r1->{rates}[2]{amount}, 'UPS cheaper than FedEx 2Day');

my $r2 = $shippo->get_rates(
    from      => $wh_tx,
    to        => $valid_addr,
    weight_oz => 24,
);
is($r2->{ok},     1, 'Second get_rates succeeded');
is($r2->{cached}, 1, 'Second get_rates call served from KeyDB cache');
is("$r2->{rates}[0]{amount}", "$r1->{rates}[0]{amount}", 'Cached MT::Decimal rate matches exactly');
ok(ref($r2->{rates}[0]{amount}) && $r2->{rates}[0]{amount}->isa('MT::Decimal'), 'Cached rate re-hydrated as MT::Decimal');

# Label purchase
my $chosen_rate = $r2->{rates}[1]; # UPS Ground
my $lbl = $shippo->buy_label(
    rate     => $chosen_rate,
    order_id => 'ORD-UNIT-1',
    from     => $wh_tx,
    to       => $valid_addr,
);
is($lbl->{ok}, 1, 'buy_label succeeded');
like($lbl->{tracking_number}, qr/^1Z999AA1\d{10}$/, 'UPS tracking number generated');
like($lbl->{label_url}, qr{^https://shippo\.sandbox/labels/ORD-UNIT-1-}, 'Sandbox label URL generated');
is($lbl->{carrier}, 'UPS', 'Label carrier matches');
is("$lbl->{rate_amount}", "$chosen_rate->{amount}", 'Label rate_amount exact MT::Decimal match');

# =========================================================================
# 2. Tax Nexus Engine (TX 8.25% Registered, WA 0.00 No Nexus, nexus_alerts)
# =========================================================================
my $nexus = Shop::Tax::Nexus->new(db => $db, keydb => $kdb, cache_ttl => 86400);

my $tx_tax = $nexus->calculate(state => 'TX', postal_code => '78701', subtotal => '100.00');
is($tx_tax->{registered},   1,            'TX is registered for tax nexus');
is($tx_tax->{nexus_status}, 'REGISTERED', 'TX nexus_status == REGISTERED');
is("$tx_tax->{tax}",        '8.25',       'TX 8.25% on $100.00 == $8.25 exact MT::Decimal');
ok(ref($tx_tax->{tax}) && $tx_tax->{tax}->isa('MT::Decimal'), 'Tax amount is MT::Decimal');

# Verify ROUND_HALF_UP precision: 75.00 * 0.0825 = 6.1875 -> 6.19
my $tx_round = $nexus->calculate(state => 'TX', postal_code => '78701', subtotal => '75.00');
is("$tx_round->{tax}",   '6.19', 'TX 8.25% on $75.00 rounds HALF_UP to $6.19');
is($tx_round->{cached},  1,      'Second TX lookup served from KeyDB cache');

my $wa_tax = $nexus->calculate(state => 'WA', postal_code => '98101', subtotal => '100.00');
is($wa_tax->{registered},   0,          'WA is NOT registered for tax nexus');
is($wa_tax->{nexus_status}, 'NO_NEXUS', 'WA nexus_status == NO_NEXUS');
is("$wa_tax->{tax}",        '0.00',     'WA tax == $0.00 (no nexus)');

# Verify nexus_alerts classification (REGISTERED / NEXUS_REQUIRED / APPROACHING / BELOW_THRESHOLD)
{
    package MockNexusDB;
    sub new { bless {}, shift }
    sub tax_nexus_report {
        return [
            { state => 'TX', rate => '0.0825', threshold_sales => '500000', threshold_txns => 0,   registered => 1, ytd_sales => '12000.00',  ytd_txns => 50 },
            { state => 'WA', rate => '0.0650', threshold_sales => '100000', threshold_txns => 0,   registered => 0, ytd_sales => '105000.00', ytd_txns => 120 },
            { state => 'FL', rate => '0.0600', threshold_sales => '100000', threshold_txns => 0,   registered => 0, ytd_sales => '85000.00',  ytd_txns => 90 },
            { state => 'IL', rate => '0.0625', threshold_sales => '100000', threshold_txns => 200, registered => 0, ytd_sales => '10000.00',  ytd_txns => 15 },
        ];
    }
}
my $mock_nexus = Shop::Tax::Nexus->new(db => MockNexusDB->new);
my $alerts = $mock_nexus->nexus_alerts;
my %by_st = map { $_->{state} => $_->{status} } @$alerts;
is($by_st{TX}, 'REGISTERED',      'nexus_alerts: TX -> REGISTERED');
is($by_st{WA}, 'NEXUS_REQUIRED',  'nexus_alerts: WA (>=100%) -> NEXUS_REQUIRED');
is($by_st{FL}, 'APPROACHING',     'nexus_alerts: FL (>=80%) -> APPROACHING');
is($by_st{IL}, 'BELOW_THRESHOLD', 'nexus_alerts: IL (<80%) -> BELOW_THRESHOLD');

# Also verify live SQLite tax_nexus_report works through nexus_alerts
my $live_alerts = $nexus->nexus_alerts;
ok(scalar(@$live_alerts) >= 6, 'Live SQLite nexus_alerts returns all 6 seeded states');

# =========================================================================
# 3. Inbound PO Receive -> DB + MT::Cell CAS Increment + EventBus Broadcast
# =========================================================================
my $checkout = Shop::Domain::Checkout->new(
    db        => $db,
    inventory => $inv,
    event_bus => $eb,
    keydb     => $kdb,
    metrics   => $metrics,
    shippo    => $shippo,
    tax_nexus => $nexus,
);

my $pos = $db->list_pos;
ok(scalar(@$pos) >= 2, 'Seeded purchase orders present');
my $po_lines = $db->get_po_lines($pos->[0]{id});
ok(scalar(@$po_lines) >= 1, 'First PO has lines');
my $line0 = $po_lines->[0];
my $sku0  = $line0->{sku};
my $stock_before = $inv->get_stock($sku0);

my $recv = $checkout->receive_po_line(po_line_id => $line0->{id}, qty => 5);
is($recv->{ok},        1,                 'Checkout::receive_po_line succeeded');
is($recv->{sku},       $sku0,             'Received SKU matches PO line');
is($inv->get_stock($sku0), $stock_before + 5, 'Inventory MT::Cell atomically incremented by +5');
is($recv->{new_stock}, $stock_before + 5, 'Returned new_stock matches MT::Cell');

my $ev_list = $eb->poll_inbox($inbox);
my ($restock_ev) = grep { ($_->{type} // '') eq 'stock_update' && ($_->{reason} // '') eq 'po_received' } @$ev_list;
ok($restock_ev, 'EventBus broadcast live stock_update event on PO receive');
is($restock_ev->{sku},   $sku0,             'EventBus stock_update SKU matches');
is($restock_ev->{stock}, $stock_before + 5, 'EventBus stock_update stock matches');

# =========================================================================
# 4. Outbound Checkout -> Shipment Creation -> POST /webhooks/shippo Live Push
# =========================================================================
$db->upsert_user({ fingerprint => 'SHA256:ship_buyer', username => 'ada', is_guest => 0 });
my $cart = Shop::Domain::Cart->new(user_fp => 'SHA256:ship_buyer', inventory => $inv, db => $db);
my $add_res = $cart->add('VT-220', 1);
is($add_res->{ok}, 1, 'Added VT-220 to cart');

my $wa_addr = {
    recipient   => 'Ada Lovelace',
    line1       => '400 Pine St',
    city        => 'Seattle',
    state       => 'WA',
    postal_code => '98101',
    country     => 'US',
};
my $wa_rates = $shippo->get_rates(to => $wa_addr, items => $cart->items, warehouses => $warehouses);
is($wa_rates->{warehouse_code}, 'SFO1', 'WA rate lookup routed to SFO1');
my $usps_rate = $wa_rates->{rates}[0];

my $ord_res = $checkout->place_order(
    cart          => $cart,
    user          => { fingerprint => 'SHA256:ship_buyer', username => 'ada' },
    address       => $wa_addr,
    shipping_rate => $usps_rate,
    tax_nexus     => $nexus,
);
is($ord_res->{ok}, 1, 'place_order with Shippo rate + Tax Nexus succeeded');
is("$ord_res->{order}{tax}",      '0.00',               'WA order has $0.00 tax (NO_NEXUS)');
is("$ord_res->{order}{shipping}", "$usps_rate->{amount}", 'Order shipping matches chosen Shippo rate');
ok($ord_res->{shipment} && $ord_res->{shipment}{id},    'Shipment auto-created on order placement');
is($ord_res->{shipment}{warehouse_code}, 'SFO1',        'Shipment assigned to closest warehouse SFO1');
is($ord_res->{shipment}{status},         'PENDING',     'Initial shipment status is PENDING');

# Buy label and attach tracking number to shipment
my $ord_lbl = $shippo->buy_label(
    rate     => $usps_rate,
    order_id => $ord_res->{order}{id},
    from     => $wa_rates->{warehouse},
    to       => $wa_addr,
);
is($ord_lbl->{ok}, 1, 'Label purchased for order shipment');
my $trk = $ord_lbl->{tracking_number};
my $upd_shp = $db->update_shipment(
    $ord_res->{shipment}{id},
    status          => 'LABEL_CREATED',
    tracking_number => $trk,
    label_url       => $ord_lbl->{label_url},
);
is($upd_shp->{tracking_number}, $trk, 'Tracking number persisted on shipment');

# Clear inbox before live webhook test
$eb->poll_inbox($inbox);

# Launch live Webhook::Server inside frozen MT::Worker
my $shippo_secret = 'shippo_whsec_test_999';
my $m_ids  = $metrics->state_ids;
my $eb_ids = $eb->state_ids;
my $w = MT::Worker::spawn(
    'main::shippo_webhook_worker',
    $db_path, $m_ids->{cells_id}, $m_ids->{ratelimit_id},
    $eb_ids->{sessions_id}, $shutdown->id, $port_ch->id, $shippo_secret,
);
my $wh_port = $port_ch->recv;
ok($wh_port > 0, "Webhook::Server listening on 127.0.0.1:$wh_port in frozen MT::Worker");

# 4.0 Verify mojolicious-mt engine, Mojo::Reactor::MT, accel, and /api/catalog
my ($st_h11, $body_h11) = http_req($wh_port, 'GET', '/healthz');
is($st_h11, 200, 'GET /healthz returned 200 OK');
my $h11 = decode_json($body_h11);
ok($h11->{ok}, 'GET /healthz ok is true');
is($h11->{engine},  'mojolicious-mt',    'GET /healthz reports mojolicious-mt');
is($h11->{reactor}, 'Mojo::Reactor::MT', 'GET /healthz reports Mojo::Reactor::MT');
ok($h11->{accel},   'GET /healthz reports accel active');

my ($st_c11, $body_c11) = http_req($wh_port, 'GET', '/api/catalog');
is($st_c11, 200, 'GET /api/catalog returned 200 OK');
my $c11 = decode_json($body_c11);
ok($c11->{ok} && $c11->{count} >= 12 && ref($c11->{items}) eq 'ARRAY', 'GET /api/catalog returns catalog JSON');

# 4a. Bad X-Shippo-Signature -> 400
my $transit_payload = encode_json({
    event => 'track_updated',
    data  => {
        tracking_number => $trk,
        tracking_status => { status => 'TRANSIT' },
    },
});
my ($st_bad, $body_bad) = http_req(
    $wh_port, 'POST', '/webhooks/shippo',
    { 'Content-Type' => 'application/json', 'X-Shippo-Signature' => '0' x 64 },
    $transit_payload,
);
is($st_bad, 400, 'POST /webhooks/shippo rejects invalid X-Shippo-Signature with 400');

# 4b. Valid TRANSIT webhook -> IN_TRANSIT + order shipped + EventBus push
my $sig_transit = Shop::Webhook::Server::sign_shippo_payload($transit_payload, $shippo_secret);
my ($st_tr, $body_tr) = http_req(
    $wh_port, 'POST', '/webhooks/shippo',
    { 'Content-Type' => 'application/json', 'X-Shippo-Signature' => $sig_transit },
    $transit_payload,
);
is($st_tr, 200, 'POST /webhooks/shippo (TRANSIT) returned 200 OK');

my $pushed_tr;
for (1 .. 40) {
    my $evs = $eb->poll_inbox($inbox);
    ($pushed_tr) = grep { ($_->{type} // '') eq 'shipment_updated' } @$evs;
    last if $pushed_tr;
    usleep(10_000);
}
ok($pushed_tr, 'EventBus delivered shipment_updated (IN_TRANSIT) to buyer inbox');
is($pushed_tr->{order_id},        $ord_res->{order}{id}, 'EventBus order_id matches');
is($pushed_tr->{tracking_number}, $trk,                  'EventBus tracking_number matches');
is($pushed_tr->{status},          'IN_TRANSIT',          'EventBus status mapped TRANSIT -> IN_TRANSIT');

my $shp_after_tr = $db->get_shipment_by_tracking($trk);
is($shp_after_tr->{status}, 'IN_TRANSIT', 'DB shipment status updated to IN_TRANSIT');
my $ord_after_tr = $db->get_order($ord_res->{order}{id});
is($ord_after_tr->{status}, 'shipped', 'DB order status updated to shipped');

# 4c. Valid DELIVERED webhook -> DELIVERED + order delivered + EventBus push
my $deliv_payload = encode_json({
    event => 'track_updated',
    data  => {
        tracking_number => $trk,
        tracking_status => { status => 'DELIVERED' },
    },
});
my $sig_deliv = Shop::Webhook::Server::sign_shippo_payload($deliv_payload, $shippo_secret);
my ($st_dl, $body_dl) = http_req(
    $wh_port, 'POST', '/webhooks/shippo',
    { 'Content-Type' => 'application/json', 'X-Shippo-Signature' => $sig_deliv },
    $deliv_payload,
);
is($st_dl, 200, 'POST /webhooks/shippo (DELIVERED) returned 200 OK');

my $pushed_dl;
for (1 .. 40) {
    my $evs = $eb->poll_inbox($inbox);
    ($pushed_dl) = grep { ($_->{type} // '') eq 'shipment_updated' } @$evs;
    last if $pushed_dl;
    usleep(10_000);
}
ok($pushed_dl, 'EventBus delivered shipment_updated (DELIVERED) to buyer inbox');
is($pushed_dl->{status}, 'DELIVERED', 'EventBus status == DELIVERED');

my $shp_after_dl = $db->get_shipment_by_tracking($trk);
is($shp_after_dl->{status}, 'DELIVERED', 'DB shipment status updated to DELIVERED');
my $ord_after_dl = $db->get_order($ord_res->{order}{id});
is($ord_after_dl->{status}, 'delivered', 'DB order status updated to delivered');
is($metrics->get('webhooks_processed_total'), 2, 'webhooks_processed_total incremented to 2');

# Shutdown webhook worker cleanly
$shutdown->set(1);
MT::Worker::join($w);
pass('Webhook::Server MT::Worker shut down cleanly');

# =========================================================================
# 5. Live Docker Verification against BOTH Db2 (:50050) AND Informix (:50051)
# =========================================================================
if ($ENV{SHOP_TEST_DOCKER}) {
    my @engines = (
        { name => 'Db2',      opts => { driver => 'db2',      gateway_url          => $ENV{DB2_GATEWAY_URL}      // 'http://127.0.0.1:50050' } },
        { name => 'Informix', opts => { driver => 'informix', informix_gateway_url => $ENV{INFORMIX_GATEWAY_URL} // 'http://127.0.0.1:50051' } },
    );

    for my $eng (@engines) {
        subtest "Live $eng->{name} SP_ONLY logistics & nexus" => sub {
            my $edb = Shop::DB->new($eng->{opts});
            if (!$edb->health) {
                plan skip_all => "$eng->{name} gateway not reachable";
            }

            my $ewhs = $edb->list_warehouses;
            is(scalar(@$ewhs), 3, "$eng->{name}: 3 warehouses seeded");

            my $enexus = Shop::Tax::Nexus->new(db => $edb);
            my $etx = $enexus->calculate(state => 'TX', postal_code => '75201', subtotal => '100.00');
            is("$etx->{tax}", '8.25', "$eng->{name}: TX nexus 8.25% exact MT::Decimal");
            my $ewa = $enexus->calculate(state => 'WA', postal_code => '98101', subtotal => '100.00');
            is("$ewa->{tax}", '0.00', "$eng->{name}: WA unregistered 0.00 NO_NEXUS");

            my $ealerts = $enexus->nexus_alerts;
            ok(scalar(@$ealerts) >= 6, "$eng->{name}: nexus_alerts returns >= 6 states");

            # Inbound PO create + receive_po_line
            my $run = sprintf('%d%03d', time() % 100000, int(rand(1000)));
            my $einv = Shop::State::Inventory->new;
            $einv->load_from_db($edb);
            my $eeb  = Shop::State::EventBus->new;
            my $ebox = $eeb->register_session("sess-$eng->{name}-$run", { user_fp => "SHA256:dock_$run", username => 'dock' });
            my $echk = Shop::Domain::Checkout->new(
                db        => $edb,
                inventory => $einv,
                event_bus => $eeb,
                shippo    => $shippo,
                tax_nexus => $enexus,
            );

            my $po_id = "PO-T11-$run";
            my $pol_id = "POL-T11-$run";
            my $po = $edb->create_po(
                { id => $po_id, supplier => 'Acme Supply', warehouse_code => 'DAL1', total_cost => '100.00' },
                [{ id => $pol_id, sku => 'AC-MUG', qty_ordered => 10, unit_cost => '10.00' }],
            );
            ok($po && $po->{id} eq $po_id, "$eng->{name}: created PO $po_id");

            my $bef = $einv->get_stock('AC-MUG');
            my $er  = $echk->receive_po_line(po_line_id => $pol_id, qty => 4);
            is($er->{ok}, 1, "$eng->{name}: receive_po_line succeeded");
            is($einv->get_stock('AC-MUG'), $bef + 4, "$eng->{name}: MT::Cell stock incremented +4");

            # Outbound checkout -> shipment auto-created -> update -> lookup by tracking
            $edb->upsert_user({ fingerprint => "SHA256:dock_$run", username => 'dock', is_guest => 0 });
            my $ecart = Shop::Domain::Cart->new(user_fp => "SHA256:dock_$run", inventory => $einv, db => $edb);
            $ecart->add('AC-MUG', 1);
            my $eaddr = { recipient => 'Dock User', line1 => '1 Market St', city => 'New York', state => 'NY', postal_code => '10001', country => 'US' };
            my $erates = $shippo->get_rates(to => $eaddr, items => $ecart->items, warehouses => $ewhs);
            my $eord = $echk->place_order(
                cart          => $ecart,
                user          => { fingerprint => "SHA256:dock_$run", username => 'dock' },
                address       => $eaddr,
                shipping_rate => $erates->{rates}[0],
                tax_nexus     => $enexus,
            );
            is($eord->{ok}, 1, "$eng->{name}: checkout with Shippo + Nexus succeeded");
            ok($eord->{shipment} && $eord->{shipment}{warehouse_code} eq 'NYC1', "$eng->{name}: shipment routed to NYC1");

            my $etrk = "9400111899$run";
            $edb->update_shipment($eord->{shipment}{id}, status => 'IN_TRANSIT', tracking_number => $etrk);
            my $efound = $edb->get_shipment_by_tracking($etrk);
            is($efound->{status}, 'IN_TRANSIT', "$eng->{name}: get_shipment_by_tracking returned IN_TRANSIT");
        };
    }
}

done_testing;
