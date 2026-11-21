#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(sleep);
use lib 'lib';

use MT::Decimal;
use Shop::DB;
use Shop::TUI::View::Admin;

my $gw = $ENV{INFORMIX_GATEWAY_URL} // 'http://127.0.0.1:50051';
my $db = Shop::DB->new({ driver => 'informix', informix_gateway_url => $gw });

if (!$db->health) {
    plan skip_all => "Live IBM Informix gateway not reachable at $gw";
}

my $run_id = sprintf('%d%03d', time() % 100000, int(rand(1000)));

# =========================================================================
# 1. Engine capabilities, SP_ONLY metadata & Admin TUI banner
# =========================================================================
my $feat = $db->db2_features;
is($feat->{engine},      'IBM Informix Innovator-C', 'db2_features engine == IBM Informix Innovator-C');
is($feat->{driver},      'informix',                 'db2_features driver == informix');
is($feat->{decfloat34},  0,                          'db2_features decfloat34 == 0');
is($feat->{decimal32},   1,                          'db2_features decimal32 == 1');
is($feat->{temporal},    1,                          'db2_features temporal == 1');
is($feat->{spl_procs},   1,                          'db2_features spl_procs == 1');
is($feat->{sp_only},     1,                          'db2_features sp_only == 1');
is($feat->{final_table}, 0,                          'db2_features final_table == 0');
is($feat->{merge},       1,                          'db2_features merge == 1');
is($feat->{compression}, 'ROW',                      'db2_features compression == ROW');
is($feat->{olap_rollup}, 1,                          'db2_features olap_rollup == 1');

my $admin = Shop::TUI::View::Admin->new();
$admin->{db2_features} = $feat;
my ($banner, $is_enterprise) = $admin->_db2_engine_banner({ db => $db }, 120);
is(
    $banner,
    'IBM Informix | SP-ONLY (SQLi Blocked) | SPL Procedures | DECIMAL(32,4) | Trigger Audit | ROLLUP OLAP',
    'Admin TUI shows exact IBM Informix SP-ONLY banner'
);
is($is_enterprise, 1, 'Admin TUI marks Informix as enterprise engine');

# =========================================================================
# 2. INFORMIX_SP_ONLY=1 Ad-Hoc SQL Blocking
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
ok(!defined $sqli_prod, 'SQLi payload in shop_sp_get_product is completely inert');

my $sqli_user = $db->get_user("' OR '1'='1");
ok(!defined $sqli_user, 'SQLi payload in shop_sp_get_user is completely inert');

my $seeded = $db->list_products;
ok(scalar(@$seeded) >= 12, 'products table untouched after SQLi attempts (' . scalar(@$seeded) . ' active)');

# =========================================================================
# 3. DECIMAL(32,4) 32-digit exact round-trip matching MT::Decimal
# =========================================================================
my $sku_dec = "T-DEC-$run_id";
my $val_32  = '1234567890123456789012345678.1234';
my $mt_32   = MT::Decimal->new($val_32);

ok($db->upsert_product({
    sku         => $sku_dec,
    name        => 'DECIMAL(32,4) Precision Probe',
    category    => 'Precision',
    description => '32-digit Informix DECIMAL(32,4) test',
    ascii_art   => '',
    price       => "$mt_32",
    stock       => 5,
    active      => 0,
}), 'upserted DECIMAL(32,4) test product via MERGE SPL');

my $got_dec = $db->get_product($sku_dec);
is($got_dec->{price}, $val_32, 'DECIMAL(32,4) preserves all 32 significant digits verbatim');
is("" . MT::Decimal->new($got_dec->{price}), "$mt_32", 'exact MT::Decimal parity with Informix DECIMAL(32,4)');

# Small decimal must never drift to scientific notation
$db->upsert_product({ sku => $sku_dec, price => '0.0001' });
my $got_small = $db->get_product($sku_dec);
is($got_small->{price}, '0.0001', 'DECIMAL(32,4) small decimal serialized without scientific notation drift');

# =========================================================================
# 4. DB Engine CHECK Constraints (stock >= 0, price >= 0, qty > 0)
# =========================================================================
eval { $db->update_product_stock($sku_dec, -5); };
like($@, qr/-530|23513|check constraint/i, 'CHECK (stock >= 0) rejects negative stock at Informix engine level');

eval { $db->upsert_product({ sku => $sku_dec, price => '-9.99' }); };
like($@, qr/-530|23513|check constraint/i, 'CHECK (price >= 0) rejects negative price at Informix engine level');

eval {
    $db->txn(sub {
        my ($tx) = @_;
        $tx->sp_call('SHOP_SP_ADD_ORDER_ITEM', "BAD-$run_id", "ORD-BAD-$run_id", $sku_dec, 'Bad Qty', 0, '1.0000', '0.0000');
    });
};
like($@, qr/-530|23513|check constraint/i, 'CHECK (qty > 0) rejects zero qty at Informix engine level');

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

# Partial update: only change price; name & stock must be preserved via NVL
my $ts_before_mutate = $db->current_timestamp;
ok(length($ts_before_mutate) >= 19, "captured Informix DATETIME YEAR TO FRACTION(5): $ts_before_mutate");
# Informix CURRENT YEAR TO FRACTION(5) ticks at 1s resolution unless USEOSTIME=1
sleep(1.1);

$db->upsert_product({ sku => $sku_mrg, price => '149.9500' });
my $m2 = $db->get_product($sku_mrg);
is($m2->{name},  'Merge Initial Name', 'MERGE INTO partial update preserved existing name');
is($m2->{price}, '149.9500',           'MERGE INTO partial update changed price');
is($m2->{stock}, 20,                   'MERGE INTO partial update preserved stock');

# User MERGE INTO upsert
my $fp = "SHA256:ifxsuper_$run_id";
my $u1 = $db->upsert_user({ fingerprint => $fp, username => 'ifxtester', email => 'ifx@example.com', is_admin => 1 });
is($u1->{username}, 'ifxtester', 'MERGE INTO users inserted user');
my $u2 = $db->upsert_user({ fingerprint => $fp, email => 'updated@example.com' });
is($u2->{username}, 'ifxtester',           'MERGE INTO users partial update preserved username');
is($u2->{email},    'updated@example.com', 'MERGE INTO users partial update changed email');

# =========================================================================
# 6. Atomic Stock Decrement via SPL + DBINFO('sqlca.sqlerrd2')
# =========================================================================
sleep(0.05);
my $dec_row = $db->decrement_product_stock($sku_mrg, 3);
ok(defined $dec_row, 'shop_sp_decrement_stock returned updated row');
is($dec_row->{sku},   $sku_mrg, 'decrement returned matching SKU');
is($dec_row->{stock}, 17,       'atomically decremented stock 20 -> 17');

my $over_dec = $db->decrement_product_stock($sku_mrg, 99999);
ok(!defined $over_dec, 'shop_sp_decrement_stock returns undef when stock < requested qty');
is($db->get_product($sku_mrg)->{stock}, 17, 'stock unchanged after rejected decrement');

# =========================================================================
# 7. SPL + CREATE TRIGGER Audit History (products_audit + catalog_as_of)
# =========================================================================
my $phist = $db->product_history($sku_mrg, 10);
ok(scalar(@$phist) >= 3, 'product_history (SPL Trigger Audit) captured insert + price update + stock decrement (' . scalar(@$phist) . ' versions)');
is($phist->[0]{stock},  17,         'newest audit version has stock == 17');
is($phist->[0]{price},  '149.9500', 'newest audit version has price == 149.9500');
is($phist->[-1]{price}, '100.0000', 'oldest audit version preserved original price == 100.0000');
is($phist->[-1]{stock}, 20,         'oldest audit version preserved original stock == 20');
ok(length($phist->[0]{sys_start}) >= 19 && length($phist->[0]{sys_end}) >= 19, 'audit rows carry sys_start & sys_end');

# Time-travel AS OF before mutations
my $past_cat = $db->catalog_as_of($ts_before_mutate);
my ($past_mrg) = grep { $_->{sku} eq $sku_mrg } @$past_cat;
ok(defined $past_mrg, 'shop_sp_catalog_as_of recovered product snapshot before mutation');
is($past_mrg->{price}, '100.0000', 'AS OF time-travel recovered exact old price (100.0000)');
is($past_mrg->{stock}, 20,         'AS OF time-travel recovered exact old stock (20)');

# =========================================================================
# 8. Orders Trigger Audit Lifecycle (pending -> paid -> shipped) + Masked View
# =========================================================================
my $ord_id = "ORD-IFX-$run_id";
my $ord = $db->create_order(
    {
        id               => $ord_id,
        user_fp          => $fp,
        username         => 'ifxtester',
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
is($u_paid->{status}, 'paid', 'shop_sp_update_order_status transitioned pending -> paid');

sleep(0.05);
my $u_ship = $db->update_order_status($ord_id, 'shipped');
is($u_ship->{status}, 'shipped', 'shop_sp_update_order_status transitioned paid -> shipped');

my $ohist = $db->order_history($ord_id);
is(scalar(@$ohist), 3, 'orders trigger audit automatically captured all 3 lifecycle versions');
my @statuses = map { $_->{status} } @$ohist;
is_deeply(\@statuses, ['shipped', 'paid', 'pending'], 'order audit trail: shipped -> paid -> pending');

# Restore VT-220 stock so seeded stock remains healthy
my $vt_now = $db->get_product('VT-220');
$db->update_product_stock('VT-220', $vt_now->{stock} + 1);

# Masked view check
my $masked = $db->list_orders_masked($fp);
ok(@$masked >= 1, 'v_orders_masked returned user order');
like($masked->[0]{shipping_address}, qr/\*\*\*MASKED\*\*\*/, 'v_orders_masked masks shipping_address PII');

# =========================================================================
# 9. Category OLAP (SPL Rollup + Rank + Share %)
# =========================================================================
my $ord_id2 = "ORD-IFX2-$run_id";
$db->create_order(
    {
        id               => $ord_id2,
        user_fp          => $fp,
        username         => 'ifxtester',
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
    cmp_ok($row->{rank}, '>=', 1, "category '$row->{category}' has rank >= 1");
    $sum_cat_rev   = $sum_cat_rev + MT::Decimal->new($row->{revenue});
    $sum_cat_units += int($row->{units_sold});
}
cmp_ok($sum_cat_rev, '==', MT::Decimal->new($total_row->{revenue}), 'ROLLUP grand total revenue matches exact MT::Decimal sum of categories');
is($sum_cat_units, int($total_row->{units_sold}), 'ROLLUP grand total units_sold matches sum of categories');

done_testing;
