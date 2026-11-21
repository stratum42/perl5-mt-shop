package Shop::Domain::Checkout;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64 decode_base64);
use Shop::Domain::JSON ();
use Shop::Domain::Pricing;
use Shop::Domain::Cart;
use Shop::Payment::Mock;
use Shop::Shipping::Shippo;

# Checkout saga:
# 1. Validate non-empty cart + compute exact MT::Decimal totals
# 2. Execute Payment adapter (Mock or Stripe)
# 3. Compute canonical receipt SHA-256 hash + Ed25519 signature (if hostkey provided)
# 4. Commit ACID order + order_items + stock decrement in DB
# 5. Clear cart (keeping CAS reservations permanently consumed)
# 6. Broadcast order_placed + stock_changed on EventBus (and KeyDB Pub/Sub)

sub new {
    my ($class, %opt) = @_;
    die "Shop::Domain::Checkout: db required\n"        unless $opt{db};
    die "Shop::Domain::Checkout: inventory required\n" unless $opt{inventory};
    return bless {
        db         => $opt{db},
        inventory  => $opt{inventory},
        event_bus  => $opt{event_bus},
        keydb      => $opt{keydb},
        payment    => $opt{payment} // Shop::Payment::Mock->new,
        hostkey    => $opt{hostkey},
        metrics    => $opt{metrics},
        shippo     => $opt{shippo},
        tax_nexus  => $opt{tax_nexus},
        membership => $opt{membership},
    }, $class;
}

sub _format_address {
    my ($addr) = @_;
    return '' unless defined $addr;
    return "$addr" unless ref($addr) eq 'HASH';
    my @parts = grep { defined $_ && length $_ } (
        $addr->{recipient},
        $addr->{line1},
        $addr->{line2},
        join(', ', grep { defined $_ && length $_ } ($addr->{city}, $addr->{state}, $addr->{postal_code})),
        $addr->{country},
    );
    return join(' | ', @parts);
}

sub _extract_sk {
    my ($hk) = @_;
    return undef unless defined $hk;
    return $hk->{sk} if ref($hk) eq 'HASH';
    return $hk;
}

sub _extract_pk {
    my ($pk) = @_;
    return undef unless defined $pk;
    return $pk->{pk} if ref($pk) eq 'HASH';
    return $pk;
}

sub _const_eq {
    my ($a, $b) = @_;
    return 0 unless defined $a && defined $b;
    return 0 if length($a) != length($b);
    my $diff = 0;
    for my $i (0 .. length($a) - 1) {
        $diff |= ord(substr($a, $i, 1)) ^ ord(substr($b, $i, 1));
    }
    return $diff == 0 ? 1 : 0;
}

sub canonical_receipt_json {
    my ($order) = @_;
    if (defined $order && !ref($order) && $order eq __PACKAGE__) {
        $order = $_[1];
    }
    return '' unless ref($order) eq 'HASH';

    my @items = map {
        {
            sku        => '' . ($_->{sku} // ''),
            qty        => int($_->{qty} // 0),
            unit_price => Shop::Domain::Pricing::money($_->{unit_price} // '0.00'),
            line_total => Shop::Domain::Pricing::money($_->{line_total} // '0.00'),
        }
    } sort { ($a->{sku} // '') cmp ($b->{sku} // '') } @{ $order->{items} || [] };

    my $doc = {
        id               => '' . ($order->{id}               // ''),
        user_fp          => '' . ($order->{user_fp}          // ''),
        username         => '' . ($order->{username}         // ''),
        subtotal         => Shop::Domain::Pricing::money($order->{subtotal} // '0.00'),
        discount         => Shop::Domain::Pricing::money($order->{discount} // '0.00'),
        tax              => Shop::Domain::Pricing::money($order->{tax}      // '0.00'),
        shipping         => Shop::Domain::Pricing::money($order->{shipping} // '0.00'),
        total            => Shop::Domain::Pricing::money($order->{total}    // '0.00'),
        promo_code       => '' . ($order->{promo_code}       // ''),
        payment_method   => '' . ($order->{payment_method}   // ''),
        payment_ref      => '' . ($order->{payment_ref}      // ''),
        shipping_address => '' . ($order->{shipping_address} // ''),
        items            => \@items,
    };

    return Shop::Domain::JSON::encode_json($doc);
}

sub sign_receipt {
    my ($order, $hostkey) = @_;
    if (defined $order && !ref($order) && $order eq __PACKAGE__) {
        ($order, $hostkey) = ($_[1], $_[2]);
    }
    my $canonical = canonical_receipt_json($order);
    my $hash      = sha256_hex($canonical);
    my $sig_b64   = '';

    my $sk64 = _extract_sk($hostkey);
    if (defined $sk64 && length($sk64) == 64) {
        require Shop::SSH::Crypto;
        my $sig64 = Shop::SSH::Crypto::ed25519_sign($canonical, $sk64);
        $sig_b64  = encode_base64($sig64, '');
    }

    return ($hash, $sig_b64);
}

sub verify_receipt {
    my ($order, $hostkey_pk) = @_;
    if (defined $order && !ref($order) && $order eq __PACKAGE__) {
        ($order, $hostkey_pk) = ($_[1], $_[2]);
    }
    return 0 unless ref($order) eq 'HASH';
    my $sig_b64 = $order->{receipt_sig}  // '';
    my $hash    = $order->{receipt_hash} // '';
    return 0 unless length($sig_b64) && length($hash);

    my $pk32 = _extract_pk($hostkey_pk);
    return 0 unless defined $pk32 && length($pk32) == 32;

    my $canonical = canonical_receipt_json($order);
    my $expected_hash = sha256_hex($canonical);
    return 0 unless _const_eq($hash, $expected_hash);

    my $sig64 = eval { decode_base64($sig_b64) };
    return 0 unless defined $sig64 && length($sig64) == 64;

    require Shop::SSH::Crypto;
    return Shop::SSH::Crypto::ed25519_verify($canonical, $sig64, $pk32) ? 1 : 0;
}

sub place_order {
    my ($self, %args) = @_;
    my $cart = $args{cart} or return { ok => 0, error => 'Cart is required' };
    my $user = $args{user} || { fingerprint => 'guest', username => 'guest' };
    my $items = $cart->items;
    return { ok => 0, error => 'Cart is empty' } unless @$items;

    my $member_benefits;
    if (ref($args{membership}) eq 'HASH') {
        $member_benefits = $args{membership};
    }
    elsif ($args{membership} && eval { $args{membership}->can('benefits') }) {
        $member_benefits = $args{membership}->benefits($user->{fingerprint});
    }
    elsif ($self->{membership} && eval { $self->{membership}->can('benefits') }
           && defined $user->{fingerprint} && $user->{fingerprint} ne 'guest') {
        $member_benefits = $self->{membership}->benefits($user->{fingerprint});
    }

    my $totals;
    my $tax_nexus     = $args{tax_nexus} // $self->{tax_nexus};
    my $shipping_rate = $args{shipping_rate};
    if ($tax_nexus || $shipping_rate || $member_benefits) {
        my %base_opt = (
            promo => $cart->promo,
            ($member_benefits ? (membership => $member_benefits) : ()),
        );
        my $base    = Shop::Domain::Pricing::calculate($items, %base_opt);
        my $taxable = Shop::Domain::Pricing::quant($base->{subtotal} - $base->{discount});
        my %p_opt   = %base_opt;
        if ($tax_nexus && ref($args{address}) eq 'HASH' && defined $args{address}{state} && length $args{address}{state}) {
            $p_opt{tax_result} = $tax_nexus->calculate(
                state       => $args{address}{state},
                postal_code => $args{address}{postal_code} // $args{address}{zip} // '',
                subtotal    => $taxable,
            );
        }
        if (ref($shipping_rate) eq 'HASH' && defined $shipping_rate->{amount}) {
            $p_opt{shipping_rate} = $shipping_rate;
        }
        $totals = Shop::Domain::Pricing::calculate($items, %p_opt);
    }
    else {
        $totals = $cart->totals;
    }
    my $order_id = sprintf('ORD-%d-%04d', time(), int(rand(10000)));
    my $payment  = $args{payment} || $self->{payment};
    my $method   = $args{payment_method} || ($payment->isa('Shop::Payment::Stripe') ? 'stripe' : 'mock');

    # Step 1: Charge payment adapter
    my $pay_res = $payment->charge(
        amount      => "$totals->{total}",
        currency    => 'usd',
        token       => $args{payment_token} // 'tok_visa',
        order_id    => $order_id,
        description => "perl5-mt-shop order $order_id",
        items       => $items,
    );
    if (!$pay_res || !$pay_res->{ok}) {
        return {
            ok      => 0,
            error   => ($pay_res && $pay_res->{error}) ? $pay_res->{error} : 'Payment failed',
            payment => $pay_res,
        };
    }

    my $shipping_addr = _format_address($args{address});
    my $order_rec = {
        id               => $order_id,
        user_fp          => $user->{fingerprint} // 'guest',
        username         => $user->{username}    // 'guest',
        status           => ($pay_res->{status} // 'paid') eq 'pending_checkout' ? 'pending' : 'paid',
        subtotal         => "$totals->{subtotal}",
        discount         => "$totals->{discount}",
        tax              => "$totals->{tax}",
        shipping         => "$totals->{shipping}",
        total            => "$totals->{total}",
        promo_code       => $totals->{promo_applied} // '',
        payment_method   => $method,
        payment_ref      => $pay_res->{ref} // '',
        shipping_address => $shipping_addr,
        items            => $totals->{lines},
    };

    # Step 2: Sign canonical receipt (SHA-256 + Ed25519 if hostkey configured)
    my $hk = $args{hostkey} // $self->{hostkey};
    my ($receipt_hash, $receipt_sig) = sign_receipt($order_rec, $hk);
    $order_rec->{receipt_hash} = $receipt_hash;
    $order_rec->{receipt_sig}  = $receipt_sig;

    # Step 3: Commit ACID order in DB
    my $order;
    my $db_ok = eval {
        $order = $self->{db}->create_order($order_rec, $totals->{lines});
        1;
    };
    if (!$db_ok) {
        my $err = $@;
        eval { $payment->refund($pay_res->{ref}) if $pay_res->{ref}; };
        return { ok => 0, error => "Order persistence failed: $err" };
    }

    # Step 3b: Automatically create outbound shipment row (PENDING, closest warehouse)
    my $shipment;
    if ($self->{db}->can('create_shipment')) {
        my $warehouses = $self->{db}->can('list_warehouses')
            ? eval { $self->{db}->list_warehouses }
            : undef;
        my $dest_zip = ref($args{address}) eq 'HASH'
            ? ($args{address}{postal_code} // $args{address}{zip} // '')
            : (defined $args{address} && $args{address} =~ /\b(\d{5})\b/ ? $1 : '');
        my $wh = Shop::Shipping::Shippo::pick_warehouse($dest_zip, $warehouses);
        my $wh_code = (ref($shipping_rate) eq 'HASH' && defined $shipping_rate->{warehouse_code} && length $shipping_rate->{warehouse_code})
            ? $shipping_rate->{warehouse_code}
            : ($wh ? $wh->{code} : 'DAL1');
        my $carrier = (ref($shipping_rate) eq 'HASH' && defined $shipping_rate->{carrier})
            ? $shipping_rate->{carrier}
            : 'USPS';
        my $service = (ref($shipping_rate) eq 'HASH' && defined $shipping_rate->{service})
            ? $shipping_rate->{service}
            : 'USPS Ground Advantage';
        my $rate_amt = (ref($shipping_rate) eq 'HASH' && defined $shipping_rate->{amount})
            ? '' . Shop::Domain::Pricing::quant($shipping_rate->{amount})
            : "$totals->{shipping}";
        my $shp_id = sprintf('SHP-%d-%04d', time(), int(rand(10000)));
        $shipment = eval {
            $self->{db}->create_shipment({
                id              => $shp_id,
                order_id        => $order_id,
                warehouse_code  => $wh_code,
                carrier         => $carrier,
                service         => $service,
                rate_amount     => $rate_amt,
                tracking_number => '',
                label_url       => '',
                status          => 'PENDING',
            });
        };
    }

    # Step 4: Clear cart without releasing CAS stock (stock is now sold)
    $cart->clear(release_stock => 0);

    $self->{metrics}->inc('orders_total', 1) if $self->{metrics};

    # Step 5: Broadcast live events across all SSH sessions
    my $ev = {
        type     => 'order_placed',
        order_id => $order_id,
        username => $user->{username} // 'guest',
        total    => "$totals->{total}",
        items    => [ map { { sku => $_->{sku}, qty => $_->{qty}, stock => $self->{inventory}->get_stock($_->{sku}) } } @$items ],
        ts       => time(),
    };
    if ($self->{event_bus}) {
        $self->{event_bus}->broadcast($ev);
    }
    if ($self->{keydb}) {
        eval { $self->{keydb}->publish('events', Shop::Domain::JSON::encode_json($ev)); };
    }

    return {
        ok       => 1,
        order    => $order,
        payment  => $pay_res,
        shipment => $shipment,
    };
}

# Inbound PO line receiving: atomically updates DB, increments lock-free MT::Cell stock,
# and broadcasts live restock event over EventBus (and KeyDB Pub/Sub).
sub receive_po_line {
    my ($self, @rest) = @_;
    my %args;
    if (@rest == 2 && !ref($rest[0]) && $rest[0] ne 'po_line_id' && $rest[0] ne 'qty') {
        %args = (po_line_id => $rest[0], qty => $rest[1]);
    }
    elsif (@rest == 1 && ref($rest[0]) eq 'HASH') {
        %args = %{ $rest[0] };
    }
    else {
        %args = @rest;
    }

    my $po_line_id = $args{po_line_id};
    my $qty        = int($args{qty} // 0);
    return { ok => 0, error => 'po_line_id is required' } unless defined $po_line_id && length $po_line_id;
    return { ok => 0, error => 'qty must be positive' }   if $qty <= 0;
    return { ok => 0, error => 'DB does not support receive_po_line' }
        unless $self->{db} && $self->{db}->can('receive_po_line');

    my $res = $self->{db}->receive_po_line($po_line_id, $qty);
    return ($res || { ok => 0, error => 'receive_po_line failed' })
        unless ref($res) eq 'HASH' && $res->{ok};

    my $sku       = $res->{sku};
    my $new_stock = $self->{inventory}->release($sku, $qty);
    if (!defined $new_stock) {
        $new_stock = $self->{inventory}->set_stock($sku, int($res->{new_stock} // $qty));
    }

    my $ev = {
        type           => 'stock_update',
        sku            => $sku,
        stock          => $new_stock,
        qty_received   => $qty,
        po_id          => $res->{po_id}          // '',
        po_line_id     => $po_line_id,
        warehouse_code => $res->{warehouse_code} // '',
        po_status      => $res->{po_status}      // '',
        reason         => 'po_received',
        ts             => time(),
    };
    if ($self->{event_bus}) {
        $self->{event_bus}->broadcast($ev);
    }
    if ($self->{keydb}) {
        eval { $self->{keydb}->publish('events', Shop::Domain::JSON::encode_json($ev)); };
    }

    return {
        %$res,
        ok        => 1,
        sku       => $sku,
        stock     => $new_stock,
        new_stock => $new_stock,
    };
}

# 1-keystroke repeat checkout using saved default address + saved payment method.
sub quick_reorder {
    my ($self, %args) = @_;
    my $user_fp = $args{user_fp} // ($args{user} && $args{user}{fingerprint});
    return { ok => 0, error => 'user_fp is required' } unless defined $user_fp && length $user_fp;

    my $sku = $args{sku};
    return { ok => 0, error => 'sku is required' } unless defined $sku && length $sku;
    my $qty = int($args{qty} // 1);
    return { ok => 0, error => 'qty must be positive' } if $qty <= 0;

    my $user = $self->{db}->get_user($user_fp);
    return { ok => 0, error => 'User not found' } unless $user;

    my $pm_token = $user->{default_payment_method} // '';
    return { ok => 0, error => 'No saved payment method on file' } unless length $pm_token;

    my $addr = $self->{db}->get_default_address($user_fp);
    return { ok => 0, error => 'No saved default shipping address on file' } unless $addr;

    my $cart = Shop::Domain::Cart->new(
        user_fp   => $user_fp,
        inventory => $self->{inventory},
        keydb     => $self->{keydb},
        db        => $self->{db},
    );

    my $add_res = $cart->add($sku, $qty);
    if (!$add_res->{ok}) {
        return $add_res;
    }

    if (defined $args{promo_code} && length $args{promo_code}) {
        $cart->apply_promo($args{promo_code});
    }

    my $res = $self->place_order(
        cart           => $cart,
        user           => $user,
        address        => $addr,
        payment_token  => $pm_token,
        payment        => $args{payment},
        payment_method => $args{payment_method},
        hostkey        => $args{hostkey},
        (defined $args{membership} ? (membership => $args{membership}) : ()),
    );

    if (!$res->{ok}) {
        $cart->clear(release_stock => 1);
    }

    return $res;
}

1;
