#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use lib 'lib';

use Shop::DB;
use Shop::Cache::KeyDB;
use Shop::State::Inventory;
use Shop::State::EventBus;
use Shop::Domain::Cart;
use Shop::Domain::Checkout;
use Shop::Payment::Mock;
use Shop::Payment::Stripe;

# =========================================================================
# Part 1: SQLite zero-Docker integration (always runs)
# =========================================================================
my ($fh, $db_path) = tempfile(SUFFIX => '.db', UNLINK => 1);
close $fh;

my $db = Shop::DB->new({ driver => 'sqlite', path => $db_path });
is($db->driver, 'sqlite', 'factory returned SQLite driver');
ok($db->health, 'SQLite health check passed');

ok($db->init_schema('sql/schema_sqlite.sql', 'sql/seed.sql'), 'schema + seed applied');
ok($db->init_schema('sql/schema_sqlite.sql', 'sql/seed.sql'), 'schema + seed is idempotent');

my $products = $db->list_products;
is(scalar(@$products), 12, '12 seeded products loaded');

my $vt = $db->get_product('VT-220');
is(Shop::Domain::Pricing::money($vt->{price}), '429.00', 'exact product price retrieved');

my $promo = $db->get_promo('perlmt20');
is($promo->{code}, 'PERLMT20', 'case-insensitive promo lookup works');

# User & Address CRUD
my $u = $db->upsert_user({ fingerprint => 'SHA256:testfp', username => 'matt', email => 'matt@example.com', is_admin => 1 });
is($u->{username}, 'matt', 'user upserted');
is($u->{is_admin}, 1,      'user is_admin preserved');

my $addr = $db->save_address({
    user_fp     => 'SHA256:testfp',
    label       => 'Lab',
    recipient   => 'Matt',
    line1       => '127 Loopback St',
    city        => 'Austin',
    state       => 'TX',
    postal_code => '78701',
    country     => 'US',
    is_default  => 1,
});
ok($addr->{id}, 'address saved with generated id');
is(scalar(@{ $db->list_addresses('SHA256:testfp') }), 1, 'list_addresses returns 1');

# Inventory + EventBus + Cart + Checkout Saga
my $inv = Shop::State::Inventory->new;
is($inv->load_from_db($db), 12, 'Inventory loaded 12 products from DB');
my $bus   = Shop::State::EventBus->new;
my $inbox = $bus->register_session('s1', { user_fp => 'SHA256:testfp', username => 'matt' });

my $cart = Shop::Domain::Cart->new(user_fp => 'SHA256:testfp', inventory => $inv, db => $db);
my $add = $cart->add('KB-M01', 2);
ok($add->{ok}, 'added 2x KB-M01 to cart');
is($inv->get_stock('KB-M01'), 12, 'CAS decremented KB-M01 stock 14 -> 12');

my $pr = $cart->apply_promo('PERLMT20');
ok($pr->{ok}, 'applied PERLMT20 promo');

my $co = Shop::Domain::Checkout->new(
    db        => $db,
    inventory => $inv,
    event_bus => $bus,
    payment   => Shop::Payment::Mock->new,
);

# Declined card keeps cart & stock intact
my $decl = $co->place_order(
    cart          => $cart,
    user          => $u,
    address       => $addr,
    payment_token => 'tok_decline',
);
ok(!$decl->{ok}, 'tok_decline rejected');
is($cart->item_count, 2, 'cart preserved after payment decline');

# Valid card commits ACID order, clears cart, broadcasts order_placed
my $paid = $co->place_order(
    cart          => $cart,
    user          => $u,
    address       => $addr,
    payment_token => 'tok_visa',
);
ok($paid->{ok}, 'tok_visa checkout succeeded');
ok($paid->{order}{id}, 'order id returned');
is($paid->{order}{status}, 'paid', 'order status is paid');
is(scalar(@{ $paid->{order}{items} }), 1, 'order has 1 line item');
is($cart->item_count, 0, 'cart cleared after order');
is($inv->get_stock('KB-M01'), 12, 'CAS stock remains decremented after order');
is($db->get_product('KB-M01')->{stock}, 12, 'DB stock decremented atomically');

my $evs = $bus->poll_inbox($inbox);
is(scalar(@$evs), 1, 'order_placed event broadcast on EventBus');
is($evs->[0]{type}, 'order_placed', 'event type is order_placed');

my $gmv = $db->gmv_summary;
is($gmv->{order_count}, 1, 'gmv_summary order_count == 1');
is($gmv->{total_gmv}, $paid->{order}{total}, 'gmv_summary matches exact order total');

# SQLite fallbacks for Db2 temporal/OLAP repository methods
my $feat = $db->db2_features;
is($feat->{driver}, 'sqlite', 'SQLite db2_features reports sqlite');
is($feat->{decfloat34}, 0, 'SQLite decfloat34 == 0');
my $phist = $db->product_history('KB-M01', 5);
is(scalar(@$phist), 1, 'SQLite product_history fallback returns current row');
my $ohist = $db->order_history($paid->{order}{id});
is(scalar(@$ohist), 1, 'SQLite order_history fallback returns current row');
my $olap = $db->category_olap;
ok(scalar(@$olap) >= 2 && $olap->[-1]{category} eq 'ALL CATEGORIES', 'SQLite category_olap fallback includes ROLLUP total row');

# Stripe adapter offline checks (QR renderer + unconfigured guard)
my $stripe = Shop::Payment::Stripe->new(secret_key => '');
ok(!$stripe->is_configured, 'Stripe reports unconfigured when secret_key empty');
my $qr = Shop::Payment::Stripe::ascii_qr('https://checkout.stripe.com/c/pay/cs_test_123');
ok(length($qr) > 100 && $qr =~ /\x{2588}/, 'Stripe ascii_qr generates compact terminal QR code');

# =========================================================================
# Part 2: Live Docker IBM Db2 + KeyDB tests (when SHOP_TEST_DOCKER=1)
# =========================================================================
SKIP: {
    skip 'Set SHOP_TEST_DOCKER=1 to run live Db2 + KeyDB integration tests', 12
        unless $ENV{SHOP_TEST_DOCKER};

    my $db2 = Shop::DB->new({ driver => 'db2', gateway_url => $ENV{DB2_GATEWAY_URL} // 'http://127.0.0.1:50050' });
    is($db2->driver, 'db2', 'factory returned Db2 driver');
    ok($db2->health, 'Db2 gateway /health is green');

    my $db2_prods = $db2->list_products;
    ok(scalar(@$db2_prods) >= 12, 'Db2 has >= 12 seeded products');
    my $db2_vt = $db2->get_product('VT-220');
    is($db2_vt->{price}, '429.0000', 'Db2 gateway returns DECFLOAT(34) as exact string');

    # Test Db2 transaction rollback isolation via SP_ONLY stored procedure
    eval {
        $db2->txn(sub {
            my ($tx) = @_;
            $tx->sp_call(
                'SHOP_SP_UPSERT_PRODUCT',
                'TMP-ROLLBACK', 'Rollback Probe', 'Test', 'desc', '', '1.0000', 1, 1
            );
            die "intentional rollback\n";
        });
    };
    ok(!$db2->get_product('TMP-ROLLBACK'), 'Db2 transaction rollback verified via SP_ONLY');

    # Live KeyDB tests
    my $kdb = Shop::Cache::KeyDB->new(
        host => $ENV{KEYDB_HOST} // '127.0.0.1',
        port => $ENV{KEYDB_PORT} // 6379,
    );
    ok($kdb->ping, 'KeyDB PING -> PONG');

    my $pipe = $kdb->pipeline([
        ['SET', 's:test:p1', 'alpha'],
        ['GET', 's:test:p1'],
        ['DEL', 's:test:p1'],
    ]);
    is($pipe->[1], 'alpha', 'KeyDB pipelining round-trip works');

    is($kdb->reserve_cart_lease('fp_test', 'VT-220', 2, 60), 2, 'KeyDB Lua reserve_cart_lease == 2');
    my $citems = $kdb->get_cart_items('fp_test');
    is($citems->{'VT-220'}, 2, 'KeyDB get_cart_items reflects lease');
    is($kdb->release_cart_lease('fp_test', 'VT-220', 1), 1, 'KeyDB Lua release_cart_lease == 1');
    $kdb->clear_cart('fp_test');

    my ($allowed, $rem, $ttl) = $kdb->rate_limit('test_bucket_' . time(), 2, 30);
    is($allowed, 1, 'KeyDB Lua rate_limit allows under limit');
    is($rem,     1, 'KeyDB Lua rate_limit remaining == 1');
}

done_testing;
