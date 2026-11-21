#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(sleep);
use lib 'lib';

use MT::Decimal;
use Shop::DB;

my $gw = $ENV{DB2_GATEWAY_URL} // 'http://127.0.0.1:50050';
my $db = Shop::DB->new({ driver => 'db2', gateway_url => $gw });

if (!$db->health) {
    plan skip_all => "Live IBM Db2 gateway not reachable at $gw";
}

my $run_id = sprintf('%d%03d', time() % 100000, int(rand(1000)));

# =========================================================================
# 1. Engine capabilities & SP_ONLY metadata
# =========================================================================
my $feat = $db->db2_features;
is($feat->{driver},      'db2',      'db2_features driver == db2');
is($feat->{decfloat34},  1,          'db2_features decfloat34 == 1');
is($feat->{temporal},    1,          'db2_features temporal == 1');
is($feat->{final_table}, 1,          'db2_features final_table == 1');
is($feat->{merge},       1,          'db2_features merge == 1');
is($feat->{compression}, 'ADAPTIVE', 'db2_features compression == ADAPTIVE');
is($feat->{olap_rollup}, 1,          'db2_features olap_rollup == 1');
is($feat->{sp_only},     1,          'db2_features sp_only == 1');

# =========================================================================
# 2. SP_ONLY Ad-Hoc SQL Blocking
# =========================================================================
eval { $db->query('SELECT * FROM orders'); };
like($@, qr/SQL_INJECTION_BLOCKED/, 'ad-hoc SELECT on /query is blocked (403 SQL_INJECTION_BLOCKED)');

eval { $db->exec('DROP TABLE orders'); };
like($@, qr/SQL_INJECTION_BLOCKED/, 'ad-hoc DROP TABLE on /query is blocked (403 SQL_INJECTION_BLOCKED)');

eval {
    $db->txn(sub {
        my ($tx) = @_;
        $tx->query('SELECT * FROM users');
    });
};
like($@, qr/SQL_INJECTION_BLOCKED/, 'ad-hoc SELECT inside /tx/query is blocked');

eval { $db->sp_call('SHOP_SP_GET_PRODUCT; DROP TABLE products', 'VT-220'); };
like($@, qr/SQL_INJECTION_BLOCKED/, 'injected procedure name on /sp/call is blocked');

# Parameterized SQLi payloads are completely inert
my $sqli_prod = $db->get_product("VT-220'; DROP TABLE products; --");
ok(!defined $sqli_prod, 'SQLi payload in SHOP_SP_GET_PRODUCT is completely inert');

my $sqli_user = $db->get_user("' OR '1'='1");
ok(!defined $sqli_user, 'SQLi payload in SHOP_SP_GET_USER is completely inert');

my $seeded = $db->list_products;
ok(scalar(@$seeded) >= 12, 'products table untouched after SQLi attempts');

# =========================================================================
# 3. DECFLOAT(34) 34-digit precision round-trip matching MT::Decimal
# =========================================================================
my $sku_dec = "T-DEC-$run_id";
my $val_34  = '123456789012345678901234567890.1234';
my $mt_34   = MT::Decimal->new($val_34);

ok($db->upsert_product({
    sku         => $sku_dec,
    name        => 'DECFLOAT34 Precision Probe',
    category    => 'Precision',
    description => '34-digit IEEE 754-2008 decimal128 test',
    ascii_art   => '',
    price       => "$mt_34",
    stock       => 5,
    active      => 0,
}), 'upserted DECFLOAT(34) test product via MERGE SP');

my $got_dec = $db->get_product($sku_dec);
is($got_dec->{price}, $val_34, 'DECFLOAT(34) preserves all 34 significant digits verbatim');
is("" . MT::Decimal->new($got_dec->{price}), "$mt_34", 'exact MT::Decimal parity with Db2 DECFLOAT(34)');

# Small decimal must never drift to scientific notation (e.g. 1E-8)
$db->upsert_product({ sku => $sku_dec, price => '0.00000001' });
my $got_small = $db->get_product($sku_dec);
is($got_small->{price}, '0.00000001', 'DECFLOAT(34) small decimal serialized without scientific notation drift');

# =========================================================================
# 4. DB Engine CHECK Constraints (stock >= 0, price >= 0, qty > 0)
# =========================================================================
eval { $db->update_product_stock($sku_dec, -5); };
like($@, qr/SQL0545N|23513|CHECK/i, 'CHECK (stock >= 0) rejects negative stock at Db2 engine level');

eval { $db->upsert_product({ sku => $sku_dec, price => '-9.99' }); };
like($@, qr/SQL0545N|23513|CHECK/i, 'CHECK (price >= 0) rejects negative price at Db2 engine level');

eval {
    $db->txn(sub {
        my ($tx) = @_;
        $tx->sp_call('SHOP_SP_ADD_ORDER_ITEM', "BAD-$run_id", "ORD-BAD-$run_id", $sku_dec, 'Bad Qty', 0, '1.00', '0.00');
    });
};
like($@, qr/SQL0545N|23513|CHECK/i, 'CHECK (qty > 0) rejects zero qty at Db2 engine level');

# =========================================================================
# 5. MERGE INTO Atomic Upsert (Insert + Partial Update)
# =========================================================================
my $sku_mrg = "T-MRG-$run_id";
$db->upsert_product({
    sku         => $sku_mrg,
    name        => 'Merge Initial Name',
    category    => 'MergeCat',
    description => 'Initial desc',
    ascii_art   => '',
    price       => '100.0000',
    stock       => 20,
    active      => 0,
});
my $m1 = $db->get_product($sku_mrg);
is($m1->{name},  'Merge Initial Name', 'MERGE INTO inserted new product');
is($m1->{price}, '100.0000',           'MERGE INTO stored initial price');
is($m1->{stock}, 20,                   'MERGE INTO stored initial stock');

# Partial update: only change price; name & stock must be preserved via COALESCE
my $ts_before_mutate = $db->current_timestamp;
ok(length($ts_before_mutate) >= 19, "captured Db2 TIMESTAMP(12): $ts_before_mutate");
sleep(0.05);

$db->upsert_product({ sku => $sku_mrg, price => '149.9500' });
my $m2 = $db->get_product($sku_mrg);
is($m2->{name},  'Merge Initial Name', 'MERGE INTO partial update preserved existing name');
is($m2->{price}, '149.9500',           'MERGE INTO partial update changed price');
is($m2->{stock}, 20,                   'MERGE INTO partial update preserved stock');

# User MERGE INTO upsert
my $fp = "SHA256:db2super_$run_id";
my $u1 = $db->upsert_user({ fingerprint => $fp, username => 'db2tester', email => 'db2@example.com', is_admin => 1 });
is($u1->{username}, 'db2tester', 'MERGE INTO users inserted user');
my $u2 = $db->upsert_user({ fingerprint => $fp, email => 'updated@example.com' });
is($u2->{username}, 'db2tester',           'MERGE INTO users partial update preserved username');
is($u2->{email},    'updated@example.com', 'MERGE INTO users partial update changed email');

# =========================================================================
# 6. SELECT FROM FINAL TABLE (UPDATE ...) Atomic Decrement & Readback
# =========================================================================
sleep(0.05);
my $dec_row = $db->decrement_product_stock($sku_mrg, 3);
ok(defined $dec_row, 'SELECT FROM FINAL TABLE returned updated row in 1 round-trip');
is($dec_row->{sku},   $sku_mrg, 'FINAL TABLE returned matching SKU');
is($dec_row->{stock}, 17,       'FINAL TABLE atomically decremented stock 20 -> 17');

my $over_dec = $db->decrement_product_stock($sku_mrg, 99999);
ok(!defined $over_dec, 'FINAL TABLE returns undef when stock < requested qty');
is($db->get_product($sku_mrg)->{stock}, 17, 'stock unchanged after rejected decrement');

# =========================================================================
# 7. System-Period Temporal Time-Travel (products FOR SYSTEM_TIME)
# =========================================================================
my $phist = $db->product_history($sku_mrg, 10);
ok(scalar(@$phist) >= 3, 'product_history (FOR SYSTEM_TIME) captured insert + price update + stock decrement (' . scalar(@$phist) . ' versions)');
is($phist->[0]{stock}, 17,         'newest temporal version has stock == 17');
is($phist->[0]{price}, '149.9500', 'newest temporal version has price == 149.9500');
is($phist->[-1]{price}, '100.0000', 'oldest temporal version preserved original price == 100.0000');
is($phist->[-1]{stock}, 20,         'oldest temporal version preserved original stock == 20');
ok(length($phist->[0]{sys_start}) >= 19 && length($phist->[0]{sys_end}) >= 19, 'temporal rows carry sys_start & sys_end');

# Time-travel AS OF before mutations
my $past_cat = $db->catalog_as_of($ts_before_mutate);
my ($past_mrg) = grep { $_->{sku} eq $sku_mrg } @$past_cat;
ok(defined $past_mrg, 'FOR SYSTEM_TIME AS OF recovered product snapshot before mutation');
is($past_mrg->{price}, '100.0000', 'AS OF time-travel recovered exact old price (100.0000)');
is($past_mrg->{stock}, 20,         'AS OF time-travel recovered exact old stock (20)');

# =========================================================================
# 8. Orders Temporal Lifecycle (pending -> paid -> shipped) + Masked View
# =========================================================================
my $ord_id = "ORD-SUP-$run_id";
my $ord = $db->create_order(
    {
        id               => $ord_id,
        user_fp          => $fp,
        username         => 'db2tester',
        status           => 'pending',
        subtotal         => '429.0000',
        discount         => '0.0000',
        tax              => '35.3900',
        shipping         => '0.0000',
        total            => '464.3900',
        promo_code       => '',
        payment_method   => 'mock',
        payment_ref      => "ref_$run_id",
        shipping_address => '742 Evergreen Terrace, Springfield, IL 62704',
    },
    [
        {
            sku        => 'VT-220',
            name       => 'DEC VT220 Amber Phosphor Terminal',
            qty        => 1,
            unit_price => '429.0000',
            line_total => '429.0000',
        },
    ],
);
is($ord->{status}, 'pending', 'order created with initial status pending');

sleep(0.05);
my $u_paid = $db->update_order_status($ord_id, 'paid');
is($u_paid->{status}, 'paid', 'FINAL TABLE update_order_status transitioned pending -> paid');

sleep(0.05);
my $u_ship = $db->update_order_status($ord_id, 'shipped');
is($u_ship->{status}, 'shipped', 'FINAL TABLE update_order_status transitioned paid -> shipped');

my $ohist = $db->order_history($ord_id);
is(scalar(@$ohist), 3, 'orders FOR SYSTEM_TIME automatically captured all 3 lifecycle versions');
my @statuses = map { $_->{status} } @$ohist;
is_deeply(\@statuses, ['shipped', 'paid', 'pending'], 'order temporal audit trail: shipped -> paid -> pending');

# Restore VT-220 stock so seeded stock remains healthy
my $vt_now = $db->get_product('VT-220');
$db->update_product_stock('VT-220', $vt_now->{stock} + 1);

# Masked view check
my $masked = $db->list_orders_masked($fp);
ok(@$masked >= 1, 'v_orders_masked returned user order');
like($masked->[0]{shipping_address}, qr/\*\*\*MASKED\*\*\*/, 'v_orders_masked masks shipping_address PII');

# =========================================================================
# 9. Category OLAP (GROUP BY ROLLUP + RANK() OVER + SUM() OVER)
# =========================================================================
my $ord_id2 = "ORD-SUP2-$run_id";
$db->create_order(
    {
        id               => $ord_id2,
        user_fp          => $fp,
        username         => 'db2tester',
        status           => 'paid',
        subtotal         => '189.5000',
        discount         => '0.0000',
        tax              => '15.6300',
        shipping         => '0.0000',
        total            => '205.1300',
        promo_code       => '',
        payment_method   => 'mock',
        payment_ref      => "ref2_$run_id",
        shipping_address => '127 Loopback Ave, Austin, TX 78701',
    },
    [
        {
            sku        => 'KB-M01',
            name       => 'IBM Model M Buckling Spring 101',
            qty        => 1,
            unit_price => '189.5000',
            line_total => '189.5000',
        },
    ],
);
my $kb_now = $db->get_product('KB-M01');
$db->update_product_stock('KB-M01', $kb_now->{stock} + 1);

my $olap = $db->category_olap;
ok(scalar(@$olap) >= 3, 'category_olap returned >= 2 categories + ROLLUP grand total row');
my $total_row = $olap->[-1];
is($total_row->{category}, 'ALL CATEGORIES', 'ROLLUP grand total row is last and labeled ALL CATEGORIES');
is($total_row->{rank},     0,                'ROLLUP grand total row has rank == 0');
cmp_ok(MT::Decimal->new($total_row->{share_pct}), '==', MT::Decimal->new('100.00'), 'ROLLUP grand total share_pct == 100.00%');

my $sum_cat_rev   = MT::Decimal->new('0');
my $sum_cat_units = 0;
for my $row (@$olap[0 .. $#$olap - 1]) {
    cmp_ok($row->{rank}, '>=', 1, "category '$row->{category}' has window RANK() >= 1");
    $sum_cat_rev   = $sum_cat_rev + MT::Decimal->new($row->{revenue});
    $sum_cat_units += int($row->{units_sold});
}
cmp_ok($sum_cat_rev, '==', MT::Decimal->new($total_row->{revenue}), 'ROLLUP grand total revenue matches exact MT::Decimal sum of categories');
is($sum_cat_units, int($total_row->{units_sold}), 'ROLLUP grand total units_sold matches sum of categories');

done_testing;
