package Shop::TUI::View::ProductDetail;

use strict;
use warnings;
use Shop::TUI::Input ();

sub new {
    my ($class, %args) = @_;
    return bless {
        sku => undef,
        qty => 1,
    }, $class;
}

sub set_sku {
    my ($self, $sku) = @_;
    $self->{sku} = $sku;
    $self->{qty} = 1;
}

sub on_enter {
    my ($self, $app) = @_;
    $self->{qty} = 1 if $self->{qty} < 1;
}

sub is_capturing_text { 0 }

sub help_text {
    return "[+/- or Left/Right] Qty | [a/Enter] Add to Cart (CAS) | [S] Subscribe (30d) | [c] View Cart | [Esc/b] Back";
}

sub _subscribe_30d {
    my ($self, $app) = @_;
    return unless defined $self->{sku};
    my $mgr = $app->can('subscription_mgr') ? $app->subscription_mgr() : $app->{subscription};
    if (!$mgr || !$mgr->can('create')) {
        $app->set_toast("Subscription service unavailable.", 'err');
        return;
    }
    my $res = eval {
        $mgr->create(
            user_fp       => $app->user_fp(),
            sku           => $self->{sku},
            qty           => $self->{qty},
            interval_days => 30,
        );
    };
    if ($@) {
        $app->set_toast("Subscribe failed: $@", 'err');
        return;
    }
    if (ref($res) eq 'HASH' && exists($res->{ok}) && !$res->{ok}) {
        $app->set_toast($res->{error} // "Subscribe failed.", 'err');
        return;
    }
    my $sub = (ref($res) eq 'HASH' && ref($res->{subscription}) eq 'HASH') ? $res->{subscription} : $res;
    my $id  = (ref($sub) eq 'HASH' && $sub->{id}) ? $sub->{id} : 'OK';
    my $prc = (ref($sub) eq 'HASH' && defined $sub->{unit_price})
        ? ('$' . $app->format_money($sub->{unit_price}))
        : '';
    my $msg = "Subscribed: $self->{qty}x $self->{sku} every 30d"
            . (length($prc) ? " ($prc)" : '')
            . " [$id]";
    $app->set_toast($msg, 'ok', 5.0);
}

sub handle_key {
    my ($self, $app, $ev) = @_;
    my $type = $ev->{type} // '';
    my $nav  = Shop::TUI::Input::nav($ev);
    my $ch   = $ev->{char} // '';

    my $stock = ($app->{inventory} && defined $self->{sku})
        ? $app->{inventory}->get_stock($self->{sku})
        : 0;

    if ($type eq 'ESC' || ($type eq 'CHAR' && lc($ch) eq 'b')) {
        $app->switch_view('catalog');
        return 1;
    }
    if ($nav eq 'RIGHT' || ($type eq 'CHAR' && ($ch eq '+' || $ch eq '='))) {
        my $max = $stock > 0 ? $stock : 1;
        $self->{qty}++ if $self->{qty} < $max;
        return 1;
    }
    if ($nav eq 'LEFT' || ($type eq 'CHAR' && $ch eq '-')) {
        $self->{qty}-- if $self->{qty} > 1;
        return 1;
    }
    if ($type eq 'ENTER' || ($type eq 'CHAR' && lc($ch) eq 'a')) {
        if (defined $self->{sku}) {
            $app->add_to_cart($self->{sku}, $self->{qty});
            # Clamp qty to new remaining stock
            my $rem = $app->{inventory} ? $app->{inventory}->get_stock($self->{sku}) : 0;
            $self->{qty} = 1 if $self->{qty} > $rem;
            $self->{qty} = 1 if $self->{qty} < 1;
        }
        return 1;
    }
    if ($type eq 'CHAR' && lc($ch) eq 's') {
        $self->_subscribe_30d($app);
        return 1;
    }
    if ($type eq 'CHAR' && lc($ch) eq 'c') {
        $app->switch_view('cart');
        return 1;
    }
    return 0;
}

sub draw {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    my $inv = $app->{inventory};
    my $p   = ($inv && defined $self->{sku}) ? $inv->get_product($self->{sku}) : undef;

    $scr->box($x, $y, $w, $h, $pal->{border}, "Product Detail", $pal->{title});

    if (!$p) {
        $scr->write_str($x + 2, $y + 2, "Product not found. Press [Esc] to return to Catalog.", $pal->{err}, $w - 4);
        return;
    }

    my $live_stock = $inv->get_stock($p->{sku});
    my $price_str  = '$' . $app->format_money($p->{price});

    my $left_w = int($w * 0.44);
    $left_w = 28 if $left_w < 28 && $w >= 64;
    my $rx = $x + $left_w + 2;
    my $rw = $w - $left_w - 4;

    # Left: ASCII art
    my $art = $p->{ascii_art} // '';
    my @art_lines = split /\r?\n/, $art;
    my $ay = $y + 2;
    for my $al (@art_lines) {
        last if $ay >= $y + $h - 2;
        $scr->write_str($x + 3, $ay++, $al, $pal->{art}, $left_w - 3);
    }

    # Right: Metadata + Description + Add to Cart controls
    my $py = $y + 2;
    $scr->write_str($rx, $py++, $p->{name} // $p->{sku}, $pal->{title}, $rw);
    $scr->write_str($rx, $py++, "SKU: $p->{sku}   Category: " . ($p->{category} // 'General'), $pal->{dim}, $rw);
    $py++;

    $scr->write_str($rx, $py, "Price: ", $pal->{normal}, 7);
    $scr->write_str($rx + 7, $py++, $price_str, $pal->{price}, 16);

    my $stock_st = $live_stock <= 0 ? $pal->{stock_out}
                 : $live_stock <= 5 ? $pal->{stock_low}
                 :                    $pal->{stock_ok};
    my $stock_txt = $live_stock > 0 ? "$live_stock in stock (live CAS)" : "OUT OF STOCK";
    $scr->write_str($rx, $py, "Stock: ", $pal->{normal}, 7);
    $scr->write_str($rx + 7, $py++, $stock_txt, $stock_st, $rw - 7);
    $py++;

    # Description
    my $desc = $p->{description} // '';
    my @dlines = _wrap_text($desc, $rw);
    for my $dl (@dlines) {
        last if $py >= $y + $h - 5;
        $scr->write_str($rx, $py++, $dl, $pal->{normal}, $rw);
    }

    # Action bar at bottom of right pane
    my $ctrl_y = $y + $h - 4;
    $ctrl_y = $py + 1 if $ctrl_y < $py + 1;
    if ($ctrl_y < $y + $h - 1) {
        $scr->write_str($rx, $ctrl_y, sprintf("Quantity: [-]  %2d  [+]", $self->{qty}), $pal->{key}, $rw);
        if ($live_stock > 0) {
            my $add_lbl = " [A] Add to Cart (CAS) ";
            my $sub_lbl = " [S] Subscribe (30d) ";
            $scr->write_str($rx, $ctrl_y + 2, $add_lbl, $pal->{tab_act}, $rw);
            if ($rw >= length($add_lbl) + 2 + length($sub_lbl)) {
                $scr->write_str($rx + length($add_lbl) + 2, $ctrl_y + 2, $sub_lbl, $pal->{ok}, $rw - length($add_lbl) - 2);
            } elsif ($ctrl_y + 3 < $y + $h - 1) {
                $scr->write_str($rx, $ctrl_y + 3, $sub_lbl, $pal->{ok}, $rw);
            }
        } else {
            $scr->write_str($rx, $ctrl_y + 2, " Unavailable - Out of Stock ", $pal->{err}, $rw);
        }
    }
}

sub _wrap_text {
    my ($text, $width) = @_;
    return () if !defined $text || $width < 4;
    my @out;
    my $line = '';
    for my $word (split /\s+/, $text) {
        if (!length($line)) { $line = $word; }
        elsif (length($line) + 1 + length($word) <= $width) { $line .= ' ' . $word; }
        else { push @out, $line; $line = $word; }
    }
    push @out, $line if length($line);
    return @out;
}

1;
