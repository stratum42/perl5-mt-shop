#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 'lib';
use Shop::Domain::Pricing;

# 1. Exact decimal128: no binary float drift
my $d1 = Shop::Domain::Pricing::dec('0.1');
my $d2 = Shop::Domain::Pricing::dec('0.2');
is(Shop::Domain::Pricing::money($d1 + $d2), '0.30', '0.1 + 0.2 == 0.30 exact');

# 2. ROUND_HALF_UP verification
is(Shop::Domain::Pricing::money('19.995'), '20.00', '19.995 rounds half-up to 20.00');
is(Shop::Domain::Pricing::money('1.005'),  '1.01',  '1.005 rounds half-up to 1.01');
is(Shop::Domain::Pricing::money('1.004'),  '1.00',  '1.004 rounds to 1.00');

# 3. Empty cart
my $empty = Shop::Domain::Pricing::calculate([]);
is("$empty->{subtotal}", '0.00', 'empty subtotal');
is("$empty->{shipping}", '0.00', 'empty shipping');
is("$empty->{total}",    '0.00', 'empty total');
is($empty->{item_count}, 0,      'empty item_count');

# 4. Under $75 -> $7.95 flat shipping + 8.25% tax
my $under = Shop::Domain::Pricing::calculate([
    { sku => 'AC-MUG', name => 'Mug', price => '19.9500', qty => 2 },
]);
is("$under->{subtotal}", '39.90', 'subtotal 2 * 19.95 = 39.90');
is("$under->{discount}", '0.00',  'no discount');
# 39.90 * 0.0825 = 3.29175 -> 3.29
is("$under->{tax}",      '3.29',  'tax 39.90 * 0.0825 = 3.29');
is("$under->{shipping}", '7.95',  'flat shipping $7.95 under $75');
is($under->{free_shipping}, 0,    'not free shipping');
is("$under->{total}",    '51.14', 'total 39.90 + 3.29 + 7.95 = 51.14');

# 5. Exactly $75.00 -> FREE shipping
my $at75 = Shop::Domain::Pricing::calculate([
    { sku => 'TEST', price => '25.00', qty => 3 },
]);
is("$at75->{subtotal}", '75.00', 'subtotal 75.00');
is("$at75->{shipping}", '0.00',  'free shipping at >= $75.00');
is($at75->{free_shipping}, 1,    'free_shipping flag = 1');
# 75.00 * 0.0825 = 6.1875 -> 6.19
is("$at75->{tax}",   '6.19',  'tax 6.1875 rounds half-up to 6.19');
is("$at75->{total}", '81.19', 'total 75.00 + 6.19 = 81.19');

# 6. Promo PERLMT20 (20% off)
my $p20 = { code => 'PERLMT20', kind => 'percent', value => '20.0000', min_subtotal => '0.0000' };
my $r20 = Shop::Domain::Pricing::calculate(
    [{ sku => 'KB-M01', price => '189.5000', qty => 1 }],
    promo => $p20,
);
is("$r20->{subtotal}", '189.50', 'subtotal 189.50');
is("$r20->{discount}", '37.90',  '20% discount = 37.90');
# taxable = 151.60; tax = 151.60 * 0.0825 = 12.507 -> 12.51
is("$r20->{tax}",      '12.51',  'tax on discounted subtotal = 12.51');
is("$r20->{shipping}", '0.00',   'free shipping on 151.60');
is("$r20->{total}",    '164.11', 'total 151.60 + 12.51 = 164.11');
is($r20->{promo_applied}, 'PERLMT20', 'promo_applied set');

# 7. Promo SSH10 ($10 off over $50): rejected under $50, applied over $50
my $p10 = { code => 'SSH10', kind => 'fixed', value => '10.0000', min_subtotal => '50.0000' };
my $r10_fail = Shop::Domain::Pricing::calculate(
    [{ sku => 'SW-001', price => '32.00', qty => 1 }],
    promo => $p10,
);
is("$r10_fail->{discount}", '0.00', 'SSH10 rejected under $50');
ok(defined $r10_fail->{promo_error}, 'promo_error populated');

my $r10_ok = Shop::Domain::Pricing::calculate(
    [{ sku => 'BK-KRN', price => '54.00', qty => 1 }],
    promo => $p10,
);
is("$r10_ok->{discount}", '10.00', 'SSH10 applied over $50');
is($r10_ok->{promo_applied}, 'SSH10', 'SSH10 promo_applied');
is("$r10_ok->{shipping}", '7.95', 'shipping applies after discount (44.00 < 75.00)');

done_testing;
