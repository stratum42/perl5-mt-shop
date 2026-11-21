package Shop::Shipping::Shippo;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use MT::Decimal;
use Shop::Domain::JSON qw(encode_json decode_json);
use Shop::Domain::Pricing;

# Shippo Multi-Carrier Shipping & Warehouse Routing Adapter.
# 100% frozen MT::Worker safe: uses Shop::Domain::JSON + MT::Decimal,
# zero JSON::PP, zero Symbol::gensym.

my @DEFAULT_WAREHOUSES = (
    { code => 'DAL1', name => 'Dallas Central Hub',  city => 'Dallas',  state => 'TX', postal_code => '75201', active => 1 },
    { code => 'NYC1', name => 'Newark East Hub',     city => 'Newark',  state => 'NJ', postal_code => '07102', active => 1 },
    { code => 'SFO1', name => 'Oakland West Hub',    city => 'Oakland', state => 'CA', postal_code => '94607', active => 1 },
);

my %US_STATES = map { $_ => 1 } qw(
    AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD
    MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC
    SD TN TX UT VT VA WA WV WI WY DC PR VI GU AS MP
);

sub new {
    my ($class, %opt) = @_;
    if (@_ == 2 && ref($_[1]) eq 'HASH') {
        %opt = %{ $_[1] };
    }
    return bless {
        api_token => defined $opt{api_token} ? $opt{api_token} : ($ENV{SHIPPO_API_TOKEN} // ''),
        api_base  => $opt{api_base}  // 'https://api.goshippo.com',
        keydb     => $opt{keydb},
        cache_ttl => defined $opt{cache_ttl} ? int($opt{cache_ttl}) : 21600,
        timeout   => defined $opt{timeout}   ? int($opt{timeout})   : 10,
    }, $class;
}

sub is_configured {
    my ($self) = @_;
    return (defined $self->{api_token} && length($self->{api_token}) > 0) ? 1 : 0;
}

sub default_warehouses {
    return [ map { { %$_ } } @DEFAULT_WAREHOUSES ];
}

sub _zip5 {
    my ($val) = @_;
    return undef unless defined $val;
    if (ref($val) eq 'HASH') {
        $val = $val->{postal_code} // $val->{zip} // '';
    }
    return ($val =~ /(\d{5})/) ? $1 : undef;
}

# Pick closest active warehouse hub (DAL1 75201 / NYC1 07102 / SFO1 94607) by numeric ZIP distance.
# Supports both $shippo->pick_warehouse($dest_zip, $warehouses) and Shop::Shipping::Shippo::pick_warehouse(...).
sub pick_warehouse {
    my @args = @_;
    if (@args && ((ref($args[0]) && eval { $args[0]->isa(__PACKAGE__) }) || (!ref($args[0]) && defined $args[0] && $args[0] eq __PACKAGE__))) {
        shift @args;
    }
    my ($dest_zip, $warehouses) = @args;
    my $list = (ref($warehouses) eq 'ARRAY' && @$warehouses) ? $warehouses : default_warehouses();
    my @active = grep { !exists $_->{active} || $_->{active} } @$list;
    @active = @$list unless @active;

    my $dest5 = _zip5($dest_zip);
    if (!defined $dest5) {
        for my $w (@active) {
            return { %$w } if ($w->{code} // '') eq 'DAL1';
        }
        return { %{ $active[0] } };
    }
    my $dest_num = int($dest5);

    my ($best, $best_dist);
    for my $w (sort { ($a->{code} // '') cmp ($b->{code} // '') } @active) {
        my $w5 = _zip5($w->{postal_code} // $w->{zip});
        next unless defined $w5;
        my $dist = abs($dest_num - int($w5));
        if (!defined $best_dist || $dist < $best_dist) {
            $best_dist = $dist;
            $best      = $w;
        }
    }
    $best ||= $active[0];
    return { %$best };
}

sub _http_post_json {
    my ($self, $path, $payload_ref) = @_;
    my $url  = $self->{api_base} . $path;
    my $json = encode_json($payload_ref);

    my @cmd = (
        'curl', '-sS', '--max-time', $self->{timeout},
        '-H', 'Authorization: ShippoToken ' . $self->{api_token},
        '-H', 'Content-Type: application/json',
        '-X', 'POST',
        '--data-raw', $json,
        $url,
    );

    my $pid = open(my $fh, '-|', @cmd);
    return { ok => 0, error => "Failed to invoke curl: $!" } unless defined $pid;
    local $/;
    my $raw = <$fh> // '';
    close($fh);
    my $exit = $? >> 8;

    my $data = eval { decode_json($raw) };
    if ($exit != 0 || !$data || ref($data) ne 'HASH') {
        return { ok => 0, error => "Shippo HTTP error (exit=$exit): $raw" };
    }
    return { ok => 1, data => $data };
}

sub validate_address {
    my ($self, $addr) = @_;
    if (!ref($self) || !$self->isa(__PACKAGE__)) {
        $addr = $self;
        $self = __PACKAGE__->new;
    }
    return { ok => 0, valid => 0, error => 'Address hashref required', messages => ['Address hashref required'] }
        unless ref($addr) eq 'HASH';

    my $street1 = $addr->{line1}       // $addr->{street1} // '';
    my $street2 = $addr->{line2}       // $addr->{street2} // '';
    my $city    = $addr->{city}        // '';
    my $state   = uc($addr->{state}    // '');
    my $zip     = $addr->{postal_code} // $addr->{zip}     // '';
    my $country = uc($addr->{country}  // 'US');
    my $name    = $addr->{recipient}   // $addr->{name}    // 'Customer';

    for ($street1, $street2, $city, $state, $zip, $country, $name) {
        s/^\s+|\s+$//g;
    }

    if ($self->is_configured) {
        my $res = $self->_http_post_json('/addresses/', {
            name     => $name,
            street1  => $street1,
            street2  => $street2,
            city     => $city,
            state    => $state,
            zip      => $zip,
            country  => $country,
            validate => \1,
        });
        if ($res->{ok}) {
            my $d   = $res->{data};
            my $vr  = $d->{validation_results} || {};
            my $val = $vr->{is_valid} ? 1 : 0;
            my @msgs = map { $_->{text} // $_->{code} // '' } @{ $vr->{messages} || [] };
            return {
                ok         => $val,
                valid      => $val,
                object_id  => $d->{object_id} // '',
                normalized => {
                    recipient   => $d->{name}    // $name,
                    line1       => $d->{street1} // $street1,
                    line2       => $d->{street2} // $street2,
                    city        => $d->{city}    // $city,
                    state       => uc($d->{state} // $state),
                    postal_code => $d->{zip}     // $zip,
                    country     => uc($d->{country} // $country),
                },
                messages => \@msgs,
                ($val ? () : (error => join('; ', @msgs) || 'Address validation failed')),
            };
        }
        return { ok => 0, valid => 0, error => $res->{error}, messages => [$res->{error}] };
    }

    # Deterministic offline US address validator
    my @errs;
    push @errs, 'Street address (line1) is required' unless length($street1) >= 3;
    push @errs, 'City is required'                   unless length($city) >= 2;
    if ($country eq 'US') {
        push @errs, "Invalid US state code '$state'" unless $US_STATES{$state};
        push @errs, "Invalid US postal code '$zip'"  unless $zip =~ /^\d{5}(?:-\d{4})?$/;
    }
    else {
        push @errs, 'Postal code is required' unless length($zip) >= 3;
    }

    if (@errs) {
        return {
            ok       => 0,
            valid    => 0,
            error    => join('; ', @errs),
            messages => \@errs,
        };
    }

    return {
        ok         => 1,
        valid      => 1,
        sandbox    => 1,
        normalized => {
            recipient   => $name,
            line1       => $street1,
            line2       => $street2,
            city        => $city,
            state       => $state,
            postal_code => $zip,
            country     => $country,
        },
        messages => [],
    };
}

sub _estimate_weight_oz {
    my ($weight_oz, $items) = @_;
    if (defined $weight_oz && $weight_oz > 0) {
        return int($weight_oz + 0.5) || 1;
    }
    my $total_qty = 0;
    if (ref($items) eq 'ARRAY') {
        for my $it (@$items) {
            my $q = int($it->{qty} // 1);
            $total_qty += $q if $q > 0;
        }
    }
    return $total_qty > 0 ? ($total_qty * 12) : 16;
}

sub _hydrate_rates {
    my ($rates) = @_;
    my @out;
    for my $r (@$rates) {
        my $amt = Shop::Domain::Pricing::quant($r->{amount} // '0.00');
        my $days = int($r->{estimated_days} // $r->{eta_days} // 5);
        push @out, {
            %$r,
            amount         => $amt,
            amount_str     => "$amt",
            estimated_days => $days,
            eta_days       => $days,
        };
    }
    return \@out;
}

sub _dehydrate_rates {
    my ($rates) = @_;
    my @out;
    for my $r (@$rates) {
        push @out, {
            object_id      => '' . ($r->{object_id}      // ''),
            rate_id        => '' . ($r->{rate_id}        // $r->{object_id} // ''),
            carrier        => '' . ($r->{carrier}        // ''),
            service        => '' . ($r->{service}        // ''),
            service_token  => '' . ($r->{service_token}  // ''),
            amount         => '' . Shop::Domain::Pricing::quant($r->{amount} // '0.00'),
            currency       => '' . ($r->{currency}       // 'USD'),
            estimated_days => int($r->{estimated_days}   // $r->{eta_days} // 5),
            warehouse_code => '' . ($r->{warehouse_code} // ''),
        };
    }
    return \@out;
}

sub get_rates {
    my ($self, %args) = @_;
    my $to   = $args{to}   || {};
    my $from = $args{from} || $self->pick_warehouse($to, $args{warehouses});

    my $orig_zip = _zip5($from) // '75201';
    my $dest_zip = _zip5($to)   // '75201';
    my $oz       = _estimate_weight_oz($args{weight_oz}, $args{items});
    my $wh_code  = $from->{code} // 'DAL1';

    my $cache_key = "shippo:rate:$orig_zip:$dest_zip:$oz";

    # Check KeyDB cache first
    if ($self->{keydb} && !$args{bypass_cache}) {
        my $cached_raw = eval { $self->{keydb}->get($cache_key) };
        if (defined $cached_raw && length $cached_raw) {
            my $parsed = eval { decode_json($cached_raw) };
            if (ref($parsed) eq 'ARRAY' && @$parsed) {
                return {
                    ok             => 1,
                    cached         => 1,
                    cache_key      => $cache_key,
                    warehouse      => { %$from },
                    warehouse_code => $wh_code,
                    weight_oz      => $oz,
                    rates          => _hydrate_rates($parsed),
                };
            }
        }
    }

    my @rates;
    if ($self->is_configured) {
        my $res = $self->_http_post_json('/shipments/', {
            address_from => {
                name    => $from->{name}        // 'perl5-mt-shop',
                street1 => $from->{line1}       // '100 Warehouse Way',
                city    => $from->{city}        // 'Dallas',
                state   => $from->{state}       // 'TX',
                zip     => $orig_zip,
                country => $from->{country}     // 'US',
            },
            address_to => {
                name    => $to->{recipient}     // $to->{name} // 'Customer',
                street1 => $to->{line1}         // $to->{street1} // '1 Main St',
                city    => $to->{city}          // 'Austin',
                state   => $to->{state}         // 'TX',
                zip     => $dest_zip,
                country => $to->{country}       // 'US',
            },
            parcels => [{
                length        => '10',
                width         => '8',
                height        => '4',
                distance_unit => 'in',
                weight        => "$oz",
                mass_unit     => 'oz',
            }],
            async => \0,
        });
        if (!$res->{ok}) {
            return { ok => 0, error => $res->{error}, rates => [] };
        }
        my $api_rates = $res->{data}{rates} || [];
        for my $r (@$api_rates) {
            my $amt  = Shop::Domain::Pricing::quant($r->{amount} // '0.00');
            my $days = int($r->{estimated_days} // 5);
            push @rates, {
                object_id      => $r->{object_id} // '',
                rate_id        => $r->{object_id} // '',
                carrier        => $r->{provider}  // 'Carrier',
                service        => (ref($r->{servicelevel}) eq 'HASH' ? $r->{servicelevel}{name} : undef) // 'Standard',
                service_token  => (ref($r->{servicelevel}) eq 'HASH' ? $r->{servicelevel}{token} : undef) // 'standard',
                amount         => $amt,
                amount_str     => "$amt",
                currency       => $r->{currency}  // 'USD',
                estimated_days => $days,
                eta_days       => $days,
                warehouse_code => $wh_code,
            };
        }
        @rates = sort { $a->{amount} <=> $b->{amount} } @rates;
    }
    else {
        # Deterministic realistic carrier rates using exact MT::Decimal arithmetic
        local $MT::Decimal::ROUND_MODE = MT::Decimal::ROUND_HALF_UP;
        my $diff = abs(int($orig_zip) - int($dest_zip));
        my $zone_mult = $diff < 5000  ? Shop::Domain::Pricing::dec('0')
                      : $diff < 20000 ? Shop::Domain::Pricing::dec('1')
                      : $diff < 50000 ? Shop::Domain::Pricing::dec('2')
                      :                 Shop::Domain::Pricing::dec('3');

        my $extra_oz = $oz > 16 ? ($oz - 16) : 0;
        my $wt_fee   = Shop::Domain::Pricing::quant(Shop::Domain::Pricing::dec($extra_oz) * Shop::Domain::Pricing::dec('0.15'));

        my $usps_amt  = Shop::Domain::Pricing::quant(Shop::Domain::Pricing::dec('5.95')  + ($zone_mult * Shop::Domain::Pricing::dec('0.75')) + $wt_fee);
        my $ups_amt   = Shop::Domain::Pricing::quant(Shop::Domain::Pricing::dec('9.50')  + ($zone_mult * Shop::Domain::Pricing::dec('1.25')) + $wt_fee);
        my $fedex_amt = Shop::Domain::Pricing::quant(Shop::Domain::Pricing::dec('18.95') + ($zone_mult * Shop::Domain::Pricing::dec('1.75')) + $wt_fee);

        my $usps_days = $diff < 20000 ? 3 : 5;
        my $ups_days  = $diff < 20000 ? 2 : 4;

        @rates = (
            {
                object_id      => "rate_usps_${orig_zip}_${dest_zip}_${oz}",
                rate_id        => "rate_usps_${orig_zip}_${dest_zip}_${oz}",
                carrier        => 'USPS',
                service        => 'USPS Ground Advantage',
                service_token  => 'usps_ground_advantage',
                amount         => $usps_amt,
                amount_str     => "$usps_amt",
                currency       => 'USD',
                estimated_days => $usps_days,
                eta_days       => $usps_days,
                warehouse_code => $wh_code,
            },
            {
                object_id      => "rate_ups_${orig_zip}_${dest_zip}_${oz}",
                rate_id        => "rate_ups_${orig_zip}_${dest_zip}_${oz}",
                carrier        => 'UPS',
                service        => 'UPS Ground',
                service_token  => 'ups_ground',
                amount         => $ups_amt,
                amount_str     => "$ups_amt",
                currency       => 'USD',
                estimated_days => $ups_days,
                eta_days       => $ups_days,
                warehouse_code => $wh_code,
            },
            {
                object_id      => "rate_fedex_${orig_zip}_${dest_zip}_${oz}",
                rate_id        => "rate_fedex_${orig_zip}_${dest_zip}_${oz}",
                carrier        => 'FedEx',
                service        => 'FedEx 2Day',
                service_token  => 'fedex_2_day',
                amount         => $fedex_amt,
                amount_str     => "$fedex_amt",
                currency       => 'USD',
                estimated_days => 2,
                eta_days       => 2,
                warehouse_code => $wh_code,
            },
        );
    }

    # Cache in KeyDB
    if ($self->{keydb} && @rates) {
        eval {
            my $encoded = encode_json(_dehydrate_rates(\@rates));
            $self->{keydb}->set($cache_key, $encoded, $self->{cache_ttl});
        };
    }

    return {
        ok             => 1,
        cached         => 0,
        cache_key      => $cache_key,
        warehouse      => { %$from },
        warehouse_code => $wh_code,
        weight_oz      => $oz,
        rates          => \@rates,
    };
}

sub buy_label {
    my ($self, %args) = @_;
    my $rate     = $args{rate} || {};
    my $order_id = $args{order_id} // sprintf('ORD-%d', time());
    my $from     = $args{from} || {};
    my $to       = $args{to}   || {};

    my $carrier  = $rate->{carrier} // 'USPS';
    my $service  = $rate->{service} // 'USPS Ground Advantage';
    my $rate_amt = Shop::Domain::Pricing::quant($rate->{amount} // $rate->{rate_amount} // '0.00');
    my $rate_id  = $rate->{object_id} // $rate->{rate_id} // '';

    if ($self->is_configured && length($rate_id) && $rate_id !~ /^rate_/) {
        my $res = $self->_http_post_json('/transactions/', {
            rate            => $rate_id,
            label_file_type => 'PDF',
            async           => \0,
            metadata        => "order_id=$order_id",
        });
        if (!$res->{ok}) {
            return { ok => 0, error => $res->{error} };
        }
        my $d = $res->{data};
        if (($d->{status} // '') ne 'SUCCESS') {
            my @msgs = map { $_->{text} // '' } @{ $d->{messages} || [] };
            return { ok => 0, error => join('; ', @msgs) || 'Shippo label purchase failed' };
        }
        return {
            ok              => 1,
            sandbox         => 0,
            transaction_id  => $d->{object_id}       // '',
            tracking_number => $d->{tracking_number} // '',
            label_url       => $d->{label_url}       // '',
            carrier         => $carrier,
            service         => $service,
            rate_amount     => $rate_amt,
            status          => 'LABEL_CREATED',
        };
    }

    # Deterministic sandbox label generation
    my $orig_zip = _zip5($from) // '75201';
    my $dest_zip = _zip5($to)   // '75201';
    my $digest   = sha256_hex("$order_id|$carrier|$service|$orig_zip|$dest_zip");
    # Convert hex digest to deterministic decimal digits
    my $digits = '';
    for my $i (0 .. 15) {
        $digits .= (hex(substr($digest, $i * 2, 2)) % 10);
    }

    my $tracking;
    if (uc($carrier) eq 'UPS') {
        $tracking = '1Z999AA1' . substr($digits, 0, 10);
    }
    elsif (uc($carrier) eq 'FEDEX') {
        $tracking = '79464479' . substr($digits, 0, 12);
    }
    else {
        $tracking = '9400111899' . substr($digits, 0, 12);
    }

    return {
        ok              => 1,
        sandbox         => 1,
        transaction_id  => 'txn_' . substr($digest, 0, 12),
        tracking_number => $tracking,
        label_url       => "https://shippo.sandbox/labels/${order_id}-${tracking}.pdf",
        carrier         => $carrier,
        service         => $service,
        rate_amount     => $rate_amt,
        status          => 'LABEL_CREATED',
    };
}

1;
