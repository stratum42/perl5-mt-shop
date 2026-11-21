package Shop::State::Inventory;

use strict;
use warnings;
use MT;
use MT::SharedHash;
use MT::Cell;
use MT::Checkpoint;
sub _enc_json { MT::Pool::_encode_list($_[0]) }
sub _dec_json { my ($v) = MT::Pool::_decode_list($_[0]); return $v }

# Hot in-process inventory state backed by perl5-mt MT::SharedHash + per-SKU MT::Cell.
# Zero DB/KeyDB egress on hot catalog reads and lock-free CAS stock reservations.

sub new {
    my ($class, %opt) = @_;
    return bless {
        products   => MT::SharedHash->new,
        cells      => MT::SharedHash->new,
        cell_cache => {},
        metrics    => $opt{metrics},
    }, $class;
}

sub attach {
    my ($class, $ids, %opt) = @_;
    return bless {
        products   => MT::SharedHash->attach($ids->{products_id}),
        cells      => MT::SharedHash->attach($ids->{cells_id}),
        cell_cache => {},
        metrics    => $opt{metrics},
    }, $class;
}

sub set_metrics {
    my ($self, $metrics) = @_;
    $self->{metrics} = $metrics;
    return $self;
}

sub state_ids {
    my ($self) = @_;
    return {
        products_id => $self->{products}->id,
        cells_id    => $self->{cells}->id,
    };
}

sub _get_cell {
    my ($self, $sku) = @_;
    return $self->{cell_cache}{$sku} if exists $self->{cell_cache}{$sku};
    my $cid = $self->{cells}->get($sku);
    return undef unless defined $cid;
    my $cell = MT::Cell->attach($cid);
    $self->{cell_cache}{$sku} = $cell;
    return $cell;
}

sub _ensure_cell {
    my ($self, $sku, $initial_stock) = @_;
    my $cell = $self->_get_cell($sku);
    if ($cell) {
        $cell->set(int($initial_stock)) if defined $initial_stock;
        return $cell;
    }
    $cell = MT::Cell->new(int($initial_stock // 0));
    $self->{cells}->set($sku, $cell->id);
    $self->{cell_cache}{$sku} = $cell;
    return $cell;
}

sub load_from_db {
    my ($self, $db) = @_;
    my $products = $db->list_products;
    for my $p (@$products) {
        $self->upsert_product($p);
    }
    return scalar(@$products);
}

sub upsert_product {
    my ($self, $p) = @_;
    my $sku = $p->{sku} or die "Inventory::upsert_product: sku required\n";
    my %meta = (
        sku         => $sku,
        name        => $p->{name}        // $sku,
        category    => $p->{category}    // 'General',
        description => $p->{description} // '',
        ascii_art   => $p->{ascii_art}   // '',
        price       => defined $p->{price} ? "$p->{price}" : '0.0000',
        active      => defined $p->{active} ? int($p->{active}) : 1,
    );
    $self->{products}->set($sku, _enc_json(\%meta));
    my $stock = defined $p->{stock} ? int($p->{stock}) : ($self->get_stock($sku) // 0);
    $self->_ensure_cell($sku, $stock);
    return 1;
}

sub get_stock {
    my ($self, $sku) = @_;
    my $cell = $self->_get_cell($sku);
    return undef unless $cell;
    return int($cell->get);
}

sub set_stock {
    my ($self, $sku, $qty) = @_;
    $qty = int($qty);
    $qty = 0 if $qty < 0;
    my $cell = $self->_ensure_cell($sku, $qty);
    $cell->set($qty);
    return $qty;
}

# Lock-free CAS reservation: atomically decrements stock if current >= $qty.
# Returns (1, $new_stock) in list context or 1 in scalar context on success;
# (0, $cur_stock) or 0 on failure / insufficient stock.
sub reserve {
    my ($self, $sku, $qty) = @_;
    $qty = int($qty // 0);
    return wantarray ? (0, 0) : 0 if $qty <= 0;
    my $cell = $self->_get_cell($sku);
    return wantarray ? (0, 0) : 0 unless $cell;

    while (1) {
        my $cur = int($cell->get);
        if ($cur < $qty) {
            return wantarray ? (0, $cur) : 0;
        }
        my $next = $cur - $qty;
        if ($cell->cas($cur, $next)) {
            $self->{metrics}->inc('inventory_cas_ok_total', 1) if $self->{metrics};
            return wantarray ? (1, $next) : 1;
        }
        $self->{metrics}->inc('inventory_cas_conflict_total', 1) if $self->{metrics};
    }
}

# Lock-free CAS release: atomically adds $qty back to stock.
sub release {
    my ($self, $sku, $qty) = @_;
    $qty = int($qty // 0);
    my $cell = $self->_get_cell($sku);
    return undef unless $cell;
    return int($cell->get) if $qty <= 0;

    while (1) {
        my $cur  = int($cell->get);
        my $next = $cur + $qty;
        if ($cell->cas($cur, $next)) {
            return $next;
        }
    }
}

sub get_product {
    my ($self, $sku) = @_;
    my $raw = $self->{products}->get($sku);
    return undef unless defined $raw;
    my $p = _dec_json($raw);
    $p->{stock} = $self->get_stock($sku) // 0;
    return $p;
}

sub list_catalog {
    my ($self, %opt) = @_;
    my $cat = $opt{category};
    my $q   = defined $opt{query} ? lc($opt{query}) : undef;
    my @skus = sort $self->{products}->keys;
    my @out;
    for my $sku (@skus) {
        my $p = $self->get_product($sku);
        next unless $p && $p->{active};
        next if defined $cat && length $cat && lc($cat) ne 'all' && lc($p->{category}) ne lc($cat);
        if (defined $q && length $q) {
            my $hay = lc("$p->{sku} $p->{name} $p->{category} $p->{description}");
            next if index($hay, $q) < 0;
        }
        push @out, $p;
    }
    return \@out;
}

sub save_checkpoint {
    my ($self, $path) = @_;
    my @skus = sort $self->{products}->keys;
    my @items;
    for my $sku (@skus) {
        my $p = $self->get_product($sku);
        push @items, $p if $p;
    }
    return MT::Checkpoint::save({ version => 1, ts => time(), products => \@items }, file => $path);
}

sub load_checkpoint {
    my ($self, $path) = @_;
    my $snap = MT::Checkpoint::restore(file => $path);
    return 0 unless $snap && ref($snap) eq 'HASH' && ref($snap->{products}) eq 'ARRAY';
    for my $p (@{ $snap->{products} }) {
        $self->upsert_product($p);
    }
    return scalar(@{ $snap->{products} });
}

1;
