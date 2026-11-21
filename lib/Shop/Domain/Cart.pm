package Shop::Domain::Cart;

use strict;
use warnings;
use Shop::Domain::Pricing;

# Shopping cart backed by in-process Inventory lock-free CAS + optional KeyDB TTL leases.

sub new {
    my ($class, %opt) = @_;
    die "Shop::Domain::Cart: inventory required\n" unless $opt{inventory};
    return bless {
        user_fp   => $opt{user_fp}   // 'guest',
        inventory => $opt{inventory},
        keydb     => $opt{keydb},
        db        => $opt{db},
        lease_ttl => $opt{lease_ttl} // 900,
        items     => {},   # sku => qty
        promo     => undef,
    }, $class;
}

sub add {
    my ($self, $sku, $qty) = @_;
    $qty = int($qty // 1);
    return { ok => 0, error => 'Quantity must be positive' } if $qty <= 0;

    my $prod = $self->{inventory}->get_product($sku);
    return { ok => 0, error => "Unknown product '$sku'" } unless $prod;

    my ($ok, $rem) = $self->{inventory}->reserve($sku, $qty);
    if (!$ok) {
        return { ok => 0, error => "Insufficient stock for $sku (available: $rem)", stock => $rem };
    }

    $self->{items}{$sku} = ($self->{items}{$sku} // 0) + $qty;
    if ($self->{keydb}) {
        eval { $self->{keydb}->reserve_cart_lease($self->{user_fp}, $sku, $qty, $self->{lease_ttl}); };
    }
    return { ok => 1, sku => $sku, qty => $self->{items}{$sku}, stock => $rem };
}

sub remove {
    my ($self, $sku, $qty) = @_;
    my $cur = $self->{items}{$sku} // 0;
    return { ok => 1, sku => $sku, qty => 0 } if $cur <= 0;

    my $rel = (defined $qty && int($qty) < $cur) ? int($qty) : $cur;
    return { ok => 0, error => 'Quantity must be positive' } if $rel <= 0;

    my $rem_stock = $self->{inventory}->release($sku, $rel);
    my $new_qty   = $cur - $rel;
    if ($new_qty <= 0) {
        delete $self->{items}{$sku};
    }
    else {
        $self->{items}{$sku} = $new_qty;
    }

    if ($self->{keydb}) {
        eval { $self->{keydb}->release_cart_lease($self->{user_fp}, $sku, $rel); };
    }
    return { ok => 1, sku => $sku, qty => $new_qty, stock => $rem_stock };
}

sub set_qty {
    my ($self, $sku, $new_qty) = @_;
    $new_qty = int($new_qty // 0);
    my $cur = $self->{items}{$sku} // 0;
    if ($new_qty <= 0) {
        return $self->remove($sku);
    }
    elsif ($new_qty > $cur) {
        return $self->add($sku, $new_qty - $cur);
    }
    elsif ($new_qty < $cur) {
        return $self->remove($sku, $cur - $new_qty);
    }
    return { ok => 1, sku => $sku, qty => $cur };
}

sub apply_promo {
    my ($self, $code) = @_;
    $code //= '';
    $code =~ s/^\s+|\s+$//g;
    if (!length $code) {
        $self->{promo} = undef;
        return { ok => 1, promo => undef };
    }
    my $promo;
    if ($self->{db}) {
        $promo = $self->{db}->get_promo($code);
    }
    else {
        # Fallback built-in promos when DB not passed
        my %builtin = (
            PERLMT20 => { code => 'PERLMT20', kind => 'percent', value => '20.0000', min_subtotal => '0.0000' },
            SSH10    => { code => 'SSH10',    kind => 'fixed',   value => '10.0000', min_subtotal => '50.0000' },
        );
        $promo = $builtin{uc($code)};
    }
    return { ok => 0, error => "Invalid promo code '$code'" } unless $promo;
    $self->{promo} = $promo;
    return { ok => 1, promo => $promo };
}

sub clear_promo {
    my ($self) = @_;
    $self->{promo} = undef;
    return 1;
}

sub promo { $_[0]->{promo} }

sub items {
    my ($self) = @_;
    my @out;
    for my $sku (sort keys %{ $self->{items} }) {
        my $qty = $self->{items}{$sku};
        next if $qty <= 0;
        my $p = $self->{inventory}->get_product($sku) || { sku => $sku, name => $sku, price => '0.00', stock => 0 };
        my $unit = Shop::Domain::Pricing::quant($p->{price});
        my $line = Shop::Domain::Pricing::quant($unit * Shop::Domain::Pricing::dec($qty));
        push @out, {
            sku        => $sku,
            name       => $p->{name},
            price      => $unit,
            unit_price => $unit,
            qty        => $qty,
            line_total => $line,
            stock      => $p->{stock},
        };
    }
    return \@out;
}

sub item_count {
    my ($self) = @_;
    my $n = 0;
    $n += $_ for values %{ $self->{items} };
    return $n;
}

sub totals {
    my ($self) = @_;
    return Shop::Domain::Pricing::calculate($self->items, promo => $self->{promo});
}

sub clear {
    my ($self, %opt) = @_;
    my $release = exists $opt{release_stock} ? $opt{release_stock} : 1;
    if ($release) {
        for my $sku (keys %{ $self->{items} }) {
            my $qty = $self->{items}{$sku};
            $self->{inventory}->release($sku, $qty) if $qty > 0;
        }
    }
    $self->{items} = {};
    $self->{promo} = undef;
    if ($self->{keydb}) {
        eval { $self->{keydb}->clear_cart($self->{user_fp}); };
    }
    return 1;
}

1;
