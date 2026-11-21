package Shop::TUI::View::Cart;

use strict;
use warnings;
use Shop::TUI::Input ();

sub new {
    my ($class, %args) = @_;
    return bless {
        selected   => 0,
        scroll     => 0,
        promo_mode => 0,
        promo_buf  => '',
    }, $class;
}

sub on_enter {
    my ($self, $app) = @_;
    $self->{promo_mode} = 0;
}

sub is_capturing_text {
    return $_[0]->{promo_mode} ? 1 : 0;
}

sub help_text {
    my ($self) = @_;
    if ($self->{promo_mode}) {
        return "PROMO CODE: Type code | [Enter] Apply | [Esc] Cancel";
    }
    return "[Up/Down] Select | [+/-] Qty | [d] Remove | [p] Promo Code | [c] Checkout | [X] Clear";
}

sub handle_key {
    my ($self, $app, $ev) = @_;
    my $type = $ev->{type} // '';
    my $ch   = $ev->{char} // '';
    my $cart = $app->{cart};
    return 0 unless $cart;

    if ($self->{promo_mode}) {
        if ($type eq 'ENTER') {
            $self->{promo_mode} = 0;
            if (length($self->{promo_buf})) {
                my $res = $cart->apply_promo(uc($self->{promo_buf}));
                if (ref($res) eq 'HASH' && $res->{ok}) {
                    $app->set_toast("Promo '$self->{promo_buf}' applied!", 'ok');
                } else {
                    my $err = (ref($res) eq 'HASH' && $res->{error}) ? $res->{error} : "Invalid promo code";
                    $app->set_toast($err, 'err');
                }
            } else {
                $cart->clear_promo();
                $app->set_toast("Promo code cleared.", 'ok');
            }
            $self->{promo_buf} = '';
            return 1;
        }
        if ($type eq 'ESC') {
            $self->{promo_mode} = 0;
            $self->{promo_buf}  = '';
            return 1;
        }
        if ($type eq 'BACKSPACE') {
            chop($self->{promo_buf}) if length($self->{promo_buf});
            return 1;
        }
        if ($type eq 'CHAR' && length($self->{promo_buf}) < 24) {
            $self->{promo_buf} .= uc($ch);
            return 1;
        }
        return 0;
    }

    my $items = $cart->items() || [];
    my $n     = scalar(@$items);
    $self->{selected} = $n - 1 if $n > 0 && $self->{selected} >= $n;
    $self->{selected} = 0      if $self->{selected} < 0;

    my $nav = Shop::TUI::Input::nav($ev);
    if ($nav eq 'DOWN' && $n > 0 && $self->{selected} < $n - 1) {
        $self->{selected}++;
        return 1;
    }
    if ($nav eq 'UP' && $n > 0 && $self->{selected} > 0) {
        $self->{selected}--;
        return 1;
    }
    if ($type eq 'CHAR' && ($ch eq '+' || $ch eq '=') && $n > 0) {
        my $it = $items->[$self->{selected}];
        $app->add_to_cart($it->{sku}, 1);
        return 1;
    }
    if ($type eq 'CHAR' && $ch eq '-' && $n > 0) {
        my $it = $items->[$self->{selected}];
        $cart->remove($it->{sku}, 1);
        $app->broadcast_stock($it->{sku});
        $app->set_toast("Decreased $it->{sku} quantity.", 'ok');
        return 1;
    }
    if ($type eq 'CHAR' && ($ch eq 'd' || $ch eq 'x') && $n > 0) {
        my $it = $items->[$self->{selected}];
        $cart->remove($it->{sku});
        $app->broadcast_stock($it->{sku});
        $app->set_toast("Removed $it->{sku} from cart.", 'ok');
        return 1;
    }
    if ($type eq 'CHAR' && $ch eq 'X' && $n > 0) {
        my @skus = map { $_->{sku} } @$items;
        $cart->clear(release_stock => 1);
        $app->broadcast_stock($_) for @skus;
        $app->set_toast("Cart cleared and stock leases released.", 'ok');
        return 1;
    }
    if ($type eq 'CHAR' && lc($ch) eq 'p') {
        $self->{promo_mode} = 1;
        $self->{promo_buf}  = '';
        return 1;
    }
    if ($type eq 'CHAR' && lc($ch) eq 'c') {
        if ($n == 0) {
            $app->set_toast("Cart is empty! Add items from the Catalog first.", 'warn');
        } else {
            $app->switch_view('checkout');
        }
        return 1;
    }
    return 0;
}

sub draw {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal  = $app->{palette};
    my $cart = $app->{cart};
    my $items  = $cart ? ($cart->items() || []) : [];
    my $totals = $cart ? $cart->totals() : {};
    my $n      = scalar(@$items);

    $self->{selected} = $n - 1 if $n > 0 && $self->{selected} >= $n;
    $self->{selected} = 0      if $self->{selected} < 0;

    my $summary_w = 30;
    my $list_w    = $w - $summary_w - 1;
    if ($list_w < 36) {
        $list_w    = $w;
        $summary_w = 0;
    }

    # Left: Line items
    $scr->box($x, $y, $list_w, $h, $pal->{border}, "Shopping Cart ($n items)", $pal->{title});
    my $iw = $list_w - 2;
    my $ih = $h - 3;

    if ($n == 0) {
        $scr->write_str($x + 2, $y + 2, "Your cart is empty.", $pal->{dim}, $iw - 2);
        $scr->write_str($x + 2, $y + 4, "Press [1] to browse the Catalog.", $pal->{key}, $iw - 2);
    } else {
        my $name_w = $iw - 31;
        $name_w = 10 if $name_w < 10;
        $scr->write_str($x + 1, $y + 1, sprintf("%-8s %-*s %4s %8s %8s", "SKU", $name_w, "ITEM", "QTY", "UNIT", "LINE"), $pal->{dim}, $iw);

        if ($self->{selected} < $self->{scroll}) { $self->{scroll} = $self->{selected}; }
        elsif ($self->{selected} >= $self->{scroll} + $ih) { $self->{scroll} = $self->{selected} - $ih + 1; }

        for (my $r = 0; $r < $ih; $r++) {
            my $idx = $self->{scroll} + $r;
            last if $idx >= $n;
            my $it = $items->[$idx];
            my $is_sel = ($idx == $self->{selected});
            my $unit_s = '$' . $app->format_money($it->{unit_price} // $it->{price});
            my $line_s = '$' . $app->format_money($it->{line_total} // (($it->{unit_price} // $it->{price} // 0) * ($it->{qty} // 1)));
            my $nm = substr($it->{name} // $it->{sku}, 0, $name_w);
            my $str = sprintf("%-8s %-*s %4d %8s %8s", substr($it->{sku}, 0, 8), $name_w, $nm, $it->{qty} // 1, $unit_s, $line_s);
            if ($is_sel) {
                $str .= ' ' x ($iw - length($str)) if length($str) < $iw;
                $scr->write_str($x + 1, $y + 2 + $r, $str, $pal->{sel}, $iw);
            } else {
                $scr->write_str($x + 1, $y + 2 + $r, $str, $pal->{normal}, $iw);
            }
        }
    }

    # Right: Exact MT::Decimal Totals Summary
    if ($summary_w > 0) {
        my $sx = $x + $list_w + 1;
        $scr->box($sx, $y, $summary_w, $h, $pal->{border}, "Order Summary", $pal->{title});
        my $sw = $summary_w - 4;
        my $sy = $y + 2;

        my $sub_s  = '$' . $app->format_money($totals->{subtotal});
        my $disc_s = '-$' . $app->format_money($totals->{discount});
        my $ship_s = $totals->{free_shipping} ? 'FREE' : ('$' . $app->format_money($totals->{shipping}));
        my $tax_s  = '$' . $app->format_money($totals->{tax});
        my $tot_s  = '$' . $app->format_money($totals->{total});

        $scr->write_str($sx + 2, $sy++, sprintf("%-12s %12s", "Subtotal:", $sub_s), $pal->{normal}, $sw);
        if ($totals->{promo_applied}) {
            $scr->write_str($sx + 2, $sy++, sprintf("%-12s %12s", "Promo:", $disc_s), $pal->{ok}, $sw);
        }
        $scr->write_str($sx + 2, $sy++, sprintf("%-12s %12s", "Shipping:", $ship_s), $totals->{free_shipping} ? $pal->{ok} : $pal->{normal}, $sw);
        $scr->write_str($sx + 2, $sy++, sprintf("%-12s %12s", "Tax:", $tax_s), $pal->{normal}, $sw);
        $scr->hline($sx + 2, $sy++, $sw, '-', $pal->{border});
        $scr->write_str($sx + 2, $sy++, sprintf("%-12s %12s", "TOTAL:", $tot_s), $pal->{price}, $sw);
        $sy++;

        if ($self->{promo_mode}) {
            $scr->write_str($sx + 2, $sy++, "Enter Promo Code:", $pal->{key}, $sw);
            $scr->write_str($sx + 2, $sy++, sprintf(" %-*s", $sw - 1, $self->{promo_buf} . "_"), $pal->{input}, $sw);
        } else {
            my $pinfo = $totals->{promo_applied} ? "Applied: $totals->{promo_applied}" : "[p] Apply Promo Code";
            $scr->write_str($sx + 2, $sy++, $pinfo, $pal->{dim}, $sw);
        }

        if ($n > 0 && $y + $h - 3 > $sy) {
            $scr->write_str($sx + 2, $y + $h - 3, "  [C] Proceed to Checkout  ", $pal->{tab_act}, $sw);
        }
    }
}

1;
