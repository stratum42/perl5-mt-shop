package Shop::TUI::App;

use strict;
use warnings;
use utf8;

use Time::HiRes qw(time usleep);
use MT::Decimal ();
use Shop::TUI::Screen ();
use Shop::TUI::Input  ();
use Shop::TUI::View::Catalog       ();
use Shop::TUI::View::ProductDetail ();
use Shop::TUI::View::Cart          ();
use Shop::TUI::View::Checkout      ();
use Shop::TUI::View::Orders        ();
use Shop::TUI::View::Account       ();
use Shop::TUI::View::Admin         ();

BEGIN {
    eval { require Shop::Shipping::Shippo };
    eval { require Shop::Tax::Nexus };
}

my %VIEW_CLASSES = (
    catalog        => 'Shop::TUI::View::Catalog',
    product_detail => 'Shop::TUI::View::ProductDetail',
    cart           => 'Shop::TUI::View::Cart',
    checkout       => 'Shop::TUI::View::Checkout',
    orders         => 'Shop::TUI::View::Orders',
    account        => 'Shop::TUI::View::Account',
    admin          => 'Shop::TUI::View::Admin',
    subscriptions  => 'Shop::TUI::View::Subscriptions',
);

my $DEFAULT_PALETTE = {
        normal        => Shop::TUI::Screen::STYLE_DEFAULT,
        header        => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BWHITE, bg => Shop::TUI::Screen::BG_BLUE, bold => 1),
        header_accent => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BYELLOW, bg => Shop::TUI::Screen::BG_BLUE, bold => 1),
        pq_badge      => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BGREEN,  bg => Shop::TUI::Screen::BG_BLUE, bold => 1),
        eff_badge     => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BCYAN,   bg => Shop::TUI::Screen::BG_BLUE, bold => 1),
        tab_act       => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BLACK,   bg => Shop::TUI::Screen::BG_CYAN, bold => 1),
        tab_inact     => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_WHITE,   bg => Shop::TUI::Screen::BG_BLUE),
        sel           => Shop::TUI::Screen::pack_style(rev => 1, bold => 1),
        title         => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BCYAN,  bold => 1),
        price         => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BGREEN, bold => 1),
        stock_ok      => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_GREEN),
        stock_low     => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BYELLOW, bold => 1),
        stock_out     => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BRED,   bold => 1),
        dim           => Shop::TUI::Screen::pack_style(dim => 1),
        border        => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_CYAN),
        err           => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BRED,   bold => 1),
        ok            => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BGREEN, bold => 1),
        warn          => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BYELLOW, bold => 1),
        ticker        => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_CYAN),
        broadcast     => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BYELLOW, bg => Shop::TUI::Screen::BG_RED, bold => 1),
        key           => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BWHITE, bold => 1),
        art           => Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_CYAN),
        input         => Shop::TUI::Screen::pack_style(rev => 1),
};
sub _build_palette { return $DEFAULT_PALETTE; }

sub new {
    my ($class, %args) = @_;
    my $sess = $args{session};
    my ($cols, $rows) = (80, 24);
    if ($sess && $sess->can('size')) {
        my ($c, $r) = $sess->size();
        $cols = $c if defined $c && $c >= 20;
        $rows = $r if defined $r && $r >= 8;
    }
    $cols = $args{cols} if defined $args{cols};
    $rows = $args{rows} if defined $args{rows};

    my $env = $args{env};
    if (!$env && $sess && $sess->can('env')) {
        $env = eval { $sess->env() };
    }
    $env = {} unless ref($env) eq 'HASH';

    my $user = $args{user} || ($sess && $sess->can('user') ? $sess->user() : undef) || {
        username    => 'guest',
        fingerprint => 'guest',
        pubkey_type => 'none',
        is_guest    => 1,
    };

    my $self = bless {
        session      => $sess,
        session_id   => $args{session_id} // ("sess-" . $$ . "-" . int(rand(1_000_000))),
        config       => $args{config}     || {},
        db           => $args{db},
        keydb        => $args{keydb},
        inventory    => $args{inventory},
        event_bus    => $args{event_bus},
        metrics      => $args{metrics},
        hostkey      => $args{hostkey},
        cart         => $args{cart},
        checkout     => $args{checkout},
        shippo       => $args{shippo},
        tax_nexus    => $args{tax_nexus},
        membership   => $args{membership},
        subscription => $args{subscription},
        user         => $user,
        inbox        => $args{inbox},
        _member_tier => '',

        screen       => Shop::TUI::Screen->new(cols => $cols, rows => $rows, env => $env),
        input        => Shop::TUI::Input->new(),
        palette      => _build_palette(),

        views        => {
            catalog => Shop::TUI::View::Catalog->new(),
        },
        active_view     => 'catalog',
        dirty           => 1,
        running         => 1,
        _nav_hitboxes   => [],
        _last_wire_tx   => 0,

        toast_msg       => '',
        toast_kind      => 'ok',
        toast_until     => 0,
        broadcast       => '',
        broadcast_until => 0,
        ticker_msg      => 'Welcome to PERL5-MT SHOP! Post-Quantum SSH + Lock-Free CAS + Ed25519 Receipts.',
    }, $class;

    # Load / upsert user record in DB if available
    $self->_init_user_record();
    $self->refresh_membership();
    $self->_restore_session_state();
    $self->_view($self->{active_view})->on_enter($self);

    return $self;
}

sub _init_user_record {
    my ($self) = @_;
    return unless $self->{db};
    my $fp = $self->user_fp();
    my $existing = eval { $self->{db}->get_user($fp) };
    if (ref($existing) eq 'HASH' && defined $existing->{fingerprint}) {
        $self->{user}{username}               = $existing->{username} if length($existing->{username} // '');
        $self->{user}{email}                  = $existing->{email}    if defined $existing->{email};
        $self->{user}{is_admin}               = 1 if $existing->{is_admin};
        $self->{user}{stripe_customer_id}     = $existing->{stripe_customer_id}     if defined $existing->{stripe_customer_id};
        $self->{user}{default_payment_method} = $existing->{default_payment_method} if defined $existing->{default_payment_method};
        $self->{user}{default_payment_last4}  = $existing->{default_payment_last4}  if defined $existing->{default_payment_last4};
    } else {
        eval {
            $self->{db}->upsert_user({
                fingerprint => $fp,
                username    => $self->{user}{username} // 'guest',
                email       => $self->{user}{email}    // '',
                pubkey_type => $self->{user}{pubkey_type} // 'none',
                is_admin    => $self->is_admin() ? 1 : 0,
            });
        };
    }
}

sub _restore_session_state {
    my ($self) = @_;
    return unless $self->{keydb} && $self->{keydb}->can('load_session_state');
    my $fp = $self->user_fp();
    return if !$fp || $fp eq 'guest';

    my $st = eval { $self->{keydb}->load_session_state($fp) };
    return unless ref($st) eq 'HASH' && keys %$st;

    if (defined $st->{selected_sku} && length($st->{selected_sku})) {
        $self->{views}{catalog}->set_preferred_sku($st->{selected_sku})
            if $self->{views}{catalog}->can('set_preferred_sku');
    }
    if (defined $st->{promo_code} && length($st->{promo_code}) && $self->{cart} && $self->{cart}->can('apply_promo')) {
        eval { $self->{cart}->apply_promo($st->{promo_code}) };
    }
    my $lv = $st->{last_view} // '';
    if ($lv && exists $VIEW_CLASSES{$lv} && $lv ne 'checkout' && $lv ne 'product_detail') {
        if ($lv ne 'admin' || $self->is_admin()) {
            $self->{active_view} = $lv;
        }
    }
    $self->set_toast("Session resumed from KeyDB.", 'ok', 3.0);
}

sub _save_session_state {
    my ($self) = @_;
    return unless $self->{keydb} && $self->{keydb}->can('save_session_state');
    my $fp = $self->user_fp();
    return if !$fp || $fp eq 'guest';

    my $sel_sku = $self->{views}{catalog}->can('selected_sku')
        ? ($self->{views}{catalog}->selected_sku() // '')
        : '';
    my $promo = ($self->{cart} && $self->{cart}->can('promo_code'))
        ? ($self->{cart}->promo_code() // '')
        : '';
    my $state = {
        last_view    => $self->{active_view},
        selected_sku => $sel_sku,
        promo_code   => $promo,
        saved_at     => time(),
    };
    eval { $self->{keydb}->save_session_state($fp, $state, 86400) };
}

sub user_fp  { $_[0]->{user}{fingerprint} // 'guest' }
sub username { $_[0]->{user}{username}    // 'guest' }

sub shippo {
    my ($self) = @_;
    return $self->{shippo} if $self->{shippo};
    if (eval { require Shop::Shipping::Shippo; 1 }) {
        $self->{shippo} = eval {
            Shop::Shipping::Shippo->new(
                api_token => $ENV{SHIPPO_API_TOKEN} // ($self->{config}{shippo} && $self->{config}{shippo}{api_token}),
                keydb     => $self->{keydb},
            );
        };
    }
    return $self->{shippo};
}

sub tax_nexus {
    my ($self) = @_;
    return $self->{tax_nexus} if $self->{tax_nexus};
    if (eval { require Shop::Tax::Nexus; 1 }) {
        $self->{tax_nexus} = eval {
            Shop::Tax::Nexus->new(
                db    => $self->{db},
                keydb => $self->{keydb},
            );
        };
    }
    return $self->{tax_nexus};
}

sub membership_mgr {
    my ($self) = @_;
    return $self->{membership} if $self->{membership};
    if (eval { require Shop::Domain::Membership; 1 }) {
        $self->{membership} = eval {
            Shop::Domain::Membership->new(
                db        => $self->{db},
                event_bus => $self->{event_bus},
                metrics   => $self->{metrics},
            );
        };
    }
    return $self->{membership};
}

sub subscription_mgr {
    my ($self) = @_;
    return $self->{subscription} if $self->{subscription};
    if (eval { require Shop::Domain::Subscription; 1 }) {
        $self->{subscription} = eval {
            Shop::Domain::Subscription->new(
                db         => $self->{db},
                inventory  => $self->{inventory},
                checkout   => $self->{checkout},
                membership => $self->membership_mgr(),
                keydb      => $self->{keydb},
                event_bus  => $self->{event_bus},
                metrics    => $self->{metrics},
            );
        };
    }
    return $self->{subscription};
}

sub refresh_membership {
    my ($self) = @_;
    my $fp = $self->user_fp();
    my $m;
    if ($self->{membership} && $self->{membership}->can('get_membership')) {
        $m = eval { $self->{membership}->get_membership($fp) };
    } elsif ($self->{db} && $self->{db}->can('get_membership')) {
        $m = eval { $self->{db}->get_membership($fp) };
    }
    if (ref($m) eq 'HASH' && uc($m->{status} // '') eq 'ACTIVE') {
        my $tc = uc($m->{tier_code} // '');
        $self->{_member_tier} = ($tc eq 'PRO' || $tc eq 'FOUNDER') ? $tc : '';
    } else {
        $self->{_member_tier} = '';
    }
    return $self->{_member_tier};
}

sub active_member_badge {
    my ($self) = @_;
    my $tc = $self->{_member_tier} // '';
    return ($tc eq 'PRO' || $tc eq 'FOUNDER') ? "[$tc]" : '';
}

sub has_quick_reorder {
    my ($self) = @_;
    return 0 unless $self->{db};
    my $pm = $self->{user}{default_payment_method} // '';
    return 0 unless length($pm);
    my $addrs = eval { $self->{db}->list_addresses($self->user_fp()) };
    return (ref($addrs) eq 'ARRAY' && @$addrs > 0) ? 1 : 0;
}

sub is_admin {
    my ($self) = @_;
    return 1 if $self->{user}{is_admin};
    my $fp = $self->user_fp();
    my $admins = $self->{config}{admin_fingerprints} || [];
    for my $afp (@$admins) {
        return 1 if defined $afp && ($afp eq '*' || $afp eq $fp);
    }
    return 0;
}

sub format_money {
    my ($self, $val) = @_;
    return '0.00' unless defined $val;
    if (ref($val) && eval { $val->isa('MT::Decimal') }) {
        my $q = eval { $val->quantize(-2, MT::Decimal::ROUND_HALF_UP) };
        return defined $q ? "$q" : "$val";
    }
    my $d = eval { MT::Decimal->new("$val")->quantize(-2, MT::Decimal::ROUND_HALF_UP) };
    return defined $d ? "$d" : sprintf('%.2f', $val + 0);
}

sub set_toast {
    my ($self, $msg, $kind, $ttl) = @_;
    $self->{toast_msg}   = $msg  // '';
    $self->{toast_kind}  = $kind // 'ok';
    $self->{toast_until} = time() + ($ttl // 4.0);
    $self->{dirty}       = 1;
}

sub _view {
    my ($self, $name) = @_;
    return undef unless defined $name && exists $VIEW_CLASSES{$name};
    if (!$self->{views}{$name}) {
        my $cls = $VIEW_CLASSES{$name};
        if (!$cls->can('new')) {
            (my $mod = "$cls.pm") =~ s{::}{/}g;
            require $mod;
        }
        $self->{views}{$name} = $cls->new();
    }
    return $self->{views}{$name};
}

sub switch_view {
    my ($self, $name) = @_;
    return unless defined $name && exists $VIEW_CLASSES{$name};
    $self->{active_view} = $name;
    $self->_view($name)->on_enter($self);
    $self->{dirty} = 1;
}

sub open_product_detail {
    my ($self, $sku) = @_;
    $self->_view('product_detail')->set_sku($sku);
    $self->switch_view('product_detail');
}

sub broadcast_stock {
    my ($self, $sku) = @_;
    return unless $self->{event_bus} && $self->{inventory};
    my $rem = $self->{inventory}->get_stock($sku);
    $self->{event_bus}->broadcast({
        type  => 'stock_update',
        sku   => $sku,
        stock => $rem,
    });
}

sub add_to_cart {
    my ($self, $sku, $qty) = @_;
    $qty ||= 1;
    if (!$self->{cart}) {
        $self->set_toast("Cart service unavailable.", 'err');
        return 0;
    }
    my $res = eval { $self->{cart}->add($sku, $qty) };
    if ($@) {
        $self->set_toast("Add failed: $@", 'err');
        return 0;
    }
    if (ref($res) eq 'HASH' && $res->{ok}) {
        my $rem = $self->{inventory} ? $self->{inventory}->get_stock($sku) : '?';
        $self->set_toast("Reserved ${qty}x $sku via atomic CAS! ($rem left)", 'ok');
        $self->broadcast_stock($sku);
        return 1;
    }
    my $err = (ref($res) eq 'HASH' && $res->{error}) ? $res->{error} : "Out of stock (CAS rejected)";
    $self->set_toast($err, 'err');
    return 0;
}

sub quick_reorder {
    my ($self, $sku, $qty) = @_;
    $qty ||= 1;
    if (!$self->{checkout} || !$self->{checkout}->can('quick_reorder')) {
        $self->set_toast("Quick reorder unavailable.", 'err');
        return 0;
    }
    my $res = eval {
        $self->{checkout}->quick_reorder(
            user_fp => $self->user_fp(),
            user    => $self->{user},
            sku     => $sku,
            qty     => $qty,
        );
    };
    if ($@) {
        $self->set_toast("Quick reorder error: $@", 'err');
        return 0;
    }
    if (ref($res) eq 'HASH' && $res->{ok}) {
        $self->broadcast_stock($sku);
        my $cv = $self->_view('checkout');
        $cv->show_receipt($res) if $cv && $cv->can('show_receipt');
        $self->{active_view} = 'checkout';
        my $oid = $res->{order}{id} // 'OK';
        $self->set_toast("1-Keystroke Reorder #$oid confirmed & Ed25519 signed!", 'ok');
        $self->{dirty} = 1;
        return 1;
    }
    my $err = (ref($res) eq 'HASH' && $res->{error}) ? $res->{error} : "Quick reorder failed";
    $self->set_toast($err, 'err');
    return 0;
}

sub handle_event {
    my ($self, $ev) = @_;
    return unless ref($ev) eq 'HASH';
    my $t = $ev->{type} // '';

    if ($t eq 'stock_update') {
        my $sku = $ev->{sku} // '';
        my $qty = $ev->{stock} // '?';
        if (($ev->{reason} // '') eq 'po_received') {
            $self->{ticker_msg} = "[RESTOCKED] $sku is now $qty in stock (PO received)";
        } else {
            $self->{ticker_msg} = "[LIVE STOCK] $sku is now $qty in stock";
        }
        $self->{dirty} = 1;
    } elsif ($t eq 'shipment_updated') {
        my $oid   = $ev->{order_id} // '';
        my $trk   = $ev->{tracking_number} // '';
        my $st    = uc($ev->{status} // 'UPDATED');
        my $trk_s = length($trk) ? " [$trk]" : '';
        $self->{ticker_msg} = "[SHIPMENT] #$oid$trk_s is now $st!";
        $self->set_toast("Shipment #$oid is now $st!", 'ok', 6.0);
        if ($self->{active_view} eq 'orders' && $self->{views}{orders}) {
            $self->{views}{orders}->refresh($self);
        } elsif ($self->{active_view} eq 'admin' && $self->{views}{admin}) {
            $self->{views}{admin}->refresh($self);
        }
        $self->{dirty} = 1;
    } elsif ($t eq 'order_created' || $t eq 'order_placed') {
        my $oid = $ev->{order_id} // '';
        my $tot = $self->format_money($ev->{total} // 0);
        $self->{ticker_msg} = "[NEW ORDER] #$oid placed (\$$tot)";
        $self->{dirty} = 1;
    } elsif ($t eq 'order_status') {
        my $oid = $ev->{order_id} // '';
        my $st  = $ev->{status} // '';
        $self->{ticker_msg} = "[ORDER UPDATE] #$oid -> $st";
        $self->{dirty} = 1;
    } elsif ($t eq 'payment_confirmed') {
        my $oid = $ev->{order_id} // $ev->{order_number} // '';
        my $tot = defined $ev->{total} ? (' ($' . $self->format_money($ev->{total}) . ')') : '';
        $self->{ticker_msg} = "[WEBHOOK PAID] Order #$oid confirmed$tot";
        if ($self->{views}{checkout} && $self->{views}{checkout}->can('on_payment_confirmed')) {
            $self->{views}{checkout}->on_payment_confirmed($self, $ev);
        }
        if ($self->{active_view} eq 'orders' && $self->{views}{orders}) {
            $self->{views}{orders}->refresh($self);
        }
        $self->set_toast("Stripe payment confirmed live for Order #$oid!", 'ok', 6.0);
        $self->{dirty} = 1;
    } elsif ($t eq 'membership_updated') {
        my $tier = uc($ev->{tier_code} // 'FREE');
        my $st   = uc($ev->{status}    // 'ACTIVE');
        if ($st eq 'ACTIVE' && ($tier eq 'PRO' || $tier eq 'FOUNDER')) {
            $self->{_member_tier} = $tier;
        } else {
            $self->{_member_tier} = '';
        }
        $self->{ticker_msg} = "[MEMBERSHIP] Plan $tier is now $st";
        $self->set_toast("Membership updated: $tier ($st)", ($st eq 'ACTIVE' ? 'ok' : 'warn'), 6.0);
        if ($self->{active_view} eq 'subscriptions' && $self->{views}{subscriptions}) {
            $self->{views}{subscriptions}->refresh($self);
        } elsif ($self->{active_view} eq 'admin' && $self->{views}{admin}) {
            $self->{views}{admin}->refresh($self);
        }
        $self->{dirty} = 1;
    } elsif ($t eq 'subscription_renewed') {
        my $sid = $ev->{sub_id}   // '';
        my $oid = $ev->{order_id} // '';
        my $sku = $ev->{sku}      // '';
        my $tot = $self->format_money($ev->{total} // 0);
        $self->{ticker_msg} = "[SUB RENEWED] $sid ($sku) -> Order #$oid (\$$tot)";
        $self->set_toast("Subscription $sid renewed: Order #$oid (\$$tot)", 'ok', 6.0);
        if ($self->{active_view} eq 'subscriptions' && $self->{views}{subscriptions}) {
            $self->{views}{subscriptions}->refresh($self);
        } elsif ($self->{active_view} eq 'orders' && $self->{views}{orders}) {
            $self->{views}{orders}->refresh($self);
        } elsif ($self->{active_view} eq 'admin' && $self->{views}{admin}) {
            $self->{views}{admin}->refresh($self);
        }
        $self->{dirty} = 1;
    } elsif ($t eq 'broadcast') {
        my $msg = $ev->{message} // '';
        my $who = $ev->{from}    // 'admin';
        $self->{broadcast}       = "[BROADCAST from $who] $msg";
        $self->{broadcast_until} = time() + 15.0;
        $self->{ticker_msg}      = $self->{broadcast};
        $self->{dirty}           = 1;
    }
}

sub handle_key {
    my ($self, $ev) = @_;
    my $type = $ev->{type} // '';
    my $ch   = $ev->{char} // '';

    if ($type eq 'CTRL_C') {
        $self->{running} = 0;
        return 1;
    }
    if ($type eq 'CTRL_L') {
        $self->{screen}->invalidate();
        $self->{dirty} = 1;
        return 1;
    }

    my $view = $self->{views}{ $self->{active_view} };
    my $capturing = $view->is_capturing_text();

    # Clickable persistent header navigation tabs (Row 0)
    if ($type eq 'MOUSE' && $ev->{press} && ($ev->{button} // '') eq 'left' && ($ev->{y} // -1) == 0 && !$capturing) {
        my $mx = $ev->{x} // -1;
        for my $hb (@{ $self->{_nav_hitboxes} || [] }) {
            if ($mx >= $hb->{x0} && $mx < $hb->{x1}) {
                $self->switch_view($hb->{view});
                return 1;
            }
        }
        return 0;
    }

    # Global view switcher shortcuts when not typing in a text field
    if (!$capturing && $type eq 'CHAR') {
        if ($ch eq 'q' || $ch eq 'Q') {
            $self->{running} = 0;
            return 1;
        }
        my $in_subs = ($self->{active_view} eq 'subscriptions');
        if (!$in_subs && $ch eq '1') { $self->switch_view('catalog'); return 1; }
        if (!$in_subs && $ch eq '2') { $self->switch_view('cart');    return 1; }
        if (!$in_subs && $ch eq '3') { $self->switch_view('orders');  return 1; }
        if ($ch eq '4') { $self->switch_view('account');       return 1; }
        if ($ch eq '5') { $self->switch_view('admin');         return 1; }
        if ($ch eq '8') { $self->switch_view('subscriptions'); return 1; }
    }

    my $changed = $view->handle_key($self, $ev);
    $self->{dirty} = 1 if $changed;
    return $changed;
}

sub _security_pill {
    my ($self) = @_;
    my $sec = ($self->{session} && $self->{session}->can('security_info'))
        ? (eval { $self->{session}->security_info() } || {})
        : {};
    my $is_pq = $sec->{is_pq} || (($sec->{kex} // '') =~ /mlkem/i);
    my $kex_tag = $is_pq ? '[PQ:MLKEM768]' : '[X25519]';

    my $sm = $self->{screen}->metrics();
    my $tm = ($self->{session} && $self->{session}->can('egress_stats'))
        ? (eval { $self->{session}->egress_stats() } || {})
        : {};
    my $full_b = $sm->{full_frame_bytes_est} || 0;
    my $diff_b = $sm->{diff_bytes_emitted}   || 0;
    my $wire_b = $tm->{wire_tx_bytes}        || $diff_b;
    my $comp   = $tm->{compression}          || $sec->{compression} || 'none';

    my $pct = $full_b > 0 ? sprintf('%.0f', 100.0 * (1.0 - ($wire_b / $full_b))) : '0';
    $pct = '0' if $pct < 0;
    my $eff_tag = ($comp ne 'none') ? "[ZLIB:-${pct}%]" : "[DIFF:-${pct}%]";

    return ($kex_tag, $eff_tag . '[CAS]', $is_pq);
}

# Render current UI state to minimal ANSI diff string ('' if unchanged)
sub render_frame {
    my ($self) = @_;
    return '' unless $self->{dirty};
    $self->{dirty} = 0;

    my $scr  = $self->{screen};
    my $pal  = $self->{palette};
    my $cols = $scr->cols();
    my $rows = $scr->rows();
    my $now  = time();

    $scr->clear();

    # --- Row 0: Persistent Header with clickable tabs + live Security & Efficiency pill ---
    $scr->clear_rect(0, 0, $cols, 1, $pal->{header});
    $scr->write_str(0, 0, " PERL5-MT ", $pal->{header_accent});

    my $cart_cnt = $self->{cart} ? ($self->{cart}->item_count() // 0) : 0;
    my $cart_tot = $self->{cart} ? $self->format_money(($self->{cart}->totals() || {})->{total}) : '0.00';

    my @nav = (
        [ 'catalog',       '[1]Shop' ],
        [ 'cart',          "[2]Cart($cart_cnt)" ],
        [ 'orders',        '[3]Orders' ],
        [ 'account',       '[4]Acct' ],
        [ 'subscriptions', '[8]Subs' ],
    );
    push @nav, [ 'admin', '[5]Admin' ] if $self->is_admin();

    my $mem_badge = $self->active_member_badge();
    my ($kex_tag, $eff_tag, $is_pq) = $self->_security_pill();
    my $pill_str  = "$kex_tag$eff_tag";
    my $right_tot = " \$$cart_tot ";
    my $compact   = ($cols < 100) ? 1 : 0;

    my @hitboxes;
    my $nx = $compact ? 10 : 11;
    for my $item (@nav) {
        my ($vname, $lbl) = @$item;
        my $act = ($self->{active_view} eq $vname || ($vname eq 'catalog' && $self->{active_view} eq 'product_detail'));
        my $tab_str = $compact ? "$lbl " : " $lbl ";
        my $tw = length($tab_str);
        last if $nx + $tw > $cols - length($right_tot);
        $scr->write_str($nx, 0, $tab_str, $act ? $pal->{tab_act} : $pal->{tab_inact});
        push @hitboxes, { view => $vname, x0 => $nx, x1 => $nx + $tw };
        $nx += $tw;
    }
    $self->{_nav_hitboxes} = \@hitboxes;

    # Right side of header: [PRO]/[FOUNDER] + [PQ:MLKEM768][ZLIB:-98%][CAS] + $total
    my $rx_tot = $cols - length($right_tot);
    if ($rx_tot > $nx) {
        $scr->write_str($rx_tot, 0, $right_tot, $pal->{header_accent});
    }
    my $rx_cur = $rx_tot;
    if (length($mem_badge) && ($rx_cur - length($mem_badge) - 1) >= $nx) {
        $rx_cur -= length($mem_badge);
        $scr->write_str($rx_cur, 0, $mem_badge, $pal->{header_accent});
    }
    my $rx_pill = $rx_cur - length($pill_str);
    if ($rx_pill > $nx) {
        $scr->write_str($rx_pill, 0, $kex_tag, $is_pq ? $pal->{pq_badge} : $pal->{header_accent});
        $scr->write_str($rx_pill + length($kex_tag), 0, $eff_tag, $pal->{eff_badge});
    } elsif ($rx_cur - length($kex_tag) > $nx) {
        $scr->write_str($rx_cur - length($kex_tag), 0, $kex_tag, $is_pq ? $pal->{pq_badge} : $pal->{header_accent});
    }

    # --- Row 1: Broadcast / Toast / Divider ---
    if (length($self->{broadcast}) && $now < $self->{broadcast_until}) {
        $scr->clear_rect(0, 1, $cols, 1, $pal->{broadcast});
        $scr->write_str(1, 1, $self->{broadcast}, $pal->{broadcast}, $cols - 2);
    } elsif (length($self->{toast_msg}) && $now < $self->{toast_until}) {
        my $tst = $self->{toast_kind} eq 'err'  ? $pal->{err}
                : $self->{toast_kind} eq 'warn' ? $pal->{warn}
                :                                 $pal->{ok};
        $scr->write_str(1, 1, ">> $self->{toast_msg}", $tst, $cols - 2);
    } else {
        $scr->hline(0, 1, $cols, undef, $pal->{dim});
    }

    # --- Body: Active View ---
    my $body_y = 2;
    my $body_h = $rows - 4;
    if ($body_h >= 4) {
        my $view = $self->{views}{ $self->{active_view} };
        $view->draw($self, $scr, 0, $body_y, $cols, $body_h);
    }

    # --- Row rows-2: Context Help Bar ---
    my $view = $self->{views}{ $self->{active_view} };
    my $help = $view->help_text($self) . " | [q] Quit";
    $scr->write_str(1, $rows - 2, $help, $pal->{dim}, $cols - 2);

    # --- Row rows-1: Live Bottom Ticker + Egress Savings Badge ---
    my $sm = $scr->metrics();
    my $ebadge = sprintf(" [Diff:-%.0f%%|%s] ", $sm->{savings_pct} // 0, $scr->color_depth());
    my $t_w = $cols - length($ebadge) - 2;
    $scr->write_str(1, $rows - 1, $self->{ticker_msg}, $pal->{ticker}, $t_w) if $t_w > 4;
    $scr->write_str($cols - length($ebadge), $rows - 1, $ebadge, $pal->{ok});

    return $scr->render();
}

sub _record_egress_metrics {
    my ($self) = @_;
    return unless $self->{metrics};
    my $scr = $self->{screen};
    my $df = $scr->last_full_bytes();
    my $dd = $scr->last_diff_bytes();
    $self->{metrics}->inc('ssh_egress_full_bytes', $df) if $df > 0;
    $self->{metrics}->inc('ssh_egress_diff_bytes', $dd) if $dd > 0;

    if ($self->{session} && $self->{session}->can('egress_stats')) {
        my $tm = eval { $self->{session}->egress_stats() } || {};
        my $cur_wire = $tm->{wire_tx_bytes} // 0;
        my $dw = $cur_wire - $self->{_last_wire_tx};
        if ($dw > 0) {
            $self->{metrics}->inc('ssh_egress_wire_bytes', $dw);
            $self->{_last_wire_tx} = $cur_wire;
        }
    }
}

# Main cooperative session loop (designed to run inside an MT::Fiber!)
sub run {
    my ($self) = @_;
    my $sess = $self->{session};
    return unless $sess;

    # Register on EventBus for live push notifications
    if ($self->{event_bus} && !$self->{inbox}) {
        $self->{inbox} = $self->{event_bus}->register_session($self->{session_id}, {
            username    => $self->username(),
            fingerprint => $self->user_fp(),
            view        => $self->{active_view},
            started_at  => time(),
        });
    }

    # Enter alt-screen, hide cursor, enable SGR mouse reporting
    $sess->write_output(Shop::TUI::Screen::init_sequence());

    # Initial frame
    my $first = $self->render_frame();
    if (length($first)) {
        $sess->write_output($first);
        $self->_record_egress_metrics();
    }

    while ($self->{running}) {
        my $did_work = 0;

        # 1. Check for terminal resize (SSH window-change)
        if ($sess->can('poll_resize')) {
            my ($nc, $nr) = $sess->poll_resize();
            if (defined $nc && defined $nr) {
                if ($self->{screen}->resize($nc, $nr)) {
                    $self->{dirty} = 1;
                    $did_work = 1;
                }
            }
        }

        # 2. Non-blocking SSH input read
        my $raw = $sess->read_input_nonblock();
        if (!defined $raw) {
            # EOF / client disconnected
            $self->{running} = 0;
            last;
        }
        if (length($raw)) {
            $did_work = 1;
            my @evs = $self->{input}->parse($raw);
            for my $ev (@evs) {
                $self->handle_key($ev);
                last unless $self->{running};
            }
        }

        # 3. Poll EventBus inbox for live stock/order/webhook/broadcast updates
        if ($self->{event_bus} && $self->{inbox}) {
            my $evs = $self->{event_bus}->poll_inbox($self->{inbox});
            if (ref($evs) eq 'ARRAY' && @$evs) {
                $did_work = 1;
                $self->handle_event($_) for @$evs;
            }
        }

        # 4. Expire toast/broadcast banners cleanly
        my $now = time();
        if (length($self->{toast_msg}) && $now >= $self->{toast_until}) {
            $self->{toast_msg} = '';
            $self->{dirty} = 1;
        }
        if (length($self->{broadcast}) && $now >= $self->{broadcast_until}) {
            $self->{broadcast} = '';
            $self->{dirty} = 1;
        }

        # 5. Render diff & flush ONLY if dirty
        if ($self->{dirty} && $self->{running}) {
            my $diff = $self->render_frame();
            if (length($diff)) {
                $sess->write_output($diff);
                $self->_record_egress_metrics();
            }
        }

        # 6. Yield cooperatively to other fibers (never block the worker OS thread
        # with usleep inside a fiber - the worker dispatcher owns idle backoff!)
        if (defined(&MT::Fiber::current) && MT::Fiber::current()) {
            MT::Fiber::pass();
        } elsif (!$did_work) {
            usleep(10_000); # standalone non-fiber mode only
        }
    }

    # Cleanup: save session state to KeyDB, release uncommitted cart leases, unregister, restore terminal
    $self->_save_session_state();
    eval { $self->{cart}->clear(release_stock => 1) } if $self->{cart};
    eval { $self->{event_bus}->unregister_session($self->{session_id}) } if $self->{event_bus};
    eval { $sess->write_output(Shop::TUI::Screen::cleanup_sequence()) };
    eval { $sess->close() };
}

1;
