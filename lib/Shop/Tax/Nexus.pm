package Shop::Tax::Nexus;

use strict;
use warnings;
use MT::Decimal;
use Shop::Domain::JSON qw(encode_json decode_json);
use Shop::Domain::Pricing;

# Multi-State Economic Tax Nexus Engine.
# 100% frozen MT::Worker safe: uses Shop::Domain::JSON + MT::Decimal (ROUND_HALF_UP),
# zero JSON::PP, zero floating-point drift.

sub new {
    my ($class, %opt) = @_;
    if (@_ == 2 && ref($_[1]) eq 'HASH') {
        %opt = %{ $_[1] };
    }
    return bless {
        db        => $opt{db},
        keydb     => $opt{keydb},
        cache_ttl => defined $opt{cache_ttl} ? int($opt{cache_ttl}) : 86400,
    }, $class;
}

sub _load_state_nexus {
    my ($self, $state) = @_;
    my $cache_key  = "tax:nexus:$state";
    my $from_cache = 0;

    if ($self->{keydb}) {
        my $raw = eval { $self->{keydb}->get($cache_key) };
        if (defined $raw && length $raw) {
            my $parsed = eval { decode_json($raw) };
            if (ref($parsed) eq 'HASH') {
                return ($parsed, 1);
            }
        }
    }

    my $row;
    if ($self->{db} && $self->{db}->can('get_tax_nexus')) {
        $row = eval { $self->{db}->get_tax_nexus($state) };
    }

    my $rec;
    if (ref($row) eq 'HASH' && defined $row->{state}) {
        $rec = {
            state           => uc($row->{state}),
            rate            => '' . ($row->{rate}            // '0'),
            threshold_sales => '' . ($row->{threshold_sales} // '0'),
            threshold_txns  => int($row->{threshold_txns}    // 0),
            registered      => int($row->{registered}        // 0) ? 1 : 0,
        };
    }
    else {
        $rec = {
            state           => $state,
            rate            => '0',
            threshold_sales => '0',
            threshold_txns  => 0,
            registered      => 0,
        };
    }

    if ($self->{keydb}) {
        eval { $self->{keydb}->set($cache_key, encode_json($rec), $self->{cache_ttl}); };
    }

    return ($rec, $from_cache);
}

# Calculate sales tax using exact MT::Decimal (ROUND_HALF_UP, quantized to 2 decimals)
# ONLY when registered == 1; otherwise tax is 0.00 with nexus_status => 'NO_NEXUS'.
sub calculate {
    my ($self, %args) = @_;
    my $state = uc($args{state} // '');
    $state =~ s/^\s+|\s+$//g;
    my $zip      = $args{postal_code} // $args{zip} // '';
    my $subtotal = Shop::Domain::Pricing::quant($args{subtotal} // '0.00');
    my $zero     = Shop::Domain::Pricing::quant('0.00');

    if (!length($state)) {
        return {
            state        => '',
            postal_code  => $zip,
            registered   => 0,
            rate         => Shop::Domain::Pricing::dec('0'),
            rate_pct     => '0',
            tax          => $zero,
            nexus_status => 'NO_NEXUS',
            cached       => 0,
        };
    }

    my ($rec, $cached) = $self->_load_state_nexus($state);
    if ($rec && $rec->{registered}) {
        local $MT::Decimal::ROUND_MODE = MT::Decimal::ROUND_HALF_UP;
        my $rate     = Shop::Domain::Pricing::dec($rec->{rate} // '0');
        my $tax      = $subtotal > $zero ? Shop::Domain::Pricing::quant($subtotal * $rate) : $zero;
        my $rate_pct = '' . ($rate * Shop::Domain::Pricing::dec('100'))->quantize(-3, MT::Decimal::ROUND_HALF_UP);
        $rate_pct =~ s/0+$//;
        $rate_pct =~ s/\.$//;
        return {
            state        => $state,
            postal_code  => $zip,
            registered   => 1,
            rate         => $rate,
            rate_pct     => $rate_pct,
            tax          => $tax,
            nexus_status => 'REGISTERED',
            cached       => $cached ? 1 : 0,
        };
    }

    return {
        state        => $state,
        postal_code  => $zip,
        registered   => 0,
        rate         => Shop::Domain::Pricing::dec('0'),
        rate_pct     => '0',
        tax          => $zero,
        nexus_status => 'NO_NEXUS',
        cached       => $cached ? 1 : 0,
    };
}

# Calls $db->tax_nexus_report() and classifies each state:
#   REGISTERED       - registered == 1
#   NEXUS_REQUIRED   - unregistered and >= 100% of sales or txn threshold
#   APPROACHING      - unregistered and >= 80% of sales or txn threshold
#   BELOW_THRESHOLD  - unregistered and < 80%
sub nexus_alerts {
    my ($self) = @_;
    return [] unless $self->{db} && $self->{db}->can('tax_nexus_report');
    my $rows = $self->{db}->tax_nexus_report() || [];

    local $MT::Decimal::ROUND_MODE = MT::Decimal::ROUND_HALF_UP;
    my $hundred = Shop::Domain::Pricing::dec('100');
    my $eighty  = Shop::Domain::Pricing::dec('80');
    my $zero    = Shop::Domain::Pricing::dec('0');

    my @out;
    for my $r (@$rows) {
        my $reg       = int($r->{registered} // 0) ? 1 : 0;
        my $ytd_sales = Shop::Domain::Pricing::quant($r->{ytd_sales} // '0.00');
        my $thr_sales = Shop::Domain::Pricing::quant($r->{threshold_sales} // '0.00');
        my $ytd_txns  = int($r->{ytd_txns}       // 0);
        my $thr_txns  = int($r->{threshold_txns} // 0);

        my $sales_pct = ($thr_sales > $zero)
            ? (($ytd_sales * $hundred) / $thr_sales)->quantize(-2, MT::Decimal::ROUND_HALF_UP)
            : $zero->quantize(-2, MT::Decimal::ROUND_HALF_UP);
        my $txns_pct  = ($thr_txns > 0)
            ? ((Shop::Domain::Pricing::dec($ytd_txns) * $hundred) / Shop::Domain::Pricing::dec($thr_txns))->quantize(-2, MT::Decimal::ROUND_HALF_UP)
            : $zero->quantize(-2, MT::Decimal::ROUND_HALF_UP);
        my $max_pct   = ($sales_pct >= $txns_pct) ? $sales_pct : $txns_pct;

        my $status;
        if ($reg) {
            $status = 'REGISTERED';
        }
        elsif ($max_pct >= $hundred) {
            $status = 'NEXUS_REQUIRED';
        }
        elsif ($max_pct >= $eighty) {
            $status = 'APPROACHING';
        }
        else {
            $status = 'BELOW_THRESHOLD';
        }

        push @out, {
            %$r,
            state           => uc($r->{state} // ''),
            registered      => $reg,
            rate            => Shop::Domain::Pricing::dec($r->{rate} // '0'),
            ytd_sales       => $ytd_sales,
            threshold_sales => $thr_sales,
            ytd_txns        => $ytd_txns,
            threshold_txns  => $thr_txns,
            sales_pct       => $sales_pct,
            txns_pct        => $txns_pct,
            max_pct         => $max_pct,
            status          => $status,
        };
    }

    return \@out;
}

1;
