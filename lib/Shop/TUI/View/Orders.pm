package Shop::TUI::View::Orders;

use strict;
use warnings;
use Shop::TUI::Input ();

sub new {
    my ($class, %args) = @_;
    return bless {
        orders   => [],
        selected => 0,
        scroll   => 0,
        detail   => undef,
        shipment => undef,
    }, $class;
}

sub on_enter {
    my ($self, $app) = @_;
    $self->refresh($app);
}

sub refresh {
    my ($self, $app) = @_;
    return unless $app->{db};
    my $fp = $app->user_fp();
    my $list = eval { $app->{db}->list_orders($fp) };
    $self->{orders} = ref($list) eq 'ARRAY' ? $list : [];
    if (!@{ $self->{orders} }) {
        $self->{selected} = 0;
        $self->{detail}   = undef;
        $self->{shipment} = undef;
        return;
    }
    $self->{selected} = scalar(@{ $self->{orders} }) - 1 if $self->{selected} >= scalar(@{ $self->{orders} });
    $self->_load_detail($app);
}

sub _load_detail {
    my ($self, $app) = @_;
    my $ord = $self->{orders}[$self->{selected}];
    return unless $ord && $app->{db};
    $self->{detail} = eval { $app->{db}->get_order($ord->{id}) } || $ord;
    if ($app->{db}->can('get_shipment_by_order')) {
        my $sh = eval { $app->{db}->get_shipment_by_order($ord->{id}) };
        $self->{shipment} = ref($sh) eq 'HASH' ? $sh : undef;
    } else {
        $self->{shipment} = undef;
    }
}

sub is_capturing_text { 0 }

sub help_text {
    return "[Up/Down/j/k] Select Order | [r] Refresh | [1] Shop | [2] Cart";
}

sub handle_key {
    my ($self, $app, $ev) = @_;
    my $type = $ev->{type} // '';
    my $ch   = $ev->{char} // '';
    my $nav  = Shop::TUI::Input::nav($ev);
    my $n    = scalar(@{ $self->{orders} });

    if ($type eq 'MOUSE' && $ev->{press}) {
        my $btn = $ev->{button} // '';
        if ($btn eq 'wheel_down' && $n > 0 && $self->{selected} < $n - 1) {
            $self->{selected}++;
            $self->_load_detail($app);
            return 1;
        }
        if ($btn eq 'wheel_up' && $n > 0 && $self->{selected} > 0) {
            $self->{selected}--;
            $self->_load_detail($app);
            return 1;
        }
        return 0;
    }
    if ($nav eq 'DOWN' && $n > 0 && $self->{selected} < $n - 1) {
        $self->{selected}++;
        $self->_load_detail($app);
        return 1;
    }
    if ($nav eq 'UP' && $n > 0 && $self->{selected} > 0) {
        $self->{selected}--;
        $self->_load_detail($app);
        return 1;
    }
    if ($type eq 'CHAR' && lc($ch) eq 'r') {
        $self->refresh($app);
        $app->set_toast("Order history refreshed.", 'ok');
        return 1;
    }
    return 0;
}

sub _status_style {
    my ($status, $pal) = @_;
    $status = uc($status // '');
    return $pal->{ok}    if $status eq 'DELIVERED' || $status eq 'PAID';
    return $pal->{title} if $status eq 'IN_TRANSIT' || $status eq 'OUT_FOR_DELIVERY';
    return $pal->{warn}  if $status eq 'PACKING' || $status eq 'PACKED' || $status eq 'PICKED'
                         || $status eq 'LABEL_CREATED' || $status eq 'SHIPPED' || $status eq 'PENDING';
    return $pal->{err}   if $status eq 'CANCELLED';
    return $pal->{normal};
}

sub draw {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    my $ords = $self->{orders};
    my $n    = scalar(@$ords);

    my $left_w  = int($w * 0.48);
    $left_w = $w if $w < 64;
    my $right_w = $w - $left_w - 1;

    $scr->box($x, $y, $left_w, $h, $pal->{border}, "Your Orders ($n)", $pal->{title});
    my $iw = $left_w - 2;
    my $ih = $h - 3;

    if ($n == 0) {
        $scr->write_str($x + 2, $y + 2, "No orders yet. Visit [1] Shop to place an order.", $pal->{dim}, $iw - 2);
    } else {
        $scr->write_str($x + 1, $y + 1, sprintf("%-12s %-10s %10s", "ORDER ID", "STATUS", "TOTAL"), $pal->{dim}, $iw);
        if ($self->{selected} < $self->{scroll}) { $self->{scroll} = $self->{selected}; }
        elsif ($self->{selected} >= $self->{scroll} + $ih) { $self->{scroll} = $self->{selected} - $ih + 1; }

        for (my $r = 0; $r < $ih; $r++) {
            my $idx = $self->{scroll} + $r;
            last if $idx >= $n;
            my $o = $ords->[$idx];
            my $is_sel = ($idx == $self->{selected});
            my $tot_s  = '$' . $app->format_money($o->{total});
            my $line   = sprintf("%-12s %-10s %10s", substr($o->{id} // '', 0, 12), uc($o->{status} // ''), $tot_s);
            if ($is_sel) {
                $line .= ' ' x ($iw - length($line)) if length($line) < $iw;
                $scr->write_str($x + 1, $y + 2 + $r, $line, $pal->{sel}, $iw);
            } else {
                $scr->write_str($x + 1, $y + 2 + $r, sprintf("%-12s ", substr($o->{id} // '', 0, 12)), $pal->{normal}, 13);
                $scr->write_str($x + 14, $y + 2 + $r, sprintf("%-10s ", uc($o->{status} // '')), _status_style($o->{status}, $pal), 11);
                $scr->write_str($x + 25, $y + 2 + $r, sprintf("%10s", $tot_s), $pal->{price}, 10);
            }
        }
    }

    if ($right_w >= 24) {
        my $rx = $x + $left_w + 1;
        $scr->box($rx, $y, $right_w, $h, $pal->{border}, "Order Receipt", $pal->{title});
        my $rw = $right_w - 4;
        my $d  = $self->{detail};
        if ($d) {
            my $py = $y + 2;
            $scr->write_str($rx + 2, $py++, "Order: " . ($d->{id} // ''), $pal->{title}, $rw);
            $scr->write_str($rx + 2, $py++, "Status: " . uc($d->{status} // ''), _status_style($d->{status}, $pal), $rw);
            $scr->write_str($rx + 2, $py++, "Created: " . ($d->{created_at} // ''), $pal->{dim}, $rw);
            $scr->write_str($rx + 2, $py++, "Payment: " . ($d->{payment_method} // '') . " (" . ($d->{payment_ref} // '') . ")", $pal->{dim}, $rw);

            # Shipment & live carrier tracking details
            my $sh = $self->{shipment};
            if (ref($sh) eq 'HASH') {
                my $wh   = $sh->{warehouse_code} // 'DAL1';
                my $car  = $sh->{carrier} // 'USPS';
                my $svc  = $sh->{service} // '';
                my $sst  = uc($sh->{status} // 'PENDING');
                my $trk  = $sh->{tracking_number} // '';
                my $cs   = (length($svc) && $svc =~ /^\Q$car\E\b/i) ? $svc : (length($svc) ? "$car $svc" : $car);
                $scr->write_str($rx + 2, $py++, "Ship   : [$wh] $cs | $sst", _status_style($sst, $pal), $rw) if $py < $y + $h - 5;
                if ($py < $y + $h - 5) {
                    my $trk_line = length($trk) ? "Track #: $trk" : "Track #: (awaiting label)";
                    $scr->write_str($rx + 2, $py++, $trk_line, length($trk) ? $pal->{key} : $pal->{dim}, $rw);
                }
            }

            # Ed25519 Cryptographic Receipt badge + hash/signature
            my $rhash = $d->{receipt_hash} // '';
            my $rsig  = $d->{receipt_sig}  // '';
            if (length($rsig) || length($rhash)) {
                my $badge = '[Ed25519 Signed]';
                my $bst   = $pal->{ok};
                my $pk = ($app->{hostkey} && ref($app->{hostkey}) eq 'HASH') ? $app->{hostkey}{pk} : undef;
                if (defined $pk && length($rsig) && eval { Shop::Domain::Checkout->can('verify_receipt') }) {
                    my $ok = eval { Shop::Domain::Checkout::verify_receipt($d, $pk) };
                    $badge = $ok ? '[Ed25519 Signed & VERIFIED]' : '[Ed25519 INVALID]';
                    $bst   = $ok ? $pal->{ok} : $pal->{err};
                }
                $scr->write_str($rx + 2, $py++, $badge, $bst, $rw);
                if (length($rhash) && $py < $y + $h - 5) {
                    $scr->write_str($rx + 2, $py++, "SHA256: " . substr($rhash, 0, 28) . '...', $pal->{dim}, $rw);
                }
                if (length($rsig) && $py < $y + $h - 5) {
                    $scr->write_str($rx + 2, $py++, "Sig   : " . substr($rsig, 0, 28) . '...', $pal->{dim}, $rw);
                }
            }

            $py++ if $py < $y + $h - 5;
            $scr->write_str($rx + 2, $py++, "Items:", $pal->{key}, $rw) if $py < $y + $h - 4;
            my $items = $d->{items} || [];
            for my $it (@$items) {
                last if $py >= $y + $h - 4;
                my $s = sprintf(" %2dx %-14s \$%s", $it->{qty} // 1, substr($it->{name} // $it->{sku}, 0, 14), $app->format_money($it->{line_total} // $it->{unit_price}));
                $scr->write_str($rx + 2, $py++, $s, $pal->{normal}, $rw);
            }
            $scr->hline($rx + 2, $y + $h - 4, $rw, undef, $pal->{border});
            $scr->write_str($rx + 2, $y + $h - 3, sprintf("Total: \$%s (Tax: \$%s, Ship: \$%s)",
                $app->format_money($d->{total}),
                $app->format_money($d->{tax}),
                $app->format_money($d->{shipping})
            ), $pal->{price}, $rw);
        }
    }
}

1;
