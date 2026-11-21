package Shop::Domain::Membership;

use strict;
use warnings;
use Shop::Domain::Pricing;
use Shop::Domain::JSON ();

# Membership domain engine: tier lookup, benefit evaluation, enrollment, and cancellation.
# Safe across MT::Image::freeze() and multi-worker MT::Worker execution.

sub _utc_ts {
    my ($epoch) = @_;
    $epoch = time() unless defined $epoch;
    my ($S, $M, $H, $d, $m, $y) = gmtime($epoch);
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d', $y + 1900, $m + 1, $d, $H, $M, $S);
}

sub new {
    my ($class, %opt) = @_;
    die "Shop::Domain::Membership: db required\n" unless $opt{db};
    return bless {
        db        => $opt{db},
        event_bus => $opt{event_bus},
        metrics   => $opt{metrics},
    }, $class;
}

sub list_tiers {
    my ($self) = @_;
    return [] unless $self->{db} && $self->{db}->can('list_membership_tiers');
    return $self->{db}->list_membership_tiers();
}

sub _find_tier {
    my ($self, $code) = @_;
    return undef unless defined $code && length $code;
    my $want  = uc($code);
    my $tiers = $self->list_tiers;
    for my $t (@$tiers) {
        return $t if uc($t->{code} // '') eq $want;
    }
    return undef;
}

sub get_membership {
    my ($self, $fp) = @_;
    return undef unless defined $fp && length $fp;
    return undef unless $self->{db} && $self->{db}->can('get_membership');
    return $self->{db}->get_membership($fp);
}

sub benefits {
    my ($self, $fp) = @_;
    my $zero = Shop::Domain::Pricing::quant('0.00');

    my $m = (defined $fp && length $fp) ? $self->get_membership($fp) : undef;
    if (!$m || ref($m) ne 'HASH') {
        return {
            tier_code            => 'FREE',
            tier_name            => 'Standard',
            discount_pct         => $zero,
            free_shipping        => 0,
            priority_fulfillment => 0,
            status               => 'NONE',
        };
    }

    my $code   = uc($m->{tier_code} // 'FREE');
    my $status = uc($m->{status}    // 'INACTIVE');
    my $tier   = $self->_find_tier($code);

    if ($status eq 'ACTIVE' && $tier) {
        return {
            tier_code            => $tier->{code},
            tier_name            => $tier->{name} // $tier->{code},
            discount_pct         => Shop::Domain::Pricing::quant($tier->{discount_pct} // '0.00'),
            free_shipping        => $tier->{free_shipping}        ? 1 : 0,
            priority_fulfillment => $tier->{priority_fulfillment} ? 1 : 0,
            status               => 'ACTIVE',
        };
    }

    return {
        tier_code            => $code,
        tier_name            => $tier ? ($tier->{name} // $code) : 'Standard',
        discount_pct         => $zero,
        free_shipping        => 0,
        priority_fulfillment => 0,
        status               => $status,
    };
}

sub enroll {
    my ($self, @rest) = @_;
    my %args = (@rest == 1 && ref($rest[0]) eq 'HASH') ? %{ $rest[0] } : @rest;

    my $fp   = $args{user_fp};
    my $code = uc($args{tier_code} // '');
    return { ok => 0, error => 'user_fp is required' }   unless defined $fp && length $fp;
    return { ok => 0, error => 'tier_code is required' } unless length $code;

    my $tier = $self->_find_tier($code);
    if (!$tier || (defined $tier->{active} && !$tier->{active})) {
        return { ok => 0, error => "Unknown membership tier '$code'" };
    }

    my $renews_at = defined $args{renews_at}
        ? $args{renews_at}
        : ($code eq 'FREE' ? '' : _utc_ts(time() + 30 * 86400));

    my $saved = $self->{db}->upsert_membership({
        user_fp       => $fp,
        tier_code     => $tier->{code},
        status        => 'ACTIVE',
        stripe_sub_id => $args{stripe_sub_id} // '',
        renews_at     => $renews_at,
    });

    $self->{metrics}->inc('memberships_enrolled_total', 1) if $self->{metrics};

    if ($self->{event_bus}) {
        $self->{event_bus}->send_to_user($fp, {
            type      => 'membership_updated',
            user_fp   => $fp,
            tier_code => $tier->{code},
            status    => 'ACTIVE',
            ts        => time(),
        });
    }

    return {
        ok         => 1,
        membership => $saved,
        benefits   => $self->benefits($fp),
    };
}

sub cancel {
    my ($self, @rest) = @_;
    my %args;
    if (@rest == 1 && !ref($rest[0])) {
        %args = (user_fp => $rest[0]);
    }
    elsif (@rest == 1 && ref($rest[0]) eq 'HASH') {
        %args = %{ $rest[0] };
    }
    else {
        %args = @rest;
    }

    my $fp = $args{user_fp};
    return { ok => 0, error => 'user_fp is required' } unless defined $fp && length $fp;

    my $cur = $self->get_membership($fp);
    return { ok => 0, error => 'No membership found for user' } unless $cur;

    my $saved = $self->{db}->upsert_membership({
        user_fp       => $fp,
        tier_code     => $cur->{tier_code} // 'FREE',
        status        => 'CANCELED',
        stripe_sub_id => $cur->{stripe_sub_id} // '',
        renews_at     => $cur->{renews_at}     // '',
    });

    $self->{metrics}->inc('memberships_canceled_total', 1) if $self->{metrics};

    if ($self->{event_bus}) {
        $self->{event_bus}->send_to_user($fp, {
            type      => 'membership_updated',
            user_fp   => $fp,
            tier_code => $cur->{tier_code} // 'FREE',
            status    => 'CANCELED',
            ts        => time(),
        });
    }

    return {
        ok         => 1,
        membership => $saved,
        benefits   => $self->benefits($fp),
    };
}

1;
