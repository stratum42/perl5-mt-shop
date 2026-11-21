package Shop::TUI::View::Catalog;

use strict;
use warnings;
use Shop::TUI::Input ();
use Shop::TUI::Screen ();

sub new {
    my ($class, %args) = @_;
    return bless {
        selected      => 0,
        scroll        => 0,
        cat_idx       => 0,
        categories    => ['All'],
        search_mode   => 0,
        search_query  => '',
        products      => [],
        preferred_sku => '',
        last_refresh  => 0,
        _list_x0      => 0,
        _list_x1      => 0,
        _list_y       => 0,
        _list_h       => 0,
        _cat_hitboxes => [],
    }, $class;
}

sub set_preferred_sku {
    my ($self, $sku) = @_;
    $self->{preferred_sku} = $sku // '';
}

sub selected_sku {
    my ($self) = @_;
    my $p = $self->{products}[$self->{selected}];
    return $p ? ($p->{sku} // '') : '';
}

sub on_enter {
    my ($self, $app) = @_;
    $self->refresh($app);
}

sub refresh {
    my ($self, $app) = @_;
    my $inv = $app->{inventory};
    return unless $inv;

    # Discover categories from full catalog
    my $all = $inv->list_catalog();
    my %seen;
    my @cats = ('All');
    for my $p (@$all) {
        my $c = $p->{category} // 'General';
        if (!$seen{$c}++) {
            push @cats, $c;
        }
    }
    $self->{categories} = \@cats;
    $self->{cat_idx} = 0 if $self->{cat_idx} >= scalar(@cats);

    my $cat = $self->{categories}[$self->{cat_idx}];
    my %opt;
    $opt{category} = $cat if $cat ne 'All';
    $opt{query}    = $self->{search_query} if length($self->{search_query});

    my $list = $inv->list_catalog(%opt);
    $self->{products} = $list || [];
    if (length($self->{preferred_sku} // '')) {
        for (my $i = 0; $i < @{ $self->{products} }; $i++) {
            if (($self->{products}[$i]{sku} // '') eq $self->{preferred_sku}) {
                $self->{selected} = $i;
                last;
            }
        }
        $self->{preferred_sku} = '';
    }
    if (@{ $self->{products} } == 0) {
        $self->{selected} = 0;
        $self->{scroll}   = 0;
    } elsif ($self->{selected} >= scalar(@{ $self->{products} })) {
        $self->{selected} = scalar(@{ $self->{products} }) - 1;
    }
}

sub is_capturing_text {
    my ($self) = @_;
    return $self->{search_mode} ? 1 : 0;
}

sub help_text {
    my ($self, $app) = @_;
    if ($self->{search_mode}) {
        return "SEARCH: Type to filter | [Enter] Apply | [Esc] Cancel | [Bksp] Delete";
    }
    my $qr = ($app && $app->can('has_quick_reorder') && $app->has_quick_reorder())
        ? " | [R] 1-Click Reorder"
        : "";
    return "[Up/Down/Scroll/Click] Browse | [Enter] Details | [a] +1 Cart$qr | [/] Search | [Tab] Cat";
}

sub handle_key {
    my ($self, $app, $ev) = @_;
    my $type = $ev->{type} // '';

    if ($self->{search_mode}) {
        if ($type eq 'ENTER') {
            $self->{search_mode} = 0;
            $self->refresh($app);
            return 1;
        }
        if ($type eq 'ESC') {
            $self->{search_mode}  = 0;
            $self->{search_query} = '';
            $self->{selected}     = 0;
            $self->refresh($app);
            return 1;
        }
        if ($type eq 'BACKSPACE') {
            if (length($self->{search_query})) {
                chop($self->{search_query});
                $self->{selected} = 0;
                $self->refresh($app);
            }
            return 1;
        }
        if ($type eq 'CHAR') {
            $self->{search_query} .= $ev->{char};
            $self->{selected} = 0;
            $self->refresh($app);
            return 1;
        }
        return 0;
    }

    my $nav = Shop::TUI::Input::nav($ev);
    my $n   = scalar(@{ $self->{products} });

    # SGR Mouse support: scroll wheel navigates list, left click selects product or category
    if ($type eq 'MOUSE' && $ev->{press}) {
        my $btn = $ev->{button} // '';
        if ($btn eq 'wheel_down') {
            if ($n > 0 && $self->{selected} < $n - 1) {
                $self->{selected}++;
                return 1;
            }
            return 0;
        }
        if ($btn eq 'wheel_up') {
            if ($n > 0 && $self->{selected} > 0) {
                $self->{selected}--;
                return 1;
            }
            return 0;
        }
        if ($btn eq 'left') {
            my ($mx, $my) = ($ev->{x} // -1, $ev->{y} // -1);
            # Category tab click
            for my $hb (@{ $self->{_cat_hitboxes} || [] }) {
                if ($my == $hb->{y} && $mx >= $hb->{x0} && $mx < $hb->{x1}) {
                    if ($self->{cat_idx} != $hb->{idx}) {
                        $self->{cat_idx}  = $hb->{idx};
                        $self->{selected} = 0;
                        $self->{scroll}   = 0;
                        $self->refresh($app);
                        return 1;
                    }
                    return 0;
                }
            }
            # Product list click
            if ($n > 0 && $mx >= $self->{_list_x0} && $mx < $self->{_list_x1}
                && $my >= $self->{_list_y} && $my < $self->{_list_y} + $self->{_list_h})
            {
                my $idx = $self->{scroll} + ($my - $self->{_list_y});
                if ($idx >= 0 && $idx < $n) {
                    if ($self->{selected} == $idx) {
                        # Clicking already-selected item opens detail view
                        $app->open_product_detail($self->{products}[$idx]{sku});
                    } else {
                        $self->{selected} = $idx;
                    }
                    return 1;
                }
            }
            return 0;
        }
        return 0;
    }

    if ($nav eq 'DOWN') {
        if ($n > 0 && $self->{selected} < $n - 1) {
            $self->{selected}++;
            return 1;
        }
        return 0;
    }
    if ($nav eq 'UP') {
        if ($n > 0 && $self->{selected} > 0) {
            $self->{selected}--;
            return 1;
        }
        return 0;
    }
    if ($type eq 'PGDN') {
        if ($n > 0) {
            $self->{selected} += 8;
            $self->{selected} = $n - 1 if $self->{selected} >= $n;
            return 1;
        }
        return 0;
    }
    if ($type eq 'PGUP') {
        if ($n > 0) {
            $self->{selected} -= 8;
            $self->{selected} = 0 if $self->{selected} < 0;
            return 1;
        }
        return 0;
    }
    if ($type eq 'TAB' || ($type eq 'CHAR' && $ev->{char} eq ']')) {
        my $nc = scalar(@{ $self->{categories} });
        if ($nc > 1) {
            $self->{cat_idx} = ($self->{cat_idx} + 1) % $nc;
            $self->{selected} = 0;
            $self->{scroll}   = 0;
            $self->refresh($app);
            return 1;
        }
        return 0;
    }
    if ($type eq 'SHIFT_TAB' || ($type eq 'CHAR' && $ev->{char} eq '[')) {
        my $nc = scalar(@{ $self->{categories} });
        if ($nc > 1) {
            $self->{cat_idx} = ($self->{cat_idx} - 1 + $nc) % $nc;
            $self->{selected} = 0;
            $self->{scroll}   = 0;
            $self->refresh($app);
            return 1;
        }
        return 0;
    }
    if ($type eq 'CHAR' && $ev->{char} eq '/') {
        $self->{search_mode} = 1;
        return 1;
    }
    if ($type eq 'ESC' && length($self->{search_query})) {
        $self->{search_query} = '';
        $self->{selected}     = 0;
        $self->refresh($app);
        return 1;
    }
    if ($type eq 'ENTER' && $n > 0) {
        my $prod = $self->{products}[$self->{selected}];
        $app->open_product_detail($prod->{sku});
        return 1;
    }
    if ($type eq 'CHAR' && lc($ev->{char}) eq 'a' && $n > 0) {
        my $prod = $self->{products}[$self->{selected}];
        my $res  = $app->add_to_cart($prod->{sku}, 1);
        return 1;
    }
    if ($type eq 'CHAR' && ($ev->{char} eq 'R' || $ev->{char} eq 'r') && $n > 0) {
        if ($app->can('has_quick_reorder') && $app->has_quick_reorder()) {
            my $prod = $self->{products}[$self->{selected}];
            $app->quick_reorder($prod->{sku}, 1);
            return 1;
        }
        $app->set_toast("Save a card & address in Checkout to enable [R] 1-Keystroke Reorder.", 'warn');
        return 1;
    }

    return 0;
}

sub _stock_badge {
    my ($qty, $pal) = @_;
    $qty = int($qty // 0);
    if ($qty <= 0) {
        return ('[OUT]', $pal->{stock_out});
    } elsif ($qty <= 5) {
        return (sprintf('[LOW:%d]', $qty), $pal->{stock_low});
    } else {
        return (sprintf('[%d]', $qty), $pal->{stock_ok});
    }
}

sub draw {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    my $inv = $app->{inventory};

    # Keep product list fresh (lightweight shared-hash read)
    $self->refresh($app) if !@{ $self->{products} } && $inv;

    # Row y: Category tabs + Search box
    my @cat_hbs;
    my $cx = $x;
    for (my $i = 0; $i < @{ $self->{categories} }; $i++) {
        my $cat = $self->{categories}[$i];
        my $lbl = " $cat ";
        my $st  = ($i == $self->{cat_idx}) ? $pal->{tab_act} : $pal->{dim};
        last if $cx + length($lbl) > $x + $w - 22;
        $scr->write_str($cx, $y, $lbl, $st);
        push @cat_hbs, { idx => $i, y => $y, x0 => $cx, x1 => $cx + length($lbl) };
        $cx += length($lbl) + 1;
    }
    $self->{_cat_hitboxes} = \@cat_hbs;

    # Right-aligned search indicator
    my $sbox_w = 20;
    my $sx = $x + $w - $sbox_w;
    if ($sx > $cx) {
        my $q = $self->{search_query};
        my $lbl = $self->{search_mode}
            ? sprintf("/%-17s_", substr($q, -17))
            : (length($q) ? sprintf("Search: %-12s", substr($q, 0, 12)) : "[/] Search...");
        my $st = $self->{search_mode} ? $pal->{input} : $pal->{dim};
        $scr->write_str($sx, $y, $lbl, $st, $sbox_w);
    }

    my $body_y = $y + 1;
    my $body_h = $h - 1;
    return if $body_h < 4;

    # Split pane geometry
    my $left_w  = int($w * 0.56);
    $left_w = 36 if $left_w < 36 && $w >= 64;
    $left_w = $w if $w < 60;
    my $right_w = $w - $left_w - 1;

    # Left pane box: Catalog list
    $scr->box($x, $body_y, $left_w, $body_h, $pal->{border}, "Catalog (" . scalar(@{ $self->{products} }) . ")", $pal->{title});

    my $inner_w = $left_w - 2;
    my $inner_h = $body_h - 3; # header row + top/bottom border
    my $list_y  = $body_y + 2;

    $self->{_list_x0} = $x + 1;
    $self->{_list_x1} = $x + 1 + $inner_w;
    $self->{_list_y}  = $list_y;
    $self->{_list_h}  = $inner_h;

    # Column headers
    $scr->write_str($x + 1, $body_y + 1, sprintf("%-8s %-*s %8s %7s", "SKU", ($inner_w > 27 ? $inner_w - 26 : 10), "PRODUCT", "PRICE", "STOCK"), $pal->{dim}, $inner_w);

    my $prods = $self->{products};
    my $n = scalar(@$prods);

    if ($n == 0) {
        $scr->write_str($x + 2, $list_y + 1, "No products match your filter.", $pal->{dim}, $inner_w - 2);
    } else {
        # Adjust scroll window
        if ($self->{selected} < $self->{scroll}) {
            $self->{scroll} = $self->{selected};
        } elsif ($self->{selected} >= $self->{scroll} + $inner_h) {
            $self->{scroll} = $self->{selected} - $inner_h + 1;
        }
        $self->{scroll} = 0 if $self->{scroll} < 0;

        my $name_w = $inner_w - 26;
        $name_w = 8 if $name_w < 8;

        for (my $row = 0; $row < $inner_h; $row++) {
            my $idx = $self->{scroll} + $row;
            last if $idx >= $n;
            my $p = $prods->[$idx];
            my $is_sel = ($idx == $self->{selected});

            # Always read live stock from MT::SharedHash inventory!
            my $live_stock = $inv ? $inv->get_stock($p->{sku}) : ($p->{stock} // 0);
            my ($badge, $badge_st) = _stock_badge($live_stock, $pal);
            my $price_str = '$' . $app->format_money($p->{price});
            my $name = $p->{name} // $p->{sku};
            $name = substr($name, 0, $name_w) if length($name) > $name_w;

            my $ry = $list_y + $row;
            if ($is_sel) {
                my $line = sprintf("%-8s %-*s %8s %7s", substr($p->{sku}, 0, 8), $name_w, $name, $price_str, $badge);
                $line .= ' ' x ($inner_w - length($line)) if length($line) < $inner_w;
                $scr->write_str($x + 1, $ry, $line, $pal->{sel}, $inner_w);
            } else {
                $scr->write_str($x + 1, $ry, sprintf("%-8s ", substr($p->{sku}, 0, 8)), $pal->{dim}, 9);
                $scr->write_str($x + 10, $ry, sprintf("%-*s ", $name_w, $name), $pal->{normal}, $name_w + 1);
                $scr->write_str($x + 10 + $name_w + 1, $ry, sprintf("%8s ", $price_str), $pal->{price}, 9);
                $scr->write_str($x + 10 + $name_w + 10, $ry, sprintf("%7s", $badge), $badge_st, 7);
            }
        }
    }

    # Right pane: ASCII Art Preview & Summary
    if ($right_w >= 20) {
        my $rx = $x + $left_w + 1;
        $scr->box($rx, $body_y, $right_w, $body_h, $pal->{border}, "Preview", $pal->{title});

        if ($n > 0) {
            my $p = $prods->[$self->{selected}];
            my $live_stock = $inv ? $inv->get_stock($p->{sku}) : ($p->{stock} // 0);
            my ($badge, $badge_st) = _stock_badge($live_stock, $pal);
            my $rw = $right_w - 4;
            my $py = $body_y + 1;

            $scr->write_str($rx + 2, $py++, $p->{name} // '', $pal->{title}, $rw);
            $scr->write_str($rx + 2, $py, '$' . $app->format_money($p->{price}), $pal->{price}, 14);
            $scr->write_str($rx + 17, $py++, "Stock: $badge", $badge_st, $rw - 15);
            $py++;

            # ASCII Art
            my $art = $p->{ascii_art} // '';
            my @art_lines = split /\r?\n/, $art;
            my $max_art = $body_h - 9;
            $max_art = 6 if $max_art > 8;
            $max_art = 0 if $max_art < 0;
            for (my $i = 0; $i < @art_lines && $i < $max_art; $i++) {
                $scr->write_str($rx + 2, $py++, $art_lines[$i], $pal->{art}, $rw);
            }
            $py++ if @art_lines;

            # Short description wrapped
            my $desc = $p->{description} // '';
            my @dlines = _wrap_text($desc, $rw);
            for my $dl (@dlines) {
                last if $py >= $body_y + $body_h - 2;
                $scr->write_str($rx + 2, $py++, $dl, $pal->{normal}, $rw);
            }

            if ($body_y + $body_h - 2 > $py - 1) {
                my $hint = ($app->can('has_quick_reorder') && $app->has_quick_reorder())
                    ? "[Enter] Details  [a] +1 Cart  [R] 1-Click Buy"
                    : "[Enter] Details  [a] +1 Cart";
                $scr->write_str($rx + 2, $body_y + $body_h - 2, $hint, $pal->{key}, $rw);
            }
        }
    }
}

sub _wrap_text {
    my ($text, $width) = @_;
    return () if !defined $text || $width < 4;
    my @out;
    my $line = '';
    for my $word (split /\s+/, $text) {
        if (!length($line)) {
            $line = $word;
        } elsif (length($line) + 1 + length($word) <= $width) {
            $line .= ' ' . $word;
        } else {
            push @out, $line;
            $line = $word;
        }
    }
    push @out, $line if length($line);
    return @out;
}

1;
