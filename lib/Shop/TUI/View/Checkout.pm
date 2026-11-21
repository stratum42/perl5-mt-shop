package Shop::TUI::View::Checkout;

use strict;
use warnings;
use MT::Decimal ();
use Shop::TUI::Input ();

my @ADDR_FIELDS = (
    { key => 'label',       label => 'Label' },
    { key => 'recipient',   label => 'Recipient' },
    { key => 'line1',       label => 'Street' },
    { key => 'city',        label => 'City' },
    { key => 'state',       label => 'State' },
    { key => 'postal_code', label => 'Postal' },
    { key => 'country',     label => 'Country' },
);

my @BASE_PAY_METHODS = (
    { id => 'mock_visa',     method => 'mock',   token => 'tok_visa',     last4 => '4242', label => 'Mock Card (Visa **** 4242 - Approved)' },
    { id => 'mock_declined', method => 'mock',   token => 'tok_decline',  last4 => '0002', label => 'Mock Card (Declined Test)' },
    { id => 'stripe',        method => 'stripe', token => 'stripe_link',  last4 => '',     label => 'Stripe Checkout Link + Terminal QR (Live Webhook)' },
);

sub new {
    my ($class, %args) = @_;
    return bless {
        step          => 'address', # address | new_addr | payment | awaiting_stripe | receipt
        addresses     => [],
        addr_idx      => 0,
        pay_idx       => 0,
        field_idx     => 0,
        form          => { label => 'Home', recipient => '', line1 => '', city => '', state => '', postal_code => '', country => 'US' },
        receipt       => undef,
        qr_lines      => [],
        pay_methods   => [ @BASE_PAY_METHODS ],
        rates         => [],
        rate_idx      => 0,
        selected_wh   => undef,
        tax_info      => undef,
    }, $class;
}

sub on_enter {
    my ($self, $app) = @_;
    $self->{step}     = 'address';
    $self->{receipt}  = undef;
    $self->{qr_lines} = [];
    $self->_load_addresses($app);
    $self->_build_pay_methods($app);
    $self->_refresh_shipping_and_tax($app);
}

sub show_receipt {
    my ($self, $res) = @_;
    $self->{receipt}  = $res;
    $self->{qr_lines} = [];
    $self->{step}     = 'receipt';
}

sub _build_pay_methods {
    my ($self, $app) = @_;
    my @methods;
    my $saved_pm    = $app->{user}{default_payment_method} // '';
    my $saved_last4 = $app->{user}{default_payment_last4}  // '4242';
    if (length($saved_pm)) {
        push @methods, {
            id     => 'saved_default',
            method => 'mock',
            token  => $saved_pm,
            last4  => $saved_last4,
            label  => "Saved Default Card (**** $saved_last4 - 1-Click)",
        };
    }
    push @methods, @BASE_PAY_METHODS;
    $self->{pay_methods} = \@methods;
    $self->{pay_idx} = 0 if $self->{pay_idx} >= scalar(@methods);
}

sub _load_addresses {
    my ($self, $app) = @_;
    my $fp = $app->user_fp();
    my $addrs = ($app->{db} && defined $fp) ? eval { $app->{db}->list_addresses($fp) } : [];
    $self->{addresses} = ref($addrs) eq 'ARRAY' ? $addrs : [];
    $self->{addr_idx}  = 0 if $self->{addr_idx} >= scalar(@{ $self->{addresses} });
}

sub _refresh_shipping_and_tax {
    my ($self, $app) = @_;
    my $addr = $self->{addresses}[$self->{addr_idx}];
    if (ref($addr) ne 'HASH') {
        $self->{rates}       = [];
        $self->{rate_idx}    = 0;
        $self->{selected_wh} = undef;
        $self->{tax_info}    = undef;
        return;
    }

    my $warehouses = ($app->{db} && $app->{db}->can('list_warehouses'))
        ? (eval { $app->{db}->list_warehouses() } || [])
        : [];
    my $shippo = $app->can('shippo') ? $app->shippo() : $app->{shippo};
    if ($shippo) {
        my $wh = eval { $shippo->pick_warehouse($addr->{postal_code} // '', $warehouses) };
        $self->{selected_wh} = ref($wh) eq 'HASH' ? $wh : undef;
        my $items = ($app->{cart} && $app->{cart}->can('items')) ? ($app->{cart}->items() || []) : [];
        my $res = eval {
            $shippo->get_rates(
                from  => $self->{selected_wh},
                to    => $addr,
                items => $items,
            );
        };
        if (ref($res) eq 'HASH' && ref($res->{rates}) eq 'ARRAY') {
            $self->{rates} = $res->{rates};
            $self->{selected_wh} = $res->{warehouse} if ref($res->{warehouse}) eq 'HASH';
        } elsif (ref($res) eq 'ARRAY') {
            $self->{rates} = $res;
        } else {
            $self->{rates} = [];
        }
        $self->{rate_idx} = 0 if $self->{rate_idx} >= scalar(@{ $self->{rates} });
    } else {
        $self->{rates}       = [];
        $self->{rate_idx}    = 0;
        $self->{selected_wh} = undef;
    }

    my $nexus = $app->can('tax_nexus') ? $app->tax_nexus() : $app->{tax_nexus};
    if ($nexus && $nexus->can('calculate')) {
        my $totals   = $app->{cart} ? ($app->{cart}->totals() || {}) : {};
        my $sub_d    = eval { MT::Decimal->new(($totals->{subtotal} // '0.00') . '') } || MT::Decimal->new('0.00');
        my $disc_d   = eval { MT::Decimal->new(($totals->{discount} // '0.00') . '') } || MT::Decimal->new('0.00');
        my $taxable  = $sub_d - $disc_d;
        $taxable     = MT::Decimal->new('0.00') if $taxable < 0;
        my $ti = eval {
            $nexus->calculate(
                state       => $addr->{state} // '',
                postal_code => $addr->{postal_code} // '',
                subtotal    => $taxable,
            );
        };
        $self->{tax_info} = ref($ti) eq 'HASH' ? $ti : undef;
    } else {
        $self->{tax_info} = undef;
    }
}

sub _selected_rate {
    my ($self) = @_;
    my $rates = $self->{rates} || [];
    return undef unless @$rates;
    my $idx = $self->{rate_idx} // 0;
    $idx = 0 if $idx < 0 || $idx >= @$rates;
    return $rates->[$idx];
}

sub _effective_totals {
    my ($self, $app) = @_;
    my $base = $app->{cart} ? ($app->{cart}->totals() || {}) : {};
    my $sub  = eval { MT::Decimal->new(($base->{subtotal} // '0.00') . '') } || MT::Decimal->new('0.00');
    my $disc = eval { MT::Decimal->new(($base->{discount} // '0.00') . '') } || MT::Decimal->new('0.00');

    my $rate = $self->_selected_rate();
    my $ship_raw = $rate
        ? ($rate->{amount} // $rate->{rate_amount} // $base->{shipping} // '0.00')
        : ($base->{shipping} // '0.00');
    my $ship = eval { MT::Decimal->new("$ship_raw")->quantize(-2, MT::Decimal::ROUND_HALF_UP) } || MT::Decimal->new('0.00');

    my $ti = $self->{tax_info};
    my $tax_raw = (ref($ti) eq 'HASH' && defined($ti->{tax_amount} // $ti->{tax}))
        ? ($ti->{tax_amount} // $ti->{tax})
        : ($base->{tax} // '0.00');
    my $tax = eval { MT::Decimal->new("$tax_raw")->quantize(-2, MT::Decimal::ROUND_HALF_UP) } || MT::Decimal->new('0.00');

    my $tot = ($sub - $disc + $ship + $tax)->quantize(-2, MT::Decimal::ROUND_HALF_UP);
    return {
        subtotal => $sub,
        discount => $disc,
        shipping => $ship,
        tax      => $tax,
        total    => $tot,
    };
}

sub _format_tax_label {
    my ($self, $app, $tax_dec) = @_;
    my $ti = $self->{tax_info};
    if (ref($ti) eq 'HASH') {
        my $st  = uc($ti->{state} // '');
        my $reg = $ti->{registered} // ($ti->{nexus_status} && uc($ti->{nexus_status}) ne 'NO_NEXUS' ? 1 : 0);
        if ($reg) {
            my $pct = defined($ti->{rate_pct})
                ? "$ti->{rate_pct}"
                : do {
                    my $p = sprintf('%.2f', (($ti->{rate} // 0) + 0) * 100.0);
                    $p =~ s/0+$//; $p =~ s/\.$/.0/;
                    $p;
                };
            return sprintf("Tax (%s %s%% - Nexus): \$%s", $st || 'US', $pct, $app->format_money($tax_dec));
        }
        return "Tax (\$0.00 - No Nexus)";
    }
    return "Tax: \$" . $app->format_money($tax_dec);
}

sub is_capturing_text {
    return ($_[0]->{step} // '') eq 'new_addr' ? 1 : 0;
}

sub help_text {
    my ($self, $app) = @_;
    my $s = $self->{step};
    return "NEW ADDRESS: [Tab/Up/Down] Field | [Enter] Save | [Esc] Cancel" if $s eq 'new_addr';
    if ($s eq 'address') {
        my $fast = ($app && $app->can('has_quick_reorder') && $app->has_quick_reorder())
            ? " | [f] 1-Key Express Buy"
            : "";
        return "ADDRESS: [Up/Down] Pick | [n] New$fast | [Enter] Payment | [Esc] Cart";
    }
    return "PAYMENT: [Up/Down] Method | [s/Left/Right] Carrier Rate | [Enter] Place Order | [Esc] Back" if $s eq 'payment';
    return "AWAITING STRIPE WEBHOOK: Waiting for live push... | [o] Orders | [1] Shop" if $s eq 'awaiting_stripe';
    return "RECEIPT: [Enter/o] View Orders | [1] Back to Shop";
}

# Reactive zero-polling EventBus callback when Stripe webhook confirms payment
sub on_payment_confirmed {
    my ($self, $app, $ev) = @_;
    return unless ref($ev) eq 'HASH';
    return unless $self->{step} eq 'awaiting_stripe' || $self->{step} eq 'receipt';

    my $ev_oid  = $ev->{order_id} // $ev->{order_number} // '';
    my $cur_oid = ($self->{receipt} && $self->{receipt}{order}) ? ($self->{receipt}{order}{id} // '') : '';
    return if length($cur_oid) && length($ev_oid) && "$cur_oid" ne "$ev_oid";

    # Refresh full order (including Ed25519 receipt_sig / receipt_hash) from DB if available
    if ($app->{db} && length($cur_oid || $ev_oid)) {
        my $fresh = eval { $app->{db}->get_order($cur_oid || $ev_oid) };
        if (ref($fresh) eq 'HASH' && defined $fresh->{id}) {
            $self->{receipt}{order} = $fresh;
        }
    }
    $self->{receipt}{order}{status} = 'PAID' if $self->{receipt} && $self->{receipt}{order};
    $self->{qr_lines} = [];
    $self->{step}     = 'receipt';
}

sub handle_key {
    my ($self, $app, $ev) = @_;
    my $type = $ev->{type} // '';
    my $ch   = $ev->{char} // '';
    my $nav  = Shop::TUI::Input::nav($ev);

    if ($self->{step} eq 'new_addr') {
        if ($type eq 'ESC') {
            $self->{step} = 'address';
            return 1;
        }
        if ($type eq 'TAB' || $type eq 'DOWN') {
            $self->{field_idx} = ($self->{field_idx} + 1) % scalar(@ADDR_FIELDS);
            return 1;
        }
        if ($type eq 'SHIFT_TAB' || $type eq 'UP') {
            $self->{field_idx} = ($self->{field_idx} - 1 + scalar(@ADDR_FIELDS)) % scalar(@ADDR_FIELDS);
            return 1;
        }
        if ($type eq 'BACKSPACE') {
            my $k = $ADDR_FIELDS[$self->{field_idx}]{key};
            chop($self->{form}{$k}) if length($self->{form}{$k} // '');
            return 1;
        }
        if ($type eq 'CHAR') {
            my $k = $ADDR_FIELDS[$self->{field_idx}]{key};
            $self->{form}{$k} .= $ch if length($self->{form}{$k} // '') < 48;
            return 1;
        }
        if ($type eq 'ENTER') {
            if (!length($self->{form}{line1} // '') || !length($self->{form}{city} // '')) {
                $app->set_toast("Street and City are required.", 'err');
                return 1;
            }
            my $rec = {
                %{ $self->{form} },
                user_fp => $app->user_fp(),
            };
            if ($app->{db}) {
                eval { $app->{db}->save_address($rec) };
                if ($@) {
                    $app->set_toast("Save address failed: $@", 'err');
                    return 1;
                }
            }
            $self->_load_addresses($app);
            $self->{addr_idx} = scalar(@{ $self->{addresses} }) - 1;
            $self->{addr_idx} = 0 if $self->{addr_idx} < 0;
            $self->_refresh_shipping_and_tax($app);
            $self->{step} = 'address';
            $app->set_toast("Address saved.", 'ok');
            return 1;
        }
        return 0;
    }

    if ($self->{step} eq 'address') {
        my $n = scalar(@{ $self->{addresses} });
        if ($nav eq 'DOWN' && $n > 0 && $self->{addr_idx} < $n - 1) {
            $self->{addr_idx}++;
            $self->_refresh_shipping_and_tax($app);
            return 1;
        }
        if ($nav eq 'UP' && $n > 0 && $self->{addr_idx} > 0) {
            $self->{addr_idx}--;
            $self->_refresh_shipping_and_tax($app);
            return 1;
        }
        if ($type eq 'CHAR' && lc($ch) eq 'n') {
            $self->{form} = {
                label       => 'Home',
                recipient   => $app->username(),
                line1       => '',
                city        => '',
                state       => '',
                postal_code => '',
                country     => 'US',
            };
            $self->{field_idx} = 2; # Start at Street
            $self->{step} = 'new_addr';
            return 1;
        }
        # 1-Keystroke Express Checkout using saved card + selected/default address
        if ($type eq 'CHAR' && lc($ch) eq 'f') {
            if ($n > 0 && length($app->{user}{default_payment_method} // '')) {
                $self->{pay_idx} = 0; # saved_default is index 0
                $self->_submit_order($app);
                return 1;
            }
            $app->set_toast("Express checkout requires a saved address and card.", 'warn');
            return 1;
        }
        if ($type eq 'ENTER') {
            if ($n == 0) {
                $app->set_toast("Press [n] to add a shipping address first.", 'warn');
                return 1;
            }
            $self->_refresh_shipping_and_tax($app);
            $self->{step} = 'payment';
            return 1;
        }
        if ($type eq 'ESC') {
            $app->switch_view('cart');
            return 1;
        }
        return 0;
    }

    if ($self->{step} eq 'payment') {
        my $nm = scalar(@{ $self->{pay_methods} });
        my $nr = scalar(@{ $self->{rates} || [] });
        if ($nav eq 'DOWN' && $self->{pay_idx} < $nm - 1) { $self->{pay_idx}++; return 1; }
        if ($nav eq 'UP'   && $self->{pay_idx} > 0)       { $self->{pay_idx}--; return 1; }
        if ($nr > 0 && ($nav eq 'RIGHT' || ($type eq 'CHAR' && lc($ch) eq 's'))) {
            $self->{rate_idx} = ($self->{rate_idx} + 1) % $nr;
            return 1;
        }
        if ($nr > 0 && $nav eq 'LEFT') {
            $self->{rate_idx} = ($self->{rate_idx} - 1 + $nr) % $nr;
            return 1;
        }
        if ($type eq 'ESC') {
            $self->{step} = 'address';
            return 1;
        }
        if ($type eq 'ENTER') {
            $self->_submit_order($app);
            return 1;
        }
        return 0;
    }

    if ($self->{step} eq 'awaiting_stripe') {
        if ($type eq 'CHAR' && lc($ch) eq 'o') {
            $app->switch_view('orders');
            return 1;
        }
        return 0;
    }

    if ($self->{step} eq 'receipt') {
        if ($type eq 'ENTER' || ($type eq 'CHAR' && lc($ch) eq 'o')) {
            $app->switch_view('orders');
            return 1;
        }
        return 0;
    }

    return 0;
}

sub _submit_order {
    my ($self, $app) = @_;
    my $co = $app->{checkout};
    if (!$co) {
        $app->set_toast("Checkout engine not available.", 'err');
        return;
    }
    my $addr = $self->{addresses}[$self->{addr_idx}];
    my $pm   = $self->{pay_methods}[$self->{pay_idx}] || $BASE_PAY_METHODS[0];
    my $rate = $self->_selected_rate();
    my $nexus = $app->can('tax_nexus') ? $app->tax_nexus() : $app->{tax_nexus};

    my $res = eval {
        $co->place_order(
            cart           => $app->{cart},
            user           => $app->{user},
            address        => $addr,
            payment_method => $pm->{method},
            payment_token  => $pm->{token},
            ($rate  ? (shipping_rate => $rate)  : ()),
            ($nexus ? (tax_nexus     => $nexus) : ()),
        );
    };
    if ($@) {
        $app->set_toast("Checkout error: $@", 'err');
        return;
    }
    if (!$res || !$res->{ok}) {
        my $err = ($res && $res->{error}) ? $res->{error} : "Payment failed";
        $app->set_toast("Order failed: $err", 'err');
        return;
    }

    # Save card for 1-keystroke future checkouts if approved mock/card payment
    if ($pm->{method} eq 'mock' && $pm->{last4} && $app->{db} && $app->{db}->can('save_user_payment_method')) {
        my $pm_id = $pm->{token} || 'tok_visa';
        eval { $app->{db}->save_user_payment_method($app->user_fp(), $pm_id, $pm->{last4}) };
        $app->{user}{default_payment_method} = $pm_id;
        $app->{user}{default_payment_last4}  = $pm->{last4};
    }

    $self->{receipt}  = $res;
    $self->{qr_lines} = [];
    if ($res->{payment} && $res->{payment}{qr}) {
        $self->{qr_lines} = [ split /\r?\n/, $res->{payment}{qr} ];
    } elsif ($pm->{method} eq 'stripe' && $res->{payment} && $res->{payment}{checkout_url}) {
        my $qr = eval {
            require Shop::Payment::Stripe;
            Shop::Payment::Stripe->ascii_qr($res->{payment}{checkout_url});
        };
        $self->{qr_lines} = [ split /\r?\n/, $qr ] if defined $qr;
    }

    my $oid    = $res->{order}{id} // 'OK';
    my $status = uc($res->{order}{status} // 'PAID');
    if ($pm->{method} eq 'stripe' && $status eq 'PENDING') {
        $self->{step} = 'awaiting_stripe';
        $app->set_toast("Order #$oid created - awaiting live Stripe webhook push...", 'warn', 8.0);
    } else {
        $self->{step} = 'receipt';
        $app->set_toast("Order #$oid confirmed & Ed25519 signed!", 'ok');
    }
}

sub _verify_order_receipt {
    my ($self, $app, $ord) = @_;
    return (0, 'UNSIGNED') unless ref($ord) eq 'HASH' && length($ord->{receipt_sig} // '');
    my $pk = ($app->{hostkey} && ref($app->{hostkey}) eq 'HASH') ? $app->{hostkey}{pk} : undef;
    if (defined $pk && eval { Shop::Domain::Checkout->can('verify_receipt') }) {
        my $ok = eval { Shop::Domain::Checkout::verify_receipt($ord, $pk) };
        return $ok ? (1, 'VERIFIED') : (0, 'INVALID SIG');
    }
    return (1, 'SIGNED');
}

sub draw {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal    = $app->{palette};
    my $totals = $self->_effective_totals($app);

    $scr->box($x, $y, $w, $h, $pal->{border}, "Checkout (" . uc($self->{step}) . ")", $pal->{title});
    my $iw = $w - 4;
    my $py = $y + 2;

    if ($self->{step} eq 'address') {
        $scr->write_str($x + 2, $py++, "Step 1/2: Select Shipping Address (Total: \$" . $app->format_money($totals->{total}) . ")", $pal->{title}, $iw);
        if (@{ $self->{addresses} } && length($app->{user}{default_payment_method} // '')) {
            my $last4 = $app->{user}{default_payment_last4} // '4242';
            $scr->write_str($x + 2, $py++, " [f] 1-Keystroke Express Checkout with Saved Card **** $last4 ", $pal->{tab_act}, $iw);
        }
        $py++;
        my $addrs = $self->{addresses};
        if (!@$addrs) {
            $scr->write_str($x + 2, $py++, "No saved addresses found.", $pal->{dim}, $iw);
            $scr->write_str($x + 2, $py++, "Press [n] to enter a new shipping address.", $pal->{key}, $iw);
        } else {
            for (my $i = 0; $i < @$addrs && $py < $y + $h - 3; $i++) {
                my $a = $addrs->[$i];
                my $lbl = sprintf("[%s] %s - %s, %s %s %s",
                    $a->{label} // 'Addr',
                    $a->{recipient} // '',
                    $a->{line1} // '',
                    $a->{city} // '',
                    $a->{state} // '',
                    $a->{postal_code} // ''
                );
                my $st = ($i == $self->{addr_idx}) ? $pal->{sel} : $pal->{normal};
                $scr->write_str($x + 2, $py++, $lbl, $st, $iw);
            }
            $py++;
            $scr->write_str($x + 2, $py, "[n] Add New Address    [Enter] Continue to Payment", $pal->{key}, $iw) if $py < $y + $h - 1;
        }
        return;
    }

    if ($self->{step} eq 'new_addr') {
        $scr->write_str($x + 2, $py++, "New Shipping Address:", $pal->{title}, $iw);
        $py++;
        for (my $i = 0; $i < @ADDR_FIELDS && $py < $y + $h - 3; $i++) {
            my $f = $ADDR_FIELDS[$i];
            my $val = $self->{form}{ $f->{key} } // '';
            my $is_cur = ($i == $self->{field_idx});
            $scr->write_str($x + 2, $py, sprintf("%-12s: ", $f->{label}), $pal->{dim}, 14);
            my $disp = $is_cur ? ($val . "_") : $val;
            $scr->write_str($x + 16, $py++, sprintf("%-*s", ($iw > 20 ? $iw - 16 : 16), $disp), $is_cur ? $pal->{input} : $pal->{normal}, $iw - 14);
        }
        $scr->write_str($x + 2, $py + 1, "[Tab] Next Field   [Enter] Save Address   [Esc] Cancel", $pal->{key}, $iw) if $py + 1 < $y + $h - 1;
        return;
    }

    if ($self->{step} eq 'payment') {
        my $addr = $self->{addresses}[$self->{addr_idx}] || {};
        my $rate = $self->_selected_rate();
        my $wh_code = ($self->{selected_wh} && $self->{selected_wh}{code}) ? $self->{selected_wh}{code} : 'DAL1';
        $scr->write_str($x + 2, $py++, "Step 2/2: Shipping, Tax Nexus & Payment", $pal->{title}, $iw);
        $scr->write_str($x + 2, $py++, sprintf("Ship to  : %s, %s, %s %s %s",
            $addr->{recipient} // '', $addr->{line1} // '', $addr->{city} // '', $addr->{state} // '', $addr->{postal_code} // ''), $pal->{dim}, $iw);

        # Live Shippo Carrier Rate Selector
        if ($rate) {
            my $car = $rate->{carrier} // 'USPS';
            my $svc = $rate->{service} // 'Ground';
            my $cs  = (length($svc) && $svc =~ /^\Q$car\E\b/i) ? $svc : (length($svc) ? "$car $svc" : $car);
            my $eta = defined($rate->{eta_days}) ? "$rate->{eta_days}d" : (defined($rate->{estimated_days}) ? "$rate->{estimated_days}d" : '3d');
            my $amt = $app->format_money($rate->{amount} // $rate->{rate_amount} // $totals->{shipping});
            my $nr  = scalar(@{ $self->{rates} || [] });
            my $r_line = sprintf("Shipping : [%s] < %s (\$%s, ETA %s) > (%d/%d) [s]",
                $wh_code, $cs, $amt, $eta, ($self->{rate_idx} // 0) + 1, $nr);
            $scr->write_str($x + 2, $py++, $r_line, $pal->{key}, $iw);
        } else {
            $scr->write_str($x + 2, $py++, "Shipping : \$" . $app->format_money($totals->{shipping}), $pal->{dim}, $iw);
        }

        # Nexus-Aware Tax Line
        my $tax_lbl = $self->_format_tax_label($app, $totals->{tax});
        my $tax_st  = ($self->{tax_info} && !$self->{tax_info}{registered}) ? $pal->{ok} : $pal->{normal};
        $scr->write_str($x + 2, $py++, $tax_lbl, $tax_st, $iw);

        $scr->write_str($x + 2, $py++, "Order Total: \$" . $app->format_money($totals->{total}) . " (exact MT::Decimal)", $pal->{price}, $iw);
        $py++;
        my $methods = $self->{pay_methods};
        for (my $i = 0; $i < @$methods; $i++) {
            last if $py >= $y + $h - 2;
            my $pm = $methods->[$i];
            my $st = ($i == $self->{pay_idx}) ? $pal->{sel} : $pal->{normal};
            $scr->write_str($x + 2, $py++, sprintf(" (%s) %s ", ($i == $self->{pay_idx} ? '*' : ' '), $pm->{label}), $st, $iw);
        }
        $py++ if $py < $y + $h - 2;
        $scr->write_str($x + 2, $py, " [Enter] Confirm & Charge Order ", $pal->{tab_act}, $iw) if $py < $y + $h - 1;
        return;
    }

    if ($self->{step} eq 'awaiting_stripe') {
        my $ord = $self->{receipt}{order}   || {};
        my $pay = $self->{receipt}{payment} || {};
        $scr->write_str($x + 2, $py++, "AWAITING STRIPE PAYMENT (LIVE WEBHOOK PUSH - ZERO POLLING)", $pal->{warn}, $iw);
        $scr->write_str($x + 2, $py++, "Order ID : " . ($ord->{id} // 'N/A') . "   Total: \$" . $app->format_money($ord->{total}), $pal->{title}, $iw);
        if ($pay->{checkout_url}) {
            $scr->write_str($x + 2, $py++, "Pay URL  : " . $pay->{checkout_url}, $pal->{key}, $iw);
        }
        $scr->write_str($x + 2, $py++, "This screen will auto-transition the instant Stripe POSTs /webhooks/stripe.", $pal->{dim}, $iw);
        $py++;
        if (@{ $self->{qr_lines} }) {
            for my $ql (@{ $self->{qr_lines} }) {
                last if $py >= $y + $h - 2;
                $scr->write_str($x + 4, $py++, $ql, $pal->{art}, $iw - 4);
            }
        }
        $scr->write_str($x + 2, $y + $h - 2, "[o] Orders   [1] Continue Shopping (webhook will still notify you)", $pal->{dim}, $iw);
        return;
    }

    if ($self->{step} eq 'receipt') {
        my $ord = $self->{receipt}{order}   || {};
        my $pay = $self->{receipt}{payment} || {};
        my ($sig_ok, $sig_badge) = $self->_verify_order_receipt($app, $ord);

        $scr->write_str($x + 2, $py++, "ORDER CONFIRMED!", $pal->{ok}, $iw);
        $scr->write_str($x + 2, $py++, "Order ID : " . ($ord->{id} // 'N/A') . "   Status: " . uc($ord->{status} // 'PAID'), $pal->{title}, $iw);
        $scr->write_str($x + 2, $py++, "Total    : \$" . $app->format_money($ord->{total}) . " (exact MT::Decimal)", $pal->{price}, $iw);
        $scr->write_str($x + 2, $py++, "Pay Ref  : " . ($pay->{ref} // $pay->{id} // $ord->{payment_ref} // 'mock'), $pal->{dim}, $iw);
        my $sh = $self->{receipt}{shipment};
        if (ref($sh) eq 'HASH') {
            $scr->write_str($x + 2, $py++, sprintf("Shipment : [%s] %s %s (%s)",
                $sh->{warehouse_code} // 'DAL1',
                $sh->{carrier} // 'USPS',
                $sh->{service} // '',
                uc($sh->{status} // 'PENDING')), $pal->{key}, $iw);
        }
        $py++;

        # Ed25519 Cryptographic Receipt Box
        $scr->write_str($x + 2, $py, "Ed25519 Cryptographic Receipt: ", $pal->{title}, 32);
        $scr->write_str($x + 33, $py++, "[$sig_badge]", $sig_ok ? $pal->{ok} : $pal->{warn}, $iw - 31);
        my $rhash = $ord->{receipt_hash} // '';
        my $rsig  = $ord->{receipt_sig}  // '';
        if (length($rhash)) {
            $scr->write_str($x + 2, $py++, "  SHA-256 : " . substr($rhash, 0, 48) . (length($rhash) > 48 ? '...' : ''), $pal->{dim}, $iw);
        }
        if (length($rsig)) {
            $scr->write_str($x + 2, $py++, "  Ed25519 : " . substr($rsig, 0, 44) . (length($rsig) > 44 ? '...' : ''), $pal->{ok}, $iw);
        }
        if ($pay->{checkout_url} && !length($rsig)) {
            $scr->write_str($x + 2, $py++, "Pay URL  : " . $pay->{checkout_url}, $pal->{key}, $iw);
        }

        $scr->write_str($x + 2, $y + $h - 2, "[Enter/o] View Order History   [1] Continue Shopping", $pal->{key}, $iw);
    }
}

1;
