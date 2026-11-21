package Shop::Domain::Pricing;

use strict;
use warnings;
use MT::Decimal;

# 100% IEEE 754-2008 decimal128 financial arithmetic (ROUND_HALF_UP, quantize(-2)).
# Zero binary floating-point rounding drift.

use constant {
    DEFAULT_TAX_RATE    => '0.0825',
    FREE_SHIP_THRESHOLD => '75.00',
    FLAT_SHIPPING       => '7.95',
};

sub dec {
    my ($val) = @_;
    return $val if ref($val) && $val->isa('MT::Decimal');
    return MT::Decimal->new(defined $val && length($val) ? "$val" : '0');
}

sub quant {
    my ($val) = @_;
    return dec($val)->quantize(-2, MT::Decimal::ROUND_HALF_UP);
}

sub money {
    my ($val) = @_;
    return '' . quant($val);
}

sub calculate {
    my ($items, %opt) = @_;
    # Allow both Shop::Domain::Pricing->calculate(...) and Shop::Domain::Pricing::calculate(...)
    if (defined $items && !ref($items) && $items eq __PACKAGE__) {
        $items = shift;
        %opt   = @_;
    }
    $items ||= [];

    local $MT::Decimal::ROUND_MODE = MT::Decimal::ROUND_HALF_UP;

    my $zero     = quant('0.00');
    my $subtotal = $zero;
    my $count    = 0;
    my @lines;

    for my $it (@$items) {
        my $qty  = int($it->{qty} // 0);
        next if $qty <= 0;
        my $unit = dec($it->{unit_price} // $it->{price} // '0');
        my $line = quant($unit * dec($qty));
        $subtotal = quant($subtotal + $line);
        $count   += $qty;
        push @lines, {
            sku        => $it->{sku},
            name       => $it->{name} // $it->{sku},
            qty        => $qty,
            unit_price => quant($unit),
            line_total => $line,
        };
    }

    my $discount      = $zero;
    my $promo_applied = undef;
    my $promo_error   = undef;

    if (my $promo = $opt{promo}) {
        my $min = dec($promo->{min_subtotal} // '0');
        if ($subtotal < $min) {
            $promo_error = sprintf('Promo %s requires minimum subtotal $%s', $promo->{code}, money($min));
        }
        else {
            my $kind = lc($promo->{kind} // '');
            my $val  = dec($promo->{value} // '0');
            if ($kind eq 'percent') {
                $discount = quant(($subtotal * $val) / dec('100'));
            }
            elsif ($kind eq 'fixed') {
                $discount = quant($val);
            }
            if ($discount > $subtotal) {
                $discount = $subtotal;
            }
            $promo_applied = $promo->{code};
        }
    }

    my $taxable  = quant($subtotal - $discount);
    my ($tax_rate, $tax, $nexus_status);
    if (ref($opt{tax_result}) eq 'HASH') {
        $tax_rate     = dec($opt{tax_result}{rate} // '0');
        $tax          = $count > 0 ? quant($opt{tax_result}{tax} // '0.00') : $zero;
        $nexus_status = $opt{tax_result}{nexus_status};
    }
    elsif (defined $opt{tax_override}) {
        $tax_rate = dec($opt{tax_rate} // '0');
        $tax      = $count > 0 ? quant($opt{tax_override}) : $zero;
    }
    else {
        $tax_rate = dec($opt{tax_rate} // DEFAULT_TAX_RATE);
        $tax      = $count > 0 ? quant($taxable * $tax_rate) : $zero;
    }

    my ($free_shipping, $shipping, $shipping_carrier, $shipping_service);
    if (ref($opt{shipping_rate}) eq 'HASH' && defined $opt{shipping_rate}{amount}) {
        $shipping         = $count > 0 ? quant($opt{shipping_rate}{amount}) : $zero;
        $free_shipping    = ($shipping == $zero) ? 1 : 0;
        $shipping_carrier = $opt{shipping_rate}{carrier};
        $shipping_service = $opt{shipping_rate}{service};
    }
    elsif (defined $opt{shipping_override}) {
        $shipping      = $count > 0 ? quant($opt{shipping_override}) : $zero;
        $free_shipping = ($shipping == $zero) ? 1 : 0;
    }
    else {
        my $free_threshold = dec($opt{free_ship_threshold} // FREE_SHIP_THRESHOLD);
        my $flat_ship      = dec($opt{flat_shipping}       // FLAT_SHIPPING);
        $free_shipping     = ($count == 0 || $taxable >= $free_threshold) ? 1 : 0;
        $shipping          = $free_shipping ? $zero : quant($flat_ship);
    }

    my $total = quant($taxable + $tax + $shipping);

    return {
        subtotal         => $subtotal,
        discount         => $discount,
        tax              => $tax,
        tax_rate         => $tax_rate,
        nexus_status     => $nexus_status,
        shipping         => $shipping,
        shipping_carrier => $shipping_carrier,
        shipping_service => $shipping_service,
        total            => $total,
        free_shipping    => $free_shipping,
        item_count       => $count,
        promo_applied    => $promo_applied,
        promo_error      => $promo_error,
        lines            => \@lines,
    };
}

1;
