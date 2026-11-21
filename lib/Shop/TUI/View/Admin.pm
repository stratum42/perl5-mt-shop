package Shop::TUI::View::Admin;

use strict;
use warnings;
use MT::Decimal ();
use Shop::TUI::Input ();

my @SUBTABS = ('Dashboard', 'Inventory', 'Orders', '[T] Db2 Time-Travel & OLAP', '[L] Logistics & Nexus', 'Broadcast');
my $TAB_DASH      = 0;
my $TAB_INVENTORY = 1;
my $TAB_ORDERS    = 2;
my $TAB_DB2       = 3;
my $TAB_LOGISTICS = 4;
my $TAB_BROADCAST = 5;

my %NEXT_STATUS = (
    PENDING  => 'PAID',
    PAID     => 'PACKING',
    PACKING  => 'SHIPPED',
    SHIPPED  => 'DELIVERED',
);

my %NEXT_SHIP_STATUS = (
    PENDING => 'PICKED',
    PICKED  => 'PACKED',
);

sub new {
    my ($class, %args) = @_;
    return bless {
        tab           => 0,
        inv_sel       => 0,
        ord_sel       => 0,
        db2_sku_sel   => 0,
        db2_ord_sel   => 0,
        products      => [],
        orders        => [],
        edit_mode     => '',    # '' | 'stock' | 'price' | 'broadcast' | 'po_scan'
        edit_buf      => '',
        gmv           => {},
        sub_metrics   => {},
        db2_features  => {},
        prod_history  => [],
        ord_history   => [],
        olap_rows     => [],
        log_pane      => 'po',  # 'po' | 'ship'
        po_sel        => 0,
        ship_sel      => 0,
        po_lines      => [],
        shipments     => [],
        nexus_rows    => [],
        _tab_hitboxes => [],
    }, $class;
}

sub on_enter {
    my ($self, $app) = @_;
    $self->{edit_mode} = '';
    $self->refresh($app);
}

sub _refresh_db2 {
    my ($self, $app) = @_;
    my $db = $app->{db};
    if (!$db) {
        $self->{db2_features} = {};
        $self->{prod_history} = [];
        $self->{ord_history}  = [];
        $self->{olap_rows}    = [];
        return;
    }

    if ($db->can('db2_features')) {
        my $feat = eval { $db->db2_features() };
        $self->{db2_features} = ref($feat) eq 'HASH' ? $feat : {};
    } else {
        $self->{db2_features} = { engine => $db->driver() };
    }

    my $nprod = scalar(@{ $self->{products} });
    if ($nprod > 0) {
        $self->{db2_sku_sel} = 0 if $self->{db2_sku_sel} >= $nprod || $self->{db2_sku_sel} < 0;
        my $sku = $self->{products}[$self->{db2_sku_sel}]{sku};
        if (defined $sku && $db->can('product_history')) {
            my $ph = eval { $db->product_history($sku, 8) };
            $self->{prod_history} = ref($ph) eq 'ARRAY' ? $ph : [];
        } else {
            $self->{prod_history} = [];
        }
    } else {
        $self->{db2_sku_sel}  = 0;
        $self->{prod_history} = [];
    }

    my $nord = scalar(@{ $self->{orders} });
    if ($nord > 0) {
        $self->{db2_ord_sel} = 0 if $self->{db2_ord_sel} >= $nord || $self->{db2_ord_sel} < 0;
        my $oid = $self->{orders}[$self->{db2_ord_sel}]{id};
        if (defined $oid && $db->can('order_history')) {
            my $oh = eval { $db->order_history($oid) };
            $self->{ord_history} = ref($oh) eq 'ARRAY' ? $oh : [];
        } else {
            $self->{ord_history} = [];
        }
    } else {
        $self->{db2_ord_sel} = 0;
        $self->{ord_history} = [];
    }

    if ($db->can('category_olap')) {
        my $olap = eval { $db->category_olap() };
        $self->{olap_rows} = ref($olap) eq 'ARRAY' ? $olap : [];
    } else {
        $self->{olap_rows} = [];
    }
}

sub refresh {
    my ($self, $app) = @_;
    if ($app->{inventory}) {
        $self->{products} = $app->{inventory}->list_catalog() || [];
    }
    if ($app->{db}) {
        my $ords = eval { $app->{db}->list_orders(undef) };
        $self->{orders} = ref($ords) eq 'ARRAY' ? $ords : [];
        my $gmv = eval { $app->{db}->gmv_summary() };
        $self->{gmv} = ref($gmv) eq 'HASH' ? $gmv : {};
        if ($app->{db}->can('subscription_metrics')) {
            my $sm = eval { $app->{db}->subscription_metrics() };
            $self->{sub_metrics} = ref($sm) eq 'HASH' ? $sm : {};
        } else {
            $self->{sub_metrics} = {};
        }
    }
    $self->_refresh_db2($app);
    $self->_refresh_logistics($app);
}

sub _refresh_logistics {
    my ($self, $app) = @_;
    my $db = $app->{db};

    # 1. Inbound PO Queue (flatten POs + lines)
    my @flat_pos;
    if ($db && $db->can('list_pos')) {
        my $pos = eval { $db->list_pos() };
        if (ref($pos) eq 'ARRAY') {
            for my $po (@$pos) {
                my $lines = $db->can('get_po_lines') ? (eval { $db->get_po_lines($po->{id}) } || []) : [];
                if (ref($lines) eq 'ARRAY' && @$lines) {
                    for my $ln (@$lines) {
                        push @flat_pos, {
                            po_id          => $po->{id},
                            supplier       => $po->{supplier}       // '',
                            warehouse_code => $po->{warehouse_code} // 'DAL1',
                            po_status      => uc($po->{status}      // 'OPEN'),
                            line_id        => $ln->{id},
                            sku            => $ln->{sku}            // '',
                            qty_ordered    => int($ln->{qty_ordered}  // 0),
                            qty_received   => int($ln->{qty_received} // 0),
                            unit_cost      => $ln->{unit_cost}      // '0.00',
                        };
                    }
                } else {
                    push @flat_pos, {
                        po_id          => $po->{id},
                        supplier       => $po->{supplier}       // '',
                        warehouse_code => $po->{warehouse_code} // 'DAL1',
                        po_status      => uc($po->{status}      // 'OPEN'),
                        line_id        => undef,
                        sku            => '-',
                        qty_ordered    => 0,
                        qty_received   => 0,
                        unit_cost      => '0.00',
                    };
                }
            }
        }
    }
    $self->{po_lines} = \@flat_pos;
    $self->{po_sel}   = 0 if !@flat_pos || $self->{po_sel} >= @flat_pos || $self->{po_sel} < 0;

    # 2. Outbound Shipments
    if ($db && $db->can('list_shipments')) {
        my $sh = eval { $db->list_shipments() };
        $self->{shipments} = ref($sh) eq 'ARRAY' ? $sh : [];
    } else {
        $self->{shipments} = [];
    }
    my $nsh = scalar(@{ $self->{shipments} });
    $self->{ship_sel} = 0 if !$nsh || $self->{ship_sel} >= $nsh || $self->{ship_sel} < 0;

    # 3. Tax Nexus Monitor
    my $nexus = $app->can('tax_nexus') ? $app->tax_nexus() : $app->{tax_nexus};
    my $nrows;
    if ($nexus && $nexus->can('nexus_alerts')) {
        $nrows = eval { $nexus->nexus_alerts() };
    }
    if (ref($nrows) ne 'ARRAY' && $db && $db->can('tax_nexus_report')) {
        my $rep = eval { $db->tax_nexus_report() };
        if (ref($rep) eq 'ARRAY') {
            $nrows = [ map {
                my $r = $_;
                my $reg = $r->{registered} ? 1 : 0;
                my $ytd = ($r->{ytd_sales} // 0) + 0;
                my $thr = ($r->{threshold_sales} // 0) + 0;
                my $tx  = int($r->{ytd_txns} // 0);
                my $tht = int($r->{threshold_txns} // 0);
                my $pct = $thr > 0 ? ($ytd / $thr) : 0;
                my $tpct = $tht > 0 ? ($tx / $tht) : 0;
                my $maxp = $pct > $tpct ? $pct : $tpct;
                my $st = $reg           ? 'REGISTERED'
                       : $maxp >= 1.0   ? 'NEXUS_REQUIRED'
                       : $maxp >= 0.8   ? 'APPROACHING'
                       :                  'OK';
                { %$r, status => $st, alert_status => $st };
            } @$rep ];
        }
    }
    $self->{nexus_rows} = ref($nrows) eq 'ARRAY' ? $nrows : [];
}

sub _receive_po_line {
    my ($self, $app, $line, $qty) = @_;
    $qty ||= 10;
    if (!ref($line) || !defined $line->{line_id}) {
        $app->set_toast("No receivable PO line selected.", 'warn');
        return;
    }
    my $res;
    if ($app->{checkout} && $app->{checkout}->can('receive_po_line')) {
        $res = eval { $app->{checkout}->receive_po_line(po_line_id => $line->{line_id}, qty => $qty) };
    } elsif ($app->{db} && $app->{db}->can('receive_po_line')) {
        $res = eval { $app->{db}->receive_po_line($line->{line_id}, $qty) };
        if (ref($res) eq 'HASH' && $res->{ok}) {
            my $sku = $res->{sku} // $line->{sku};
            my $ns  = $res->{new_stock};
            $app->{inventory}->set_stock($sku, $ns) if $app->{inventory} && defined $ns;
            if ($app->{event_bus}) {
                $app->{event_bus}->broadcast({
                    type   => 'stock_update',
                    sku    => $sku,
                    stock  => $ns,
                    reason => 'po_received',
                });
            }
        }
    }
    if ($@) {
        $app->set_toast("PO receive error: $@", 'err');
        return;
    }
    if (ref($res) eq 'HASH' && $res->{ok}) {
        my $sku = $res->{sku} // $line->{sku};
        my $ns  = $res->{new_stock} // '?';
        my $pst = $res->{po_status} // 'PARTIAL';
        $self->refresh($app);
        $app->set_toast("[RESTOCKED] +${qty}x $sku (stock: $ns, PO: $pst)", 'ok');
    } else {
        my $err = (ref($res) eq 'HASH' && $res->{error}) ? $res->{error} : "PO receive failed";
        $app->set_toast($err, 'err');
    }
}

sub _buy_shipment_label {
    my ($self, $app, $sh) = @_;
    if (ref($sh) ne 'HASH' || !defined $sh->{id}) {
        $app->set_toast("No shipment selected.", 'warn');
        return;
    }
    my $shippo = $app->can('shippo') ? $app->shippo() : $app->{shippo};
    if (!$shippo || !$shippo->can('buy_label')) {
        $app->set_toast("Shippo service unavailable.", 'err');
        return;
    }
    my $lbl = eval {
        $shippo->buy_label(
            rate => {
                carrier => $sh->{carrier}     // 'USPS',
                service => $sh->{service}     // 'Ground Advantage',
                amount  => $sh->{rate_amount} // '7.95',
            },
            order_id => $sh->{order_id},
            from     => { code => $sh->{warehouse_code} // 'DAL1' },
            to       => {},
        );
    };
    if ($@ || ref($lbl) ne 'HASH' || !$lbl->{ok}) {
        my $err = $@ || (ref($lbl) eq 'HASH' && $lbl->{error}) || "Shippo buy_label failed";
        $app->set_toast("Label error: $err", 'err');
        return;
    }
    my $trk = $lbl->{tracking_number} // '';
    my $url = $lbl->{label_url}       // '';
    if ($app->{db} && $app->{db}->can('update_shipment')) {
        eval {
            $app->{db}->update_shipment(
                $sh->{id},
                status          => 'LABEL_CREATED',
                tracking_number => $trk,
                label_url       => $url,
            );
        };
    }
    $self->refresh($app);
    $app->set_toast("Label bought for #$sh->{order_id}: $trk (LABEL_CREATED)", 'ok');
}

sub is_capturing_text {
    return length($_[0]->{edit_mode} // '') ? 1 : 0;
}

sub help_text {
    my ($self) = @_;
    return "INPUT ($self->{edit_mode}): Type value | [Enter] Commit | [Esc] Cancel" if length($self->{edit_mode});
    if ($self->{tab} == $TAB_DB2) {
        return "[Tab/Click] Subtab | [n/p/Arrows] Cycle SKU | [o] Cycle Order | [r] Refresh";
    }
    if ($self->{tab} == $TAB_LOGISTICS) {
        return "[Tab/Click] Subtab | [Up/Down] Select | [w/Arrows] Pane | [r] Recv 10 | [/] Scan SKU | [p] Pick/Pack | [b] Buy Label | [R] Refresh";
    }
    return "[Tab/Click] Subtab | [T] Db2 OLAP | [L] Logistics | [r] Refresh | [+/-] Stock | [s] Stock | [p] Price | [a] Advance | [b] Broadcast";
}

sub handle_key {
    my ($self, $app, $ev) = @_;
    return 0 unless $app->is_admin();

    my $type = $ev->{type} // '';
    my $ch   = $ev->{char} // '';
    my $nav  = Shop::TUI::Input::nav($ev);

    if (length($self->{edit_mode})) {
        if ($type eq 'ESC') {
            $self->{edit_mode} = '';
            $self->{edit_buf}  = '';
            return 1;
        }
        if ($type eq 'BACKSPACE') {
            chop($self->{edit_buf}) if length($self->{edit_buf});
            return 1;
        }
        if ($type eq 'CHAR') {
            $self->{edit_buf} .= $ch if length($self->{edit_buf}) < 80;
            return 1;
        }
        if ($type eq 'ENTER') {
            my $mode = $self->{edit_mode};
            my $val  = $self->{edit_buf};
            $self->{edit_mode} = '';
            $self->{edit_buf}  = '';

            if ($mode eq 'stock' && @{ $self->{products} }) {
                my $p = $self->{products}[$self->{inv_sel}];
                if ($val =~ /^\d+$/) {
                    my $qty = int($val);
                    $app->{inventory}->set_stock($p->{sku}, $qty) if $app->{inventory};
                    eval { $app->{db}->update_product_stock($p->{sku}, $qty) } if $app->{db};
                    $app->broadcast_stock($p->{sku});
                    $app->set_toast("Stock for $p->{sku} set to $qty.", 'ok');
                } else {
                    $app->set_toast("Invalid stock integer: $val", 'err');
                }
            } elsif ($mode eq 'price' && @{ $self->{products} }) {
                my $p = $self->{products}[$self->{inv_sel}];
                if ($val =~ /^\d+(?:\.\d{1,2})?$/) {
                    my %updated = (%$p, price => $val);
                    $app->{inventory}->upsert_product(\%updated) if $app->{inventory};
                    eval { $app->{db}->upsert_product(\%updated) } if $app->{db};
                    $self->refresh($app);
                    $app->set_toast("Price for $p->{sku} updated to \$$val.", 'ok');
                } else {
                    $app->set_toast("Invalid decimal price: $val", 'err');
                }
            } elsif ($mode eq 'broadcast' && length($val)) {
                if ($app->{event_bus}) {
                    $app->{event_bus}->broadcast({
                        type    => 'broadcast',
                        message => $val,
                        from    => $app->username(),
                    });
                }
                $app->set_toast("Broadcast sent to all sessions!", 'ok');
            } elsif ($mode eq 'po_scan' && length($val)) {
                my $want = uc($val);
                $want =~ s/^\s+|\s+$//g;
                my ($match) = grep { uc($_->{sku} // '') eq $want && ($_->{qty_received} // 0) < ($_->{qty_ordered} // 0) } @{ $self->{po_lines} };
                ($match) = grep { uc($_->{sku} // '') eq $want } @{ $self->{po_lines} } unless $match;
                if ($match) {
                    $self->_receive_po_line($app, $match, 10);
                } else {
                    $app->set_toast("No open PO line found for SKU '$want'.", 'warn');
                }
            }
            return 1;
        }
        return 0;
    }

    # SGR Mouse support: click any sub-tab, or scroll wheel on lists / Db2 SKU cycle
    if ($type eq 'MOUSE' && $ev->{press}) {
        my $btn = $ev->{button} // '';
        if ($btn eq 'left') {
            my ($mx, $my) = ($ev->{x} // -1, $ev->{y} // -1);
            for my $hb (@{ $self->{_tab_hitboxes} || [] }) {
                if ($my == $hb->{y} && $mx >= $hb->{x0} && $mx < $hb->{x1}) {
                    $self->{tab} = $hb->{idx};
                    $self->refresh($app);
                    return 1;
                }
            }
        }
        if ($self->{tab} == $TAB_DB2) {
            my $n = scalar(@{ $self->{products} });
            if ($btn eq 'wheel_down' && $n > 0) {
                $self->{db2_sku_sel} = ($self->{db2_sku_sel} + 1) % $n;
                $self->_refresh_db2($app);
                return 1;
            }
            if ($btn eq 'wheel_up' && $n > 0) {
                $self->{db2_sku_sel} = ($self->{db2_sku_sel} - 1 + $n) % $n;
                $self->_refresh_db2($app);
                return 1;
            }
        }
    }

    if ($type eq 'TAB') {
        $self->{tab} = ($self->{tab} + 1) % scalar(@SUBTABS);
        $self->refresh($app);
        return 1;
    }
    if ($type eq 'SHIFT_TAB') {
        $self->{tab} = ($self->{tab} - 1 + scalar(@SUBTABS)) % scalar(@SUBTABS);
        $self->refresh($app);
        return 1;
    }
    if ($type eq 'CHAR' && lc($ch) eq 't') {
        $self->{tab} = $TAB_DB2;
        $self->refresh($app);
        return 1;
    }
    if ($type eq 'CHAR' && lc($ch) eq 'l') {
        $self->{tab} = $TAB_LOGISTICS;
        $self->refresh($app);
        return 1;
    }
    if ($type eq 'CHAR' && (($self->{tab} != $TAB_LOGISTICS && lc($ch) eq 'r') || ($self->{tab} == $TAB_LOGISTICS && $ch eq 'R'))) {
        $self->refresh($app);
        $app->set_toast("Admin metrics refreshed.", 'ok');
        return 1;
    }

    # Subtab 1: Inventory editor
    if ($self->{tab} == $TAB_INVENTORY) {
        my $n = scalar(@{ $self->{products} });
        if ($nav eq 'DOWN' && $n > 0 && $self->{inv_sel} < $n - 1) { $self->{inv_sel}++; return 1; }
        if ($nav eq 'UP'   && $n > 0 && $self->{inv_sel} > 0)      { $self->{inv_sel}--; return 1; }
        if ($n > 0 && $type eq 'CHAR') {
            my $p = $self->{products}[$self->{inv_sel}];
            if ($ch eq '+' || $ch eq '=') {
                my $cur = $app->{inventory}->get_stock($p->{sku});
                $app->{inventory}->set_stock($p->{sku}, $cur + 1);
                eval { $app->{db}->update_product_stock($p->{sku}, $cur + 1) } if $app->{db};
                $app->broadcast_stock($p->{sku});
                return 1;
            }
            if ($ch eq '-') {
                my $cur = $app->{inventory}->get_stock($p->{sku});
                my $nq  = $cur > 0 ? $cur - 1 : 0;
                $app->{inventory}->set_stock($p->{sku}, $nq);
                eval { $app->{db}->update_product_stock($p->{sku}, $nq) } if $app->{db};
                $app->broadcast_stock($p->{sku});
                return 1;
            }
            if (lc($ch) eq 's') {
                $self->{edit_mode} = 'stock';
                $self->{edit_buf}  = '' . $app->{inventory}->get_stock($p->{sku});
                return 1;
            }
            if (lc($ch) eq 'p') {
                $self->{edit_mode} = 'price';
                $self->{edit_buf}  = $app->format_money($p->{price});
                return 1;
            }
        }
    }

    # Subtab 2: Order queue
    if ($self->{tab} == $TAB_ORDERS) {
        my $n = scalar(@{ $self->{orders} });
        if ($nav eq 'DOWN' && $n > 0 && $self->{ord_sel} < $n - 1) { $self->{ord_sel}++; return 1; }
        if ($nav eq 'UP'   && $n > 0 && $self->{ord_sel} > 0)      { $self->{ord_sel}--; return 1; }
        if ($n > 0 && ($type eq 'ENTER' || ($type eq 'CHAR' && lc($ch) eq 'a'))) {
            my $o = $self->{orders}[$self->{ord_sel}];
            my $next = $NEXT_STATUS{ uc($o->{status} // '') };
            if ($next && $app->{db}) {
                eval { $app->{db}->update_order_status($o->{id}, $next) };
                $app->{event_bus}->broadcast({
                    type     => 'order_status',
                    order_id => $o->{id},
                    status   => $next,
                }) if $app->{event_bus};
                $self->refresh($app);
                $app->set_toast("Order #$o->{id} advanced to $next.", 'ok');
            }
            return 1;
        }
        if ($n > 0 && $type eq 'CHAR' && lc($ch) eq 'x') {
            my $o = $self->{orders}[$self->{ord_sel}];
            if ($app->{db}) {
                eval { $app->{db}->update_order_status($o->{id}, 'CANCELLED') };
                $self->refresh($app);
                $app->set_toast("Order #$o->{id} cancelled.", 'warn');
            }
            return 1;
        }
    }

    # Subtab 3: Db2 Time-Travel & OLAP
    if ($self->{tab} == $TAB_DB2) {
        my $nprod = scalar(@{ $self->{products} });
        if ($nprod > 0) {
            if ($nav eq 'DOWN' || $nav eq 'RIGHT' || ($type eq 'CHAR' && lc($ch) eq 'n')) {
                $self->{db2_sku_sel} = ($self->{db2_sku_sel} + 1) % $nprod;
                $self->_refresh_db2($app);
                return 1;
            }
            if ($nav eq 'UP' || $nav eq 'LEFT' || ($type eq 'CHAR' && lc($ch) eq 'p')) {
                $self->{db2_sku_sel} = ($self->{db2_sku_sel} - 1 + $nprod) % $nprod;
                $self->_refresh_db2($app);
                return 1;
            }
        }
        my $nord = scalar(@{ $self->{orders} });
        if ($nord > 0 && $type eq 'CHAR' && lc($ch) eq 'o') {
            $self->{db2_ord_sel} = ($self->{db2_ord_sel} + 1) % $nord;
            $self->_refresh_db2($app);
            return 1;
        }
    }

    # Subtab 4: Logistics & Nexus
    if ($self->{tab} == $TAB_LOGISTICS) {
        if ($nav eq 'LEFT' || $nav eq 'RIGHT' || ($type eq 'CHAR' && lc($ch) eq 'w')) {
            $self->{log_pane} = ($self->{log_pane} eq 'po') ? 'ship' : 'po';
            return 1;
        }
        if ($self->{log_pane} eq 'po') {
            my $npo = scalar(@{ $self->{po_lines} });
            if ($nav eq 'DOWN' && $npo > 0 && $self->{po_sel} < $npo - 1) { $self->{po_sel}++; return 1; }
            if ($nav eq 'UP'   && $npo > 0 && $self->{po_sel} > 0)        { $self->{po_sel}--; return 1; }
        } else {
            my $nsh = scalar(@{ $self->{shipments} });
            if ($nav eq 'DOWN' && $nsh > 0 && $self->{ship_sel} < $nsh - 1) { $self->{ship_sel}++; return 1; }
            if ($nav eq 'UP'   && $nsh > 0 && $self->{ship_sel} > 0)        { $self->{ship_sel}--; return 1; }
        }
        if ($type eq 'CHAR' && $ch eq 'r') {
            my $ln = $self->{po_lines}[$self->{po_sel}];
            $self->_receive_po_line($app, $ln, 10);
            return 1;
        }
        if ($type eq 'CHAR' && ($ch eq '/' || lc($ch) eq 's')) {
            $self->{edit_mode} = 'po_scan';
            $self->{edit_buf}  = '';
            return 1;
        }
        if ($type eq 'CHAR' && lc($ch) eq 'p') {
            my $sh = $self->{shipments}[$self->{ship_sel}];
            if (ref($sh) eq 'HASH') {
                my $next = $NEXT_SHIP_STATUS{ uc($sh->{status} // '') };
                if ($next && $app->{db} && $app->{db}->can('update_shipment')) {
                    eval { $app->{db}->update_shipment($sh->{id}, status => $next) };
                    $self->refresh($app);
                    $app->set_toast("Shipment #$sh->{order_id} advanced to $next.", 'ok');
                } else {
                    $app->set_toast("Shipment #$sh->{order_id} cannot advance from " . uc($sh->{status} // '?') . " (use [b] for label).", 'warn');
                }
            }
            return 1;
        }
        if ($type eq 'CHAR' && lc($ch) eq 'b') {
            my $sh = $self->{shipments}[$self->{ship_sel}];
            $self->_buy_shipment_label($app, $sh);
            return 1;
        }
    }

    # Subtab 5: Broadcast
    if ($self->{tab} == $TAB_BROADCAST && ($type eq 'ENTER' || ($type eq 'CHAR' && lc($ch) eq 'b'))) {
        $self->{edit_mode} = 'broadcast';
        $self->{edit_buf}  = '';
        return 1;
    }

    return 0;
}

sub draw {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};

    if (!$app->is_admin()) {
        $scr->box($x, $y, $w, $h, $pal->{err}, "Admin Console - Access Denied", $pal->{err});
        $scr->write_str($x + 2, $y + 2, "Your SSH key is not authorized for Merchant/Admin access.", $pal->{err}, $w - 4);
        $scr->write_str($x + 2, $y + 4, "Your fingerprint: " . $app->user_fp(), $pal->{dim}, $w - 4);
        $scr->write_str($x + 2, $y + 5, "Add it to config/shop.json -> admin_fingerprints to grant access.", $pal->{dim}, $w - 4);
        return;
    }

    # Subtab strip (with SGR mouse hitboxes)
    my $tx = $x;
    my @hitboxes;
    for (my $i = 0; $i < @SUBTABS; $i++) {
        my $title = $SUBTABS[$i];
        if ($w < 100) {
            $title = '[T] Db2 OLAP'   if $i == $TAB_DB2;
            $title = '[L] Logistics'  if $i == $TAB_LOGISTICS;
        }
        my $lbl   = " " . $title . " ";
        my $lw    = length($lbl);
        last if $tx >= $x + $w;
        my $avail = ($x + $w) - $tx;
        $scr->write_str($tx, $y, $lbl, ($i == $self->{tab}) ? $pal->{tab_act} : $pal->{dim}, $avail);
        my $end_x = $tx + ($lw < $avail ? $lw : $avail);
        push @hitboxes, { idx => $i, y => $y, x0 => $tx, x1 => $end_x };
        $tx += $lw + 1;
    }
    $self->{_tab_hitboxes} = \@hitboxes;

    my $by = $y + 1;
    my $bh = $h - 1;
    $scr->box($x, $by, $w, $bh, $pal->{border}, "Merchant / Admin - $SUBTABS[$self->{tab}]", $pal->{title});
    my $iw = $w - 4;
    my $py = $by + 2;

    if ($self->{tab} == $TAB_DASH) {
        $self->_draw_dashboard($app, $scr, $x + 2, $py, $iw, $bh - 3);
    } elsif ($self->{tab} == $TAB_INVENTORY) {
        $self->_draw_inventory($app, $scr, $x + 2, $py, $iw, $bh - 3);
    } elsif ($self->{tab} == $TAB_ORDERS) {
        $self->_draw_orders($app, $scr, $x + 2, $py, $iw, $bh - 3);
    } elsif ($self->{tab} == $TAB_DB2) {
        $self->_draw_db2_olap($app, $scr, $x + 2, $py, $iw, $bh - 3);
    } elsif ($self->{tab} == $TAB_LOGISTICS) {
        $self->_draw_logistics($app, $scr, $x + 2, $py, $iw, $bh - 3);
    } elsif ($self->{tab} == $TAB_BROADCAST) {
        $self->_draw_broadcast($app, $scr, $x + 2, $py, $iw, $bh - 3);
    }
}

sub _draw_dashboard {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    my $py  = $y;

    my $sessions = $app->{event_bus} ? ($app->{event_bus}->list_sessions() || []) : [];
    my $fstats   = eval { MT::Fiber::stats() }       || {};
    my $sstats   = eval { MT::Fiber::sched_stats() } || {};
    my $sup      = eval { require MT::Supervisor; MT::Supervisor::status() } || [];
    my $faults   = eval { require MT::Fault; MT::Fault::count() } // 0;
    my $gm       = ($app->{metrics} && $app->{metrics}->can('snapshot'))
        ? (eval { $app->{metrics}->snapshot() } || {})
        : {};

    my $alive_units   = grep { ($_->{state} // '') ne 'faulted' } @$sup;
    my $faulted_units = grep { ($_->{state} // '') eq 'faulted' } @$sup;

    my $gmv_tot = $app->format_money($self->{gmv}{total_gmv} // $self->{gmv}{gmv} // '0.00');
    my $gmv_cnt = $self->{gmv}{order_count} // $self->{gmv}{orders} // ($gm->{orders_total} // 0);

    my $subm      = $self->{sub_metrics} || {};
    my $act_mem   = int($subm->{active_members}       // 0);
    my $act_subs  = int($subm->{active_subscriptions} // 0);
    my $mem_mrr_d = eval { MT::Decimal->new($subm->{membership_mrr}   // '0.00') } || MT::Decimal->new('0.00');
    my $sub_mrr_d = eval { MT::Decimal->new($subm->{subscription_mrr} // '0.00') } || MT::Decimal->new('0.00');
    my $tot_mrr_d = eval { $mem_mrr_d + $sub_mrr_d } || MT::Decimal->new('0.00');
    my $mem_mrr   = $app->format_money($mem_mrr_d);
    my $sub_mrr   = $app->format_money($sub_mrr_d);
    my $tot_mrr   = $app->format_money($tot_mrr_d);

    my $pq_cnt   = $gm->{ssh_kex_pq_total}      // 0;
    my $cls_cnt  = $gm->{ssh_kex_classic_total} // 0;
    my $kex_tot  = $pq_cnt + $cls_cnt;
    my $pq_ratio = $kex_tot > 0 ? sprintf('%.0f%%', 100.0 * $pq_cnt / $kex_tot) : 'N/A';
    my $blocked  = $gm->{ssh_auth_blocked_total} // 0;

    my $cas_ok   = $gm->{inventory_cas_ok_total}       // 0;
    my $cas_conf = $gm->{inventory_cas_conflict_total} // 0;
    my $webhooks = $gm->{webhooks_processed_total}     // 0;

    $scr->write_str($x, $py++, sprintf("Active SSH Sessions : %d (total=%d)  | Orders: %d | GMV: \$%s (MT::Decimal)",
        scalar(@$sessions), $gm->{ssh_connections_total} // scalar(@$sessions), $gmv_cnt, $gmv_tot), $pal->{title}, $w);
    $scr->write_str($x, $py++, sprintf("Memberships & Subs  : %d members | %d active subs | MRR: \$%s (Mem \$%s + Sub \$%s)",
        $act_mem, $act_subs, $tot_mrr, $mem_mrr, $sub_mrr), $pal->{price}, $w);
    $scr->write_str($x, $py++, sprintf("Post-Quantum KEX    : PQ=%d Classic=%d (PQ Ratio: %s) | Auth Blocked: %d",
        $pq_cnt, $cls_cnt, $pq_ratio, $blocked), $pq_cnt > 0 ? $pal->{ok} : $pal->{normal}, $w);
    $scr->write_str($x, $py++, sprintf("Inventory CAS       : ok=%d conflict=%d | Stripe Webhooks: %d",
        $cas_ok, $cas_conf, $webhooks), $pal->{normal}, $w);
    $scr->write_str($x, $py++, sprintf("MT::Fiber Pool      : mapped=%d free=%d peak=%d | sched ready=%d parked=%d ticks=%d",
        $fstats->{mapped} // 0, $fstats->{free} // 0, $fstats->{peak} // 0,
        $sstats->{ready}  // 0, $sstats->{parked} // 0, $sstats->{ticks} // 0), $pal->{normal}, $w);
    $scr->write_str($x, $py++, sprintf("MT::Supervisor      : %d healthy, %d faulted | MT::Fault=%d | DB=%s",
        $alive_units, $faulted_units, $faults, ($app->{db} ? $app->{db}->driver() : 'none')), $faulted_units ? $pal->{err} : $pal->{ok}, $w);

    # Cluster Wavefunction & DoS Blackhole telemetry
    my $cl_cfg   = (ref($app->{config}) eq 'HASH' && ref($app->{config}{cluster}) eq 'HASH')
        ? $app->{config}{cluster}
        : {};
    my $cl_snap  = {};
    if ($app->{cluster_cell} && $app->{cluster_cell}->can('get')) {
        my $raw = eval { $app->{cluster_cell}->get };
        if (defined $raw && length $raw) {
            my $dec = eval { require Shop::Domain::JSON; Shop::Domain::JSON::decode_json($raw) };
            $cl_snap = $dec if ref($dec) eq 'HASH';
        }
    } elsif (defined $cl_cfg->{_snap_cell_id}) {
        my $cell = $self->{_cluster_cell_cache} ||= eval { require MT::Cell; MT::Cell->attach($cl_cfg->{_snap_cell_id}) };
        if ($cell) {
            my $raw = eval { $cell->get };
            if (defined $raw && length $raw) {
                my $dec = eval { require Shop::Domain::JSON; Shop::Domain::JSON::decode_json($raw) };
                $cl_snap = $dec if ref($dec) eq 'HASH';
            }
        }
    }
    if ($py < $y + $h && ($cl_cfg->{enabled} || %$cl_snap || ($gm->{cluster_nodes_active} // 0) > 0)) {
        my $c_step   = defined $cl_snap->{step} ? int($cl_snap->{step}) : int($gm->{cluster_wave_step} // 0);
        my $c_nodes  = defined $cl_snap->{dim}  ? int($cl_snap->{dim})  : int($gm->{cluster_nodes_active} // 0);
        my $c_coh_ok = defined $cl_snap->{coherence_ok} ? $cl_snap->{coherence_ok} : ($gm->{cluster_coherence_ok} // 1);
        my $c_coh    = $c_coh_ok ? 'OK' : 'DRIFT';
        my $c_dig    = defined $cl_snap->{digest} && length($cl_snap->{digest}) ? substr($cl_snap->{digest}, 0, 12) : '-';
        my $c_rel    = int($gm->{cluster_relayed_total} // 0);
        $scr->write_str($x, $py++, sprintf("Cluster Wavefunction: step=%d, %d nodes, coherence=%s, digest=%s | relayed=%d",
            $c_step, $c_nodes, $c_coh, $c_dig, $c_rel), $c_coh_ok ? $pal->{ok} : $pal->{err}, $w);
    }
    my $bh_tot = int($gm->{ssh_dos_blackholed_total} // 0);
    my $bh_ban = int($gm->{ssh_dos_banned_ips}       // 0);
    if (ref($cl_snap->{blackhole}) eq 'HASH') {
        $bh_tot = int($cl_snap->{blackhole}{blackholed_total} // $bh_tot) if $bh_tot == 0;
        $bh_ban = int($cl_snap->{blackhole}{banned_ips}       // $bh_ban) if $bh_ban == 0;
    }
    if ($py < $y + $h) {
        $scr->write_str($x, $py++, sprintf("DoS Blackholed      : %d (%d banned IPs)",
            $bh_tot, $bh_ban), $bh_ban > 0 ? $pal->{warn} : $pal->{normal}, $w);
    }
    $py++;

    # Egress Telemetry (Global Shop::Metrics + This Session)
    my $sm = $app->{screen}->metrics();
    my $tm = $app->{session} ? ($app->{session}->egress_stats() || {}) : {};
    my $full_b = $sm->{full_frame_bytes_est} || 0;
    my $diff_b = $sm->{diff_bytes_emitted}   || 0;
    my $raw_tx = $tm->{raw_tx_bytes}         || $diff_b;
    my $wire_b = $tm->{wire_tx_bytes}        || $raw_tx;
    my $comp   = $tm->{compression}          || 'none';

    my $diff_save = $full_b > 0 ? sprintf('%.1f%%', 100.0 * (1 - $diff_b / $full_b)) : '0.0%';
    my $zlib_save = $raw_tx > 0 ? sprintf('%.1f%%', 100.0 * (1 - $wire_b / $raw_tx)) : '0.0%';
    my $tot_save  = $full_b > 0 ? sprintf('%.1f%%', 100.0 * (1 - $wire_b / $full_b)) : '0.0%';

    my $g_full = $gm->{ssh_egress_full_bytes} || 0;
    my $g_diff = $gm->{ssh_egress_diff_bytes} || 0;
    my $g_wire = $gm->{ssh_egress_wire_bytes} || 0;
    my $g_save = $g_full > 0 ? sprintf('%.1f%%', 100.0 * (1 - $g_wire / $g_full)) : '0.0%';

    if ($py < $y + $h) {
        $scr->write_str($x, $py++, "=== EGRESS TELEMETRY (Session & Global Shop::Metrics) ===", $pal->{title}, $w);
    }
    if ($py < $y + $h) {
        $scr->write_str($x, $py++, sprintf("Session Full ANSI   : %8d B  (%d frames, %d idle skipped)",
            $full_b, $sm->{frames_rendered}, $sm->{empty_frames_skipped}), $pal->{normal}, $w);
    }
    if ($py < $y + $h) {
        $scr->write_str($x, $py++, sprintf("Session Diff / Wire : %8d B diff (%s) -> %8d B %s (%s | TOT: %s)",
            $diff_b, $diff_save, $wire_b, $comp, $zlib_save, $tot_save), $pal->{price}, $w);
    }
    if ($py < $y + $h) {
        $scr->write_str($x, $py++, sprintf("Global All Sessions : %8d B full -> %8d B diff -> %8d B wire (SAVED: %s)",
            $g_full, $g_diff, $g_wire, $g_save), $pal->{ok}, $w);
    }
}

sub _draw_inventory {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    my $prods = $self->{products};
    $scr->write_str($x, $y, sprintf("%-10s %-26s %10s %8s", "SKU", "NAME", "PRICE", "STOCK"), $pal->{dim}, $w);
    my $py = $y + 1;
    for (my $i = 0; $i < @$prods && $py < $y + $h - 2; $i++) {
        my $p = $prods->[$i];
        my $st_qty = $app->{inventory} ? $app->{inventory}->get_stock($p->{sku}) : ($p->{stock} // 0);
        my $line = sprintf("%-10s %-26s %10s %8d", substr($p->{sku}, 0, 10), substr($p->{name} // '', 0, 26), '$' . $app->format_money($p->{price}), $st_qty);
        $scr->write_str($x, $py++, $line, ($i == $self->{inv_sel}) ? $pal->{sel} : $pal->{normal}, $w);
    }
    if ($self->{edit_mode} eq 'stock' || $self->{edit_mode} eq 'price') {
        $scr->write_str($x, $y + $h - 1, "New $self->{edit_mode}: $self->{edit_buf}_", $pal->{input}, $w);
    }
}

sub _draw_orders {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    my $ords = $self->{orders};
    $scr->write_str($x, $y, sprintf("%-12s %-12s %-10s %10s", "ORDER ID", "USER", "STATUS", "TOTAL"), $pal->{dim}, $w);
    my $py = $y + 1;
    for (my $i = 0; $i < @$ords && $py < $y + $h - 1; $i++) {
        my $o = $ords->[$i];
        my $line = sprintf("%-12s %-12s %-10s %10s",
            substr($o->{id} // '', 0, 12),
            substr($o->{user_fp} // '', 0, 12),
            uc($o->{status} // ''),
            '$' . $app->format_money($o->{total})
        );
        $scr->write_str($x, $py++, $line, ($i == $self->{ord_sel}) ? $pal->{sel} : $pal->{normal}, $w);
    }
}

sub _format_sys_ts {
    my ($ts) = @_;
    return '-' unless defined $ts && length($ts);
    return 'CURRENT' if $ts =~ /^9999-/;
    # Shorten ISO/Db2 timestamp "YYYY-MM-DD HH:MM:SS.ffffff" -> "MM-DD HH:MM:SS"
    if ($ts =~ /^\d{4}-(\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})/) {
        return "$1 $2";
    }
    return substr($ts, 0, 14);
}

sub _db2_engine_banner {
    my ($self, $app, $w) = @_;
    my $feat = $self->{db2_features} || {};
    my $drv  = lc($feat->{driver} // ($app->{db} ? $app->{db}->driver() : 'none'));
    my $eng  = $feat->{engine} // '';

    if ($drv eq 'informix' || $eng =~ /informix/i) {
        my @parts = ('IBM Informix');
        push @parts, 'SP-ONLY (SQLi Blocked)' if $feat->{sp_only};
        push @parts, 'SPL Procedures'         if $feat->{spl_procs};
        push @parts, 'DECIMAL(32,4)'          if $feat->{decimal32};
        push @parts, 'Trigger Audit'          if $feat->{temporal};
        push @parts, 'ROLLUP OLAP'            if $feat->{olap_rollup};
        return (join(' | ', @parts), 1);
    }

    if ($drv eq 'db2' || $eng =~ /db2/i) {
        my @parts = ('IBM Db2 CE');
        push @parts, 'SP-ONLY (SQLi Blocked)' if $feat->{sp_only};
        push @parts, 'DECFLOAT(34)'           if $feat->{decfloat34};
        push @parts, ($w && $w < 110 ? 'SYSTEM_TIME' : 'SYSTEM_TIME Temporal') if $feat->{temporal};
        push @parts, 'FINAL TABLE'            if $feat->{final_table};
        push @parts, 'MERGE'                  if $feat->{merge};
        push @parts, 'ROLLUP OLAP'            if $feat->{olap_rollup};
        return (join(' | ', @parts), 1);
    }

    my $msg = 'SQLite (dev mode)';
    $msg .= ' | SP-ONLY (SQLi Blocked)' if $feat->{sp_only};
    $msg .= ' | Fallback History & OLAP (SHOP_DB_DRIVER=db2 for IBM Db2 CE)';
    return ($msg, 0);
}

sub _draw_db2_olap {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};

    # Top engine & features banner
    my ($banner, $is_db2) = $self->_db2_engine_banner($app, $w);
    $scr->write_str($x, $y, $banner, $is_db2 ? $pal->{ok} : $pal->{warn}, $w);
    $scr->hline($x, $y + 1, $w, undef, $pal->{dim}) if $h > 2;

    my $py = $y + 2;
    my $ph = $h - 2;
    return if $ph < 2;

    if ($w >= 64) {
        # Side-by-side two-pane layout
        my $lw = int($w * 0.52);
        $lw = 32 if $lw < 32;
        my $rx = $x + $lw + 2;
        my $rw = $w - $lw - 2;
        $scr->vline($x + $lw, $py, $ph, undef, $pal->{dim});
        $self->_draw_temporal_pane($app, $scr, $x,  $py, $lw, $ph);
        $self->_draw_olap_pane($app,     $scr, $rx, $py, $rw, $ph) if $rw >= 18;
    } else {
        # Stacked layout for narrow terminals
        my $lh = int($ph / 2);
        $self->_draw_temporal_pane($app, $scr, $x, $py,       $w, $lh);
        $self->_draw_olap_pane($app,     $scr, $x, $py + $lh, $w, $ph - $lh);
    }
}

sub _draw_temporal_pane {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    my $py  = $y;
    my $end = $y + $h;

    $scr->write_str($x, $py++, "Temporal Audit Trail (FOR SYSTEM_TIME ALL)", $pal->{title}, $w);
    return if $py >= $end;

    my $prods = $self->{products} || [];
    my $nprod = scalar(@$prods);
    if ($nprod > 0) {
        my $idx = $self->{db2_sku_sel} // 0;
        $idx = 0 if $idx >= $nprod || $idx < 0;
        my $sku = $prods->[$idx]{sku} // '';
        $scr->write_str($x, $py++, sprintf("SKU: %s (%d/%d) [n/p/arrows]", $sku, $idx + 1, $nprod), $pal->{key}, $w);
    } else {
        $scr->write_str($x, $py++, "SKU: (no products loaded)", $pal->{dim}, $w);
    }
    return if $py >= $end;

    $scr->write_str($x, $py++, sprintf("%-9s %5s  %s", "PRICE", "STOCK", "SYS_START -> SYS_END"), $pal->{dim}, $w);

    # Reserve bottom rows for Order Lifecycle History when space allows
    my $ord_reserve = ($end - $py >= 6) ? 4 : 0;
    my $prod_limit  = $end - $ord_reserve;
    my $phist = $self->{prod_history} || [];
    if (@$phist) {
        for my $r (@$phist) {
            last if $py >= $prod_limit;
            my $s0 = _format_sys_ts($r->{sys_start});
            my $s1 = _format_sys_ts($r->{sys_end});
            my $is_cur = ($s1 eq 'CURRENT');
            my $line = sprintf("\$%-8s %5d  %s -> %s",
                $app->format_money($r->{price}),
                int($r->{stock} // 0),
                $s0, $s1
            );
            $scr->write_str($x, $py++, $line, $is_cur ? $pal->{price} : $pal->{normal}, $w);
        }
    } else {
        $scr->write_str($x, $py++, "(no temporal versions yet)", $pal->{dim}, $w) if $py < $prod_limit;
    }

    # Order lifecycle history section
    return if $py + 2 >= $end;
    $py++ if $py < $end - 3;
    my $ords = $self->{orders} || [];
    my $nord = scalar(@$ords);
    if ($nord > 0) {
        my $oidx = $self->{db2_ord_sel} // 0;
        $oidx = 0 if $oidx >= $nord || $oidx < 0;
        my $oid = $ords->[$oidx]{id} // '';
        $scr->write_str($x, $py++, sprintf("Order Lifecycle: #%s (%d/%d) [o]", $oid, $oidx + 1, $nord), $pal->{title}, $w);
    } else {
        $scr->write_str($x, $py++, "Order Lifecycle: (no orders yet)", $pal->{title}, $w);
    }
    return if $py >= $end;

    $scr->write_str($x, $py++, sprintf("%-9s %-9s %s", "STATUS", "TOTAL", "SYS_START -> SYS_END"), $pal->{dim}, $w);
    my $ohist = $self->{ord_history} || [];
    if (@$ohist) {
        for my $r (@$ohist) {
            last if $py >= $end;
            my $s0 = _format_sys_ts($r->{sys_start});
            my $s1 = _format_sys_ts($r->{sys_end});
            my $is_cur = ($s1 eq 'CURRENT');
            my $line = sprintf("%-9s \$%-8s %s -> %s",
                substr(uc($r->{status} // ''), 0, 9),
                $app->format_money($r->{total}),
                $s0, $s1
            );
            $scr->write_str($x, $py++, $line, $is_cur ? $pal->{ok} : $pal->{normal}, $w);
        }
    } elsif ($py < $end) {
        $scr->write_str($x, $py++, "(no order history rows)", $pal->{dim}, $w);
    }
}

sub _draw_olap_pane {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    my $py  = $y;
    my $end = $y + $h;

    $scr->write_str($x, $py++, "Live Category OLAP (ROLLUP + Window)", $pal->{title}, $w);
    return if $py >= $end;

    my $cat_w = $w - 28;
    $cat_w = 8  if $cat_w < 8;
    $cat_w = 18 if $cat_w > 18;
    my $hdr = sprintf("%-2s %-${cat_w}s %4s %10s %6s", "RK", "CATEGORY", "QTY", "REVENUE", "SHARE");
    $scr->write_str($x, $py++, $hdr, $pal->{dim}, $w);

    my $rows = $self->{olap_rows} || [];
    if (!@$rows) {
        $scr->write_str($x, $py++, "(no orders yet for ROLLUP OLAP)", $pal->{dim}, $w) if $py < $end;
        return;
    }

    for my $r (@$rows) {
        last if $py >= $end;
        my $cat = $r->{category};
        my $rk  = $r->{rank};
        my $is_total = (!defined($cat) || $cat eq '' || uc($cat) eq 'ALL CATEGORIES' || uc($cat) eq 'TOTAL' || (defined($rk) && $rk == 0));

        if ($is_total && $py + 1 < $end) {
            $scr->hline($x, $py++, $w, undef, $pal->{dim});
        }
        my $rk_str  = $is_total ? '==' : sprintf('#%d', int($rk // 0));
        my $cat_lbl = $is_total ? 'ALL CATEGORIES' : substr($cat, 0, $cat_w);
        my $units   = int($r->{units_sold} // 0);
        my $rev_str = '$' . $app->format_money($r->{revenue} // '0.00');
        my $sh_raw  = $r->{share_pct} // '0.0';
        my $sh_str  = ($sh_raw =~ /%$/) ? $sh_raw : sprintf('%.1f%%', $sh_raw + 0);

        my $line = sprintf("%-2s %-${cat_w}s %4d %10s %6s",
            $rk_str,
            substr($cat_lbl, 0, $cat_w),
            $units,
            $rev_str,
            $sh_str
        );
        $scr->write_str($x, $py++, $line, $is_total ? $pal->{price} : $pal->{normal}, $w);
    }
}

sub _nexus_badge {
    my ($row, $pal) = @_;
    my $st = uc($row->{alert_status} // $row->{status} // ($row->{registered} ? 'REGISTERED' : 'OK'));
    $st = 'OK' if $st eq 'BELOW_THRESHOLD' || $st eq 'NO_NEXUS';
    return ('REGISTERED',     $pal->{ok})   if $st eq 'REGISTERED';
    return ('NEXUS_REQUIRED', $pal->{err})  if $st eq 'NEXUS_REQUIRED';
    return ('APPROACHING',    $pal->{warn}) if $st eq 'APPROACHING';
    return ('OK',             $pal->{dim});
}

sub _draw_logistics {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};

    # Reserve bottom rows for Tax Nexus Monitor
    my $nexus_h = ($h >= 14) ? 7 : ($h >= 10 ? 5 : 3);
    my $top_h   = $h - $nexus_h - 1;
    $top_h = 4 if $top_h < 4;

    if ($w >= 72) {
        my $lw = int($w * 0.50);
        my $rx = $x + $lw + 2;
        my $rw = $w - $lw - 2;
        $scr->vline($x + $lw, $y, $top_h, undef, $pal->{dim});
        $self->_draw_po_pane($app,   $scr, $x,  $y, $lw, $top_h);
        $self->_draw_ship_pane($app, $scr, $rx, $y, $rw, $top_h) if $rw >= 20;
    } else {
        my $half = int($top_h / 2);
        $self->_draw_po_pane($app,   $scr, $x, $y,         $w, $half);
        $self->_draw_ship_pane($app, $scr, $x, $y + $half, $w, $top_h - $half);
    }

    my $ny = $y + $top_h;
    $scr->hline($x, $ny++, $w, undef, $pal->{dim}) if $ny < $y + $h;
    $self->_draw_nexus_pane($app, $scr, $x, $ny, $w, ($y + $h) - $ny) if $ny < $y + $h;
}

sub _draw_po_pane {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    my $py  = $y;
    my $end = $y + $h;
    my $act = ($self->{log_pane} eq 'po');

    my $hdr_t = $act ? "Inbound PO Queue [ACTIVE] [r:Recv10 /:Scan]" : "Inbound PO Queue [w:Focus] [r:Recv10]";
    $scr->write_str($x, $py++, $hdr_t, $act ? $pal->{title} : $pal->{dim}, $w);
    return if $py >= $end;

    $scr->write_str($x, $py++, sprintf("%-4s %-11s %-9s %7s %-7s", "WH", "SUPPLIER", "SKU", "RCV/ORD", "STATUS"), $pal->{dim}, $w);
    my $lines = $self->{po_lines} || [];
    my $lim = ($self->{edit_mode} eq 'po_scan') ? ($end - 1) : $end;

    if (!@$lines) {
        $scr->write_str($x, $py++, "(no open purchase orders)", $pal->{dim}, $w) if $py < $lim;
    } else {
        for (my $i = 0; $i < @$lines && $py < $lim; $i++) {
            my $ln = $lines->[$i];
            my $qty_s = sprintf("%d/%d", $ln->{qty_received} // 0, $ln->{qty_ordered} // 0);
            my $row_s = sprintf("%-4s %-11s %-9s %7s %-7s",
                substr($ln->{warehouse_code} // '', 0, 4),
                substr($ln->{supplier}       // '', 0, 11),
                substr($ln->{sku}            // '', 0, 9),
                $qty_s,
                substr($ln->{po_status}      // '', 0, 7)
            );
            my $st = ($i == $self->{po_sel})
                ? ($act ? $pal->{sel} : $pal->{key})
                : (($ln->{po_status} // '') eq 'RECEIVED' ? $pal->{ok} : $pal->{normal});
            $scr->write_str($x, $py++, $row_s, $st, $w);
        }
    }

    if ($self->{edit_mode} eq 'po_scan' && $end > $y + 1) {
        $scr->write_str($x, $end - 1, "Scan/Type SKU + Enter: $self->{edit_buf}_", $pal->{input}, $w);
    }
}

sub _draw_ship_pane {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    my $py  = $y;
    my $end = $y + $h;
    my $act = ($self->{log_pane} eq 'ship');

    my $hdr_t = $act ? "Outbound Shipments [ACTIVE] [p:Pick/Pack b:Label]" : "Outbound Shipments [w:Focus] [p:Pick b:Label]";
    $scr->write_str($x, $py++, $hdr_t, $act ? $pal->{title} : $pal->{dim}, $w);
    return if $py >= $end;

    $scr->write_str($x, $py++, sprintf("%-4s %-9s %-6s %-13s %-13s", "WH", "ORDER", "CARR", "TRACKING", "STATUS"), $pal->{dim}, $w);
    my $ships = $self->{shipments} || [];
    if (!@$ships) {
        $scr->write_str($x, $py++, "(no shipments yet)", $pal->{dim}, $w) if $py < $end;
        return;
    }

    for (my $i = 0; $i < @$ships && $py < $end; $i++) {
        my $sh  = $ships->[$i];
        my $trk = length($sh->{tracking_number} // '') ? $sh->{tracking_number} : '-';
        my $sst = uc($sh->{status} // 'PENDING');
        my $row_s = sprintf("%-4s %-9s %-6s %-13s %-13s",
            substr($sh->{warehouse_code} // 'DAL1', 0, 4),
            substr($sh->{order_id}       // '',     0, 9),
            substr($sh->{carrier}        // 'USPS', 0, 6),
            substr($trk,                            0, 13),
            substr($sst,                            0, 13)
        );
        my $st = ($i == $self->{ship_sel})
            ? ($act ? $pal->{sel} : $pal->{key})
            : ($sst eq 'DELIVERED' ? $pal->{ok} : ($sst eq 'IN_TRANSIT' || $sst eq 'LABEL_CREATED' ? $pal->{title} : $pal->{normal}));
        $scr->write_str($x, $py++, $row_s, $st, $w);
    }
}

sub _draw_nexus_pane {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    my $py  = $y;
    my $end = $y + $h;
    return if $py >= $end;

    $scr->write_str($x, $py++, "Tax Nexus Monitor (Economic Nexus Thresholds & Registration)", $pal->{title}, $w);
    return if $py >= $end;

    $scr->write_str($x, $py++, sprintf("%-5s %7s  %-24s %6s  %-15s", "STATE", "RATE", "YTD SALES / THRESHOLD", "TXNS", "STATUS"), $pal->{dim}, $w);
    my $rows = $self->{nexus_rows} || [];
    if (!@$rows) {
        $scr->write_str($x, $py++, "(no tax nexus rules loaded)", $pal->{dim}, $w) if $py < $end;
        return;
    }

    for my $r (@$rows) {
        last if $py >= $end;
        my $rate_pct = sprintf('%.2f%%', (($r->{rate} // 0) + 0) * 100.0);
        my $ytd_s    = '$' . $app->format_money($r->{ytd_sales} // '0.00');
        my $thr_s    = '$' . $app->format_money($r->{threshold_sales} // '0.00');
        my $txns_s   = int($r->{ytd_txns} // 0) . (($r->{threshold_txns} // 0) > 0 ? '/' . int($r->{threshold_txns}) : '');
        my ($badge, $bst) = _nexus_badge($r, $pal);
        my $prefix = sprintf("%-5s %7s  %-24s %6s  ",
            substr(uc($r->{state} // ''), 0, 5),
            $rate_pct,
            substr("$ytd_s / $thr_s", 0, 24),
            substr($txns_s, 0, 6)
        );
        $scr->write_str($x, $py, $prefix, $pal->{normal}, $w);
        my $bx = $x + length($prefix);
        if ($bx < $x + $w) {
            $scr->write_str($bx, $py, "[$badge]", $bst, ($x + $w) - $bx);
        }
        $py++;
    }
}

sub _draw_broadcast {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    $scr->write_str($x, $y, "Send a live announcement banner to all connected SSH shoppers:", $pal->{normal}, $w);
    if ($self->{edit_mode} eq 'broadcast') {
        $scr->write_str($x, $y + 2, "Message: " . $self->{edit_buf} . "_", $pal->{input}, $w);
    } else {
        $scr->write_str($x, $y + 2, "Press [b] or [Enter] to compose a broadcast message.", $pal->{key}, $w);
    }
}

1;
