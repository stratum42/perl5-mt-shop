package Shop::TUI::View::Subscriptions;

use strict;
use warnings;
use Shop::TUI::Input ();

my @DEFAULT_TIERS = (
    {
        code                 => 'FREE',
        name                 => 'Standard',
        monthly_price        => '0.00',
        discount_pct         => '0.00',
        free_shipping        => 0,
        priority_fulfillment => 0,
        active               => 1,
    },
    {
        code                 => 'PRO',
        name                 => 'Pro Member',
        monthly_price        => '9.99',
        discount_pct         => '10.00',
        free_shipping        => 1,
        priority_fulfillment => 1,
        active               => 1,
    },
    {
        code                 => 'FOUNDER',
        name                 => 'Founder',
        monthly_price        => '24.99',
        discount_pct         => '20.00',
        free_shipping        => 1,
        priority_fulfillment => 1,
        active               => 1,
    },
);

sub new {
    my ($class, %args) = @_;
    return bless {
        tiers      => [],
        membership => undef,
        subs       => [],
        selected   => 0,
        scroll     => 0,
    }, $class;
}

sub on_enter {
    my ($self, $app) = @_;
    $self->refresh($app);
}

sub refresh {
    my ($self, $app) = @_;
    my $fp  = $app->user_fp();
    my $mem = $app->can('membership_mgr')   ? $app->membership_mgr()   : $app->{membership};
    my $sub = $app->can('subscription_mgr') ? $app->subscription_mgr() : $app->{subscription};
    my $db  = $app->{db};

    my $tiers;
    if ($mem && $mem->can('list_tiers')) {
        $tiers = eval { $mem->list_tiers() };
    } elsif ($db && $db->can('list_membership_tiers')) {
        $tiers = eval { $db->list_membership_tiers() };
    }
    $self->{tiers} = (ref($tiers) eq 'ARRAY' && @$tiers) ? $tiers : \@DEFAULT_TIERS;

    my $cur;
    if ($mem && $mem->can('get_membership')) {
        $cur = eval { $mem->get_membership($fp) };
    } elsif ($db && $db->can('get_membership')) {
        $cur = eval { $db->get_membership($fp) };
    }
    $self->{membership} = ref($cur) eq 'HASH' ? $cur : undef;

    my $subs;
    if ($sub && $sub->can('list_user')) {
        $subs = eval { $sub->list_user($fp) };
    } elsif ($db && $db->can('list_subscriptions')) {
        $subs = eval { $db->list_subscriptions($fp) };
    }
    $self->{subs} = ref($subs) eq 'ARRAY' ? $subs : [];

    my $n = scalar(@{ $self->{subs} });
    if ($n == 0) {
        $self->{selected} = 0;
        $self->{scroll}   = 0;
    } elsif ($self->{selected} >= $n) {
        $self->{selected} = $n - 1;
    }

    $app->refresh_membership() if $app->can('refresh_membership');
}

sub is_capturing_text { 0 }

sub help_text {
    return "[1/2/3] Tier | [u] Upgrade | [x] Cancel Plan | [Up/Down] Sub | [p] Pause/Resume | [k] Skip | [c] Cancel Sub | [r] Refresh";
}

sub _enroll_tier {
    my ($self, $app, $tier_code) = @_;
    my $fp  = $app->user_fp();
    my $mem = $app->can('membership_mgr') ? $app->membership_mgr() : $app->{membership};
    my $db  = $app->{db};

    my $res;
    if ($mem && $mem->can('enroll')) {
        $res = eval { $mem->enroll(user_fp => $fp, tier_code => $tier_code) };
    } elsif ($db && $db->can('upsert_membership')) {
        $res = eval { $db->upsert_membership({ user_fp => $fp, tier_code => $tier_code, status => 'ACTIVE' }) };
    } else {
        $app->set_toast("Membership service unavailable.", 'err');
        return;
    }

    if ($@) {
        $app->set_toast("Membership enroll failed: $@", 'err');
        return;
    }
    if (ref($res) eq 'HASH' && exists($res->{ok}) && !$res->{ok}) {
        $app->set_toast($res->{error} // "Membership enroll failed.", 'err');
        return;
    }

    $self->refresh($app);
    $app->set_toast("Membership updated to $tier_code (ACTIVE).", 'ok');
}

sub _upgrade_tier {
    my ($self, $app) = @_;
    my $m      = $self->{membership};
    my $status = uc(($m && $m->{status}) ? $m->{status} : 'NONE');
    my $cur    = ($status eq 'ACTIVE') ? uc($m->{tier_code} // 'FREE') : 'FREE';

    if ($cur eq 'FOUNDER') {
        $app->set_toast("Already enrolled in FOUNDER tier.", 'ok');
        return;
    }
    my $next = ($cur eq 'PRO') ? 'FOUNDER' : 'PRO';
    $self->_enroll_tier($app, $next);
}

sub _cancel_membership {
    my ($self, $app) = @_;
    my $fp  = $app->user_fp();
    my $mem = $app->can('membership_mgr') ? $app->membership_mgr() : $app->{membership};
    my $db  = $app->{db};

    my $res;
    if ($mem && $mem->can('cancel')) {
        $res = eval { $mem->cancel(user_fp => $fp) };
    } elsif ($db && $db->can('upsert_membership')) {
        my $cur_tier = ($self->{membership} && $self->{membership}{tier_code}) || 'FREE';
        $res = eval { $db->upsert_membership({ user_fp => $fp, tier_code => $cur_tier, status => 'CANCELED' }) };
    } else {
        $app->set_toast("Membership service unavailable.", 'err');
        return;
    }

    if ($@) {
        $app->set_toast("Cancel membership failed: $@", 'err');
        return;
    }
    if (ref($res) eq 'HASH' && exists($res->{ok}) && !$res->{ok}) {
        $app->set_toast($res->{error} // "Cancel membership failed.", 'err');
        return;
    }

    $self->refresh($app);
    $app->set_toast("Membership canceled.", 'warn');
}

sub _sub_action {
    my ($self, $app, $action) = @_;
    my $n = scalar(@{ $self->{subs} });
    if ($n == 0) {
        $app->set_toast("No recurring subscriptions selected.", 'warn');
        return;
    }
    my $s   = $self->{subs}[$self->{selected}];
    my $id  = $s->{id};
    my $fp  = $app->user_fp();
    my $mgr = $app->can('subscription_mgr') ? $app->subscription_mgr() : $app->{subscription};

    if (!$mgr) {
        $app->set_toast("Subscription service unavailable.", 'err');
        return;
    }

    my ($res, $label);
    if ($action eq 'toggle_pause') {
        my $st = uc($s->{status} // '');
        if ($st eq 'ACTIVE') {
            $res   = eval { $mgr->pause($id, $fp) };
            $label = "paused";
        } elsif ($st eq 'PAUSED') {
            $res   = eval { $mgr->resume($id, $fp) };
            $label = "resumed";
        } else {
            $app->set_toast("Subscription $id is $st and cannot be paused/resumed.", 'warn');
            return;
        }
    } elsif ($action eq 'skip') {
        $res   = eval { $mgr->skip_next($id, $fp) };
        $label = "next delivery skipped";
    } elsif ($action eq 'cancel') {
        $res   = eval { $mgr->cancel($id, $fp) };
        $label = "canceled";
    }

    if ($@) {
        $app->set_toast("Subscription update failed: $@", 'err');
        return;
    }
    if (ref($res) eq 'HASH' && exists($res->{ok}) && !$res->{ok}) {
        $app->set_toast($res->{error} // "Subscription update failed.", 'err');
        return;
    }

    $self->refresh($app);
    my $kind = ($action eq 'cancel') ? 'warn' : 'ok';
    $app->set_toast("Subscription $id $label.", $kind);
}

sub handle_key {
    my ($self, $app, $ev) = @_;
    my $type = $ev->{type} // '';
    my $ch   = $ev->{char} // '';
    my $n    = scalar(@{ $self->{subs} });

    if ($type eq 'ESC') {
        $app->switch_view('catalog');
        return 1;
    }

    if ($type eq 'MOUSE' && $ev->{press}) {
        my $btn = $ev->{button} // '';
        if ($btn eq 'wheel_down' && $n > 0 && $self->{selected} < $n - 1) {
            $self->{selected}++;
            return 1;
        }
        if ($btn eq 'wheel_up' && $n > 0 && $self->{selected} > 0) {
            $self->{selected}--;
            return 1;
        }
        return 0;
    }

    if ($type eq 'DOWN' && $n > 0 && $self->{selected} < $n - 1) {
        $self->{selected}++;
        return 1;
    }
    if ($type eq 'UP' && $n > 0 && $self->{selected} > 0) {
        $self->{selected}--;
        return 1;
    }

    if ($type eq 'CHAR') {
        if ($ch eq '1' || $ch eq '2' || $ch eq '3') {
            my $idx  = int($ch) - 1;
            my $tier = $self->{tiers}[$idx];
            my $code = ($tier && $tier->{code}) ? uc($tier->{code}) : ('FREE', 'PRO', 'FOUNDER')[$idx];
            $self->_enroll_tier($app, $code);
            return 1;
        }
        if (lc($ch) eq 'u') {
            $self->_upgrade_tier($app);
            return 1;
        }
        if (lc($ch) eq 'x') {
            $self->_cancel_membership($app);
            return 1;
        }
        if (lc($ch) eq 'p') {
            $self->_sub_action($app, 'toggle_pause');
            return 1;
        }
        if (lc($ch) eq 'k') {
            $self->_sub_action($app, 'skip');
            return 1;
        }
        if (lc($ch) eq 'c') {
            $self->_sub_action($app, 'cancel');
            return 1;
        }
        if (lc($ch) eq 'j' && $n > 0 && $self->{selected} < $n - 1) {
            $self->{selected}++;
            return 1;
        }
        if (lc($ch) eq 'r') {
            $self->refresh($app);
            $app->set_toast("Memberships and subscriptions refreshed.", 'ok');
            return 1;
        }
    }

    return 0;
}

sub _status_style {
    my ($status, $pal) = @_;
    $status = uc($status // '');
    return $pal->{ok}   if $status eq 'ACTIVE';
    return $pal->{warn} if $status eq 'PAUSED' || $status eq 'PAST_DUE';
    return $pal->{err}  if $status eq 'CANCELED' || $status eq 'CANCELLED';
    return $pal->{dim};
}

sub draw {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};

    my $top_h = 8;
    $top_h = int($h / 2) if $h < 14;
    $top_h = 6 if $top_h < 6 && $h >= 10;
    my $bot_y = $y + $top_h;
    my $bot_h = $h - $top_h;

    # --- Top Pane: Membership Tier Summary ---
    my $m        = $self->{membership};
    my $cur_tier = ($m && $m->{tier_code}) ? uc($m->{tier_code}) : 'FREE';
    my $cur_stat = ($m && $m->{status})    ? uc($m->{status})    : 'NONE';
    my $badge    = ($cur_stat eq 'ACTIVE') ? "[$cur_tier ACTIVE]" : "[$cur_tier $cur_stat]";

    $scr->box($x, $y, $w, $top_h, $pal->{border}, "Membership Plan $badge", $pal->{title});
    my $iw = $w - 4;
    my $py = $y + 1;

    my $renews = ($m && length($m->{renews_at} // '')) ? "  Renews: $m->{renews_at}" : '';
    $scr->write_str(
        $x + 2, $py++,
        "Current Plan: $cur_tier  Status: $cur_stat$renews",
        _status_style($cur_stat, $pal), $iw
    );

    my $tiers = $self->{tiers} || \@DEFAULT_TIERS;
    for (my $i = 0; $i < @$tiers && $py < $y + $top_h - 2; $i++) {
        my $t     = $tiers->[$i];
        my $code  = uc($t->{code} // '');
        my $price = $app->format_money($t->{monthly_price} // '0.00');
        my $disc  = sprintf('%.0f', ($t->{discount_pct} // 0) + 0);
        my $ship  = $t->{free_shipping} ? '+ free ship' : 'standard ship';
        my $prio  = $t->{priority_fulfillment} ? ' + priority' : '';
        my $mark  = ($cur_stat eq 'ACTIVE' && $cur_tier eq $code) ? '*' : ' ';
        my $line  = sprintf(
            "%s [%d] %-8s \$%5s/mo  %2s%% off  %s%s",
            $mark, $i + 1, $code, $price, $disc, $ship, $prio
        );
        my $st = ($mark eq '*') ? $pal->{ok} : $pal->{normal};
        $scr->write_str($x + 2, $py++, $line, $st, $iw);
    }

    if ($y + $top_h - 2 >= $py) {
        $scr->write_str(
            $x + 2, $y + $top_h - 2,
            "Actions: [1] FREE  [2] PRO  [3] FOUNDER  [u] Upgrade  [x] Cancel Membership",
            $pal->{key}, $iw
        );
    }

    # --- Bottom Pane: Recurring Subscriptions ---
    return if $bot_h < 4;
    my $subs = $self->{subs} || [];
    my $n    = scalar(@$subs);
    $scr->box($x, $bot_y, $w, $bot_h, $pal->{border}, "Recurring Subscriptions ($n)", $pal->{title});

    my $sy = $bot_y + 1;
    $scr->write_str(
        $x + 2, $sy++,
        sprintf("%-14s %-10s %3s %-8s %9s %-16s %-9s",
            "ID", "SKU", "QTY", "CADENCE", "PRICE", "NEXT BILL", "STATUS"),
        $pal->{dim}, $iw
    );

    if ($n == 0) {
        $scr->write_str(
            $x + 2, $sy + 1,
            "No recurring subscriptions yet. Open a product in [1]Shop and press [S] to subscribe.",
            $pal->{dim}, $iw
        );
        return;
    }

    my $list_h = $bot_h - 4;
    $list_h = 1 if $list_h < 1;
    if ($self->{selected} < $self->{scroll}) {
        $self->{scroll} = $self->{selected};
    } elsif ($self->{selected} >= $self->{scroll} + $list_h) {
        $self->{scroll} = $self->{selected} - $list_h + 1;
    }

    for (my $row = 0; $row < $list_h; $row++) {
        my $idx = $self->{scroll} + $row;
        last if $idx >= $n;
        my $s     = $subs->[$idx];
        my $id    = substr($s->{id} // '', 0, 14);
        my $sku   = substr($s->{sku} // '', 0, 10);
        my $qty   = int($s->{qty} // 1);
        my $every = 'every ' . int($s->{interval_days} // 30) . 'd';
        my $price = '$' . $app->format_money($s->{unit_price} // '0.00');
        my $nb    = substr($s->{next_bill_at} // '-', 0, 16);
        my $stat  = uc($s->{status} // 'ACTIVE');
        my $line  = sprintf("%-14s %-10s %3d %-8s %9s %-16s %-9s",
            $id, $sku, $qty, $every, $price, $nb, $stat);
        my $st = ($idx == $self->{selected}) ? $pal->{sel} : _status_style($stat, $pal);
        $scr->write_str($x + 2, $sy + $row, $line, $st, $iw);
    }

    if ($bot_h >= 5) {
        $scr->write_str(
            $x + 2, $bot_y + $bot_h - 2,
            "Selected: [p] Pause/Resume  [k] Skip Next Delivery  [c] Cancel Subscription",
            $pal->{key}, $iw
        );
    }
}

1;
