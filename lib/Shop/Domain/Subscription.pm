package Shop::Domain::Subscription;

use strict;
use warnings;
use Time::Local qw(timegm);
use MT::SharedHash;
use Shop::Domain::Pricing;
use Shop::Domain::JSON ();

# Recurring subscription engine with MT::Decimal pricing, lifecycle transitions,
# and idempotent renewal processing backed by KeyDB / MT::SharedHash locks.

sub _utc_ts {
    my ($epoch) = @_;
    $epoch = time() unless defined $epoch;
    my ($S, $M, $H, $d, $m, $y) = gmtime($epoch);
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d', $y + 1900, $m + 1, $d, $H, $M, $S);
}

sub _parse_utc_ts {
    my ($ts) = @_;
    return undef unless defined $ts && length $ts;
    if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/) {
        my ($y, $m, $d, $H, $M, $S) = (int($1), int($2), int($3), int($4), int($5), int($6));
        my $epoch = eval { timegm($S, $M, $H, $d, $m - 1, $y) };
        return $epoch if defined $epoch;
    }
    return undef;
}

sub _advance_ts {
    my ($ts, $interval_days) = @_;
    my $days  = int($interval_days || 30);
    my $epoch = _parse_utc_ts($ts);
    $epoch    = time() unless defined $epoch;
    return _utc_ts($epoch + ($days * 86400));
}

sub new {
    my ($class, %opt) = @_;
    die "Shop::Domain::Subscription: db required\n" unless $opt{db};
    return bless {
        db          => $opt{db},
        inventory   => $opt{inventory},
        checkout    => $opt{checkout},
        membership  => $opt{membership},
        keydb       => $opt{keydb},
        event_bus   => $opt{event_bus},
        metrics     => $opt{metrics},
        renew_locks => $opt{renew_locks} || MT::SharedHash->new,
    }, $class;
}

sub create {
    my ($self, @rest) = @_;
    my %args = (@rest == 1 && ref($rest[0]) eq 'HASH') ? %{ $rest[0] } : @rest;

    my $fp            = $args{user_fp};
    my $sku           = $args{sku};
    my $qty           = int($args{qty} // 1);
    my $interval_days = int($args{interval_days} // 30);

    return { ok => 0, error => 'user_fp is required' }          unless defined $fp && length $fp;
    return { ok => 0, error => 'sku is required' }              unless defined $sku && length $sku;
    return { ok => 0, error => 'qty must be positive' }         if $qty <= 0;
    return { ok => 0, error => 'interval_days must be >= 7' }   if $interval_days < 7;

    my $prod;
    if ($self->{inventory}) {
        $prod = $self->{inventory}->get_product($sku);
    }
    if (!$prod && $self->{db}->can('get_product')) {
        $prod = eval { $self->{db}->get_product($sku) };
    }
    return { ok => 0, error => "Unknown product '$sku'" } unless $prod;

    my $base_price = Shop::Domain::Pricing::dec($prod->{price} // '0.00');
    my $unit_price = Shop::Domain::Pricing::quant($base_price);

    if ($self->{membership} && $self->{membership}->can('benefits')) {
        my $b = $self->{membership}->benefits($fp);
        if (ref($b) eq 'HASH' && uc($b->{status} // '') eq 'ACTIVE') {
            my $pct = Shop::Domain::Pricing::dec($b->{discount_pct} // '0.00');
            if ($pct > Shop::Domain::Pricing::dec('0')) {
                my $disc = Shop::Domain::Pricing::quant(($base_price * $pct) / Shop::Domain::Pricing::dec('100'));
                $unit_price = Shop::Domain::Pricing::quant($base_price - $disc);
                my $zero = Shop::Domain::Pricing::quant('0.00');
                $unit_price = $zero if $unit_price < $zero;
            }
        }
    }

    my $next_bill_at = defined $args{next_bill_at} && length $args{next_bill_at}
        ? $args{next_bill_at}
        : _utc_ts(time() + ($interval_days * 86400));

    my $sub = $self->{db}->create_subscription({
        (defined $args{id} && length $args{id} ? (id => $args{id}) : ()),
        user_fp       => $fp,
        sku           => $sku,
        qty           => $qty,
        interval_days => $interval_days,
        unit_price    => "$unit_price",
        next_bill_at  => $next_bill_at,
        stripe_sub_id => $args{stripe_sub_id} // '',
    });

    $self->{metrics}->inc('subscriptions_created_total', 1) if $self->{metrics};

    return {
        ok           => 1,
        subscription => $sub,
    };
}

sub _load_owned {
    my ($self, $id, $fp) = @_;
    return (undef, 'subscription id is required') unless defined $id && length $id;
    my $sub = $self->{db}->get_subscription($id);
    return (undef, "Subscription '$id' not found") unless $sub;
    if (defined $fp && length $fp && ($sub->{user_fp} // '') ne $fp) {
        return (undef, 'Subscription does not belong to user');
    }
    return ($sub, undef);
}

sub pause {
    my ($self, $id, $fp) = @_;
    my ($sub, $err) = $self->_load_owned($id, $fp);
    return { ok => 0, error => $err } if $err;
    if (uc($sub->{status} // '') eq 'CANCELED') {
        return { ok => 0, error => 'Cannot pause a canceled subscription' };
    }
    my $updated = $self->{db}->update_subscription($id, status => 'PAUSED');
    return { ok => 1, subscription => $updated };
}

sub resume {
    my ($self, $id, $fp) = @_;
    my ($sub, $err) = $self->_load_owned($id, $fp);
    return { ok => 0, error => $err } if $err;
    if (uc($sub->{status} // '') eq 'CANCELED') {
        return { ok => 0, error => 'Cannot resume a canceled subscription' };
    }
    my $next_bill = $sub->{next_bill_at};
    if (!defined $next_bill || !length $next_bill) {
        $next_bill = _utc_ts(time() + (int($sub->{interval_days} || 30) * 86400));
    }
    my $updated = $self->{db}->update_subscription($id, status => 'ACTIVE', next_bill_at => $next_bill);
    return { ok => 1, subscription => $updated };
}

sub skip_next {
    my ($self, $id, $fp) = @_;
    my ($sub, $err) = $self->_load_owned($id, $fp);
    return { ok => 0, error => $err } if $err;
    if (uc($sub->{status} // '') eq 'CANCELED') {
        return { ok => 0, error => 'Cannot skip a canceled subscription' };
    }
    my $new_next = _advance_ts($sub->{next_bill_at}, int($sub->{interval_days} || 30));
    my $updated  = $self->{db}->update_subscription($id, next_bill_at => $new_next);
    return { ok => 1, subscription => $updated };
}

sub cancel {
    my ($self, $id, $fp) = @_;
    my ($sub, $err) = $self->_load_owned($id, $fp);
    return { ok => 0, error => $err } if $err;
    my $updated = $self->{db}->update_subscription($id, status => 'CANCELED');
    $self->{metrics}->inc('subscriptions_canceled_total', 1) if $self->{metrics};
    return { ok => 1, subscription => $updated };
}

sub list_user {
    my ($self, $fp) = @_;
    return [] unless defined $fp && length $fp;
    return $self->{db}->list_subscriptions($fp);
}

sub mrr_summary {
    my ($self) = @_;
    my $m = $self->{db}->subscription_metrics();
    $m ||= {};
    my $mem_mrr   = Shop::Domain::Pricing::quant($m->{membership_mrr}   // '0.00');
    my $sub_mrr   = Shop::Domain::Pricing::quant($m->{subscription_mrr} // '0.00');
    my $total_mrr = Shop::Domain::Pricing::quant($mem_mrr + $sub_mrr);
    return {
        active_members       => int($m->{active_members}       // 0),
        active_subscriptions => int($m->{active_subscriptions} // 0),
        membership_mrr       => $mem_mrr,
        subscription_mrr     => $sub_mrr,
        total_mrr            => $total_mrr,
    };
}

sub _acquire_renewal_lock {
    my ($self, $lock_key) = @_;

    # Fast in-process check across MT::Workers via MT::SharedHash
    if ($self->{renew_locks} && defined $self->{renew_locks}->get($lock_key)) {
        return 0;
    }

    # Distributed idempotency lock via KeyDB SET NX EX when connected
    if ($self->{keydb}) {
        my $kdb_acquired;
        my $kdb_ok = eval {
            my $res = $self->{keydb}->cmd('SET', $self->{keydb}->_k($lock_key), '1', 'NX', 'EX', 86400);
            $kdb_acquired = (defined $res && $res eq 'OK') ? 1 : 0;
            1;
        };
        if ($kdb_ok) {
            $self->{renew_locks}->set($lock_key, '1') if $self->{renew_locks};
            return $kdb_acquired;
        }
    }

    $self->{renew_locks}->set($lock_key, '1') if $self->{renew_locks};
    return 1;
}

sub _release_renewal_lock {
    my ($self, $lock_key) = @_;
    $self->{renew_locks}->delete($lock_key) if $self->{renew_locks};
    if ($self->{keydb}) {
        eval { $self->{keydb}->del($lock_key); };
    }
    return 1;
}

sub process_due_renewals {
    my ($self, @rest) = @_;
    my %args;
    if (@rest == 1 && !ref($rest[0])) {
        %args = (as_of => $rest[0]);
    }
    elsif (@rest == 1 && ref($rest[0]) eq 'HASH') {
        %args = %{ $rest[0] };
    }
    else {
        %args = @rest;
    }

    my $as_of = defined $args{as_of} && length $args{as_of}
        ? $args{as_of}
        : _utc_ts(time());

    return { ok => 0, error => 'checkout engine is required for renewals' }
        unless $self->{checkout};

    my $due = $self->{db}->due_subscriptions($as_of);
    $due ||= [];

    my (@renewed, @skipped, @failed);

    for my $sub (@$due) {
        my $sub_id   = $sub->{id};
        my $bill_ts  = $sub->{next_bill_at} // '';
        my $lock_key = "sub:renew:$sub_id:$bill_ts";

        if (!$self->_acquire_renewal_lock($lock_key)) {
            push @skipped, $sub_id;
            next;
        }

        my $benefits;
        if ($self->{membership} && $self->{membership}->can('benefits')) {
            $benefits = $self->{membership}->benefits($sub->{user_fp});
        }

        my $res = $self->{checkout}->quick_reorder(
            user_fp    => $sub->{user_fp},
            sku        => $sub->{sku},
            qty        => int($sub->{qty} || 1),
            membership => $benefits,
        );

        if (!$res || !$res->{ok}) {
            $self->_release_renewal_lock($lock_key);
            push @failed, {
                sub_id => $sub_id,
                error  => ($res && $res->{error}) ? $res->{error} : 'Renewal checkout failed',
            };
            next;
        }

        my $order    = $res->{order};
        my $order_id = $order->{id};
        my $total    = '' . ($order->{total} // '0.00');
        my $new_next = _advance_ts($bill_ts, int($sub->{interval_days} || 30));

        $self->{db}->update_subscription(
            $sub_id,
            next_bill_at  => $new_next,
            last_order_id => $order_id,
        );

        $self->{metrics}->inc('subscription_renewals_total', 1) if $self->{metrics};

        if ($self->{event_bus}) {
            $self->{event_bus}->send_to_user($sub->{user_fp}, {
                type     => 'subscription_renewed',
                sub_id   => $sub_id,
                order_id => $order_id,
                sku      => $sub->{sku},
                qty      => int($sub->{qty} || 1),
                total    => $total,
                ts       => time(),
            });
        }

        push @renewed, {
            sub_id       => $sub_id,
            order_id     => $order_id,
            sku          => $sub->{sku},
            total        => $total,
            next_bill_at => $new_next,
        };
    }

    return {
        ok      => 1,
        as_of   => $as_of,
        due     => scalar(@$due),
        renewed => \@renewed,
        skipped => \@skipped,
        failed  => \@failed,
    };
}

1;
