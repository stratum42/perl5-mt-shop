package Shop::DB;

use strict;
use warnings;
use MT::Decimal;
use Shop::DB::Db2;
use Shop::DB::Informix;
use Shop::DB::SQLite;

# Factory: Shop::DB->new($cfg) -> Shop::DB::Db2, Shop::DB::Informix, or Shop::DB::SQLite
sub new {
    my ($class, $cfg) = @_;
    $cfg ||= {};
    my $driver = lc($cfg->{driver} // $ENV{SHOP_DB_DRIVER} // 'sqlite');
    if ($driver eq 'db2') {
        return Shop::DB::Db2->new($cfg);
    }
    elsif ($driver eq 'informix' || $driver eq 'ifx') {
        return Shop::DB::Informix->new($cfg);
    }
    elsif ($driver eq 'sqlite' || $driver eq 'sqlite3') {
        return Shop::DB::SQLite->new($cfg);
    }
    die "Shop::DB: unsupported driver '$driver'\n";
}

# --- Shared SQL splitting and idempotent schema initialization ---

sub _split_sql {
    my ($text) = @_;
    my @stmts;
    my $cur = '';
    my $in_sq = 0;
    my $i = 0;
    my $n = length($text);
    while ($i < $n) {
        my $ch = substr($text, $i, 1);
        if (!$in_sq && $ch eq '-' && $i + 1 < $n && substr($text, $i + 1, 1) eq '-') {
            while ($i < $n && substr($text, $i, 1) ne "\n") { $i++; }
            next;
        }
        if ($ch eq "'") {
            if ($in_sq && $i + 1 < $n && substr($text, $i + 1, 1) eq "'") {
                $cur .= "''";
                $i += 2;
                next;
            }
            $in_sq = !$in_sq;
            $cur .= $ch;
        }
        elsif ($ch eq ';' && !$in_sq) {
            $cur =~ s/^\s+|\s+$//g;
            push @stmts, $cur if length $cur;
            $cur = '';
        }
        else {
            $cur .= $ch;
        }
        $i++;
    }
    $cur =~ s/^\s+|\s+$//g;
    push @stmts, $cur if length $cur;
    return @stmts;
}

sub ensure_v2_columns {
    my ($self) = @_;
    return 1 if $self->{_v2_migrated};
    my $is_db2 = ($self->driver eq 'db2') ? 1 : 0;
    my @alters = $is_db2 ? (
        "ALTER TABLE users ADD COLUMN stripe_customer_id VARCHAR(128) NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN default_payment_method VARCHAR(128) NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN default_payment_last4 VARCHAR(8) NOT NULL DEFAULT ''",
        "ALTER TABLE orders ADD COLUMN receipt_sig VARCHAR(256) NOT NULL DEFAULT ''",
        "ALTER TABLE orders ADD COLUMN receipt_hash VARCHAR(128) NOT NULL DEFAULT ''",
    ) : (
        "ALTER TABLE users ADD COLUMN stripe_customer_id TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN default_payment_method TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN default_payment_last4 TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE orders ADD COLUMN receipt_sig TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE orders ADD COLUMN receipt_hash TEXT NOT NULL DEFAULT ''",
    );
    for my $stmt (@alters) {
        eval { $self->exec($stmt); };
        if (my $err = $@) {
            next if $err =~ /duplicate column|SQL0612N|42711|already exists|duplicate/i;
            # Ignore if table doesn't exist yet during early calls
            next if $err =~ /no such table|SQL0204N|42704/i;
            die "ensure_v2_columns failed: $err\nSQL: $stmt\n";
        }
    }
    $self->{_v2_migrated} = 1;
    return 1;
}

sub init_schema {
    my ($self, $schema_file, $seed_file) = @_;
    for my $file (grep { defined $_ && -f $_ } ($schema_file, $seed_file)) {
        open my $fh, '<:encoding(UTF-8)', $file or die "Cannot read $file: $!\n";
        local $/;
        my $sql_text = <$fh>;
        close $fh;
        for my $stmt (_split_sql($sql_text)) {
            eval { $self->exec($stmt); };
            if (my $err = $@) {
                # Ignore idempotent duplicate table/index/key errors
                next if $err =~ /SQL0601N|42710|SQL0803N|23505|already exists|UNIQUE constraint failed/i;
                die "init_schema failed on $file: $err\nSQL: $stmt\n";
            }
        }
    }
    $self->ensure_v2_columns;
    return 1;
}

# --- High-level Domain Data Access (100% shared across Db2 & SQLite) ---

sub list_products {
    my ($self) = @_;
    return $self->query(
        'SELECT sku, name, category, description, ascii_art, price, stock, active FROM products WHERE active = 1 ORDER BY sku'
    );
}

sub get_product {
    my ($self, $sku) = @_;
    my $rows = $self->query(
        'SELECT sku, name, category, description, ascii_art, price, stock, active FROM products WHERE sku = ?',
        $sku
    );
    return @$rows ? $rows->[0] : undef;
}

sub upsert_product {
    my ($self, $p) = @_;
    my $existing = $self->get_product($p->{sku});
    if ($existing) {
        $self->exec(
            'UPDATE products SET name = ?, category = ?, description = ?, ascii_art = ?, price = ?, stock = ?, active = ? WHERE sku = ?',
            $p->{name}        // $existing->{name},
            $p->{category}    // $existing->{category},
            $p->{description} // $existing->{description},
            $p->{ascii_art}   // $existing->{ascii_art},
            defined $p->{price} ? "$p->{price}" : "$existing->{price}",
            defined $p->{stock} ? int($p->{stock}) : int($existing->{stock}),
            defined $p->{active} ? int($p->{active}) : int($existing->{active}),
            $p->{sku},
        );
    }
    else {
        $self->exec(
            'INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            $p->{sku},
            $p->{name}        // $p->{sku},
            $p->{category}    // 'General',
            $p->{description} // '',
            $p->{ascii_art}   // '',
            "$p->{price}",
            int($p->{stock}  // 0),
            int($p->{active} // 1),
        );
    }
    return 1;
}

sub update_product_stock {
    my ($self, $sku, $stock) = @_;
    return $self->exec('UPDATE products SET stock = ? WHERE sku = ?', int($stock), $sku);
}

sub get_promo {
    my ($self, $code) = @_;
    return undef unless defined $code && length $code;
    my $rows = $self->query(
        'SELECT code, kind, value, min_subtotal, active FROM promo_codes WHERE UPPER(code) = UPPER(?) AND active = 1',
        $code
    );
    return @$rows ? $rows->[0] : undef;
}

sub get_user {
    my ($self, $fp) = @_;
    return undef unless defined $fp && length $fp;
    my $sql = 'SELECT fingerprint, username, email, pubkey_type, is_admin, stripe_customer_id, default_payment_method, default_payment_last4, created_at FROM users WHERE fingerprint = ?';
    my $rows = eval { $self->query($sql, $fp) };
    if (my $err = $@) {
        if ($err =~ /no such column|SQL0206N|42703/i) {
            $self->ensure_v2_columns;
            $rows = $self->query($sql, $fp);
        }
        else {
            die $err;
        }
    }
    return @$rows ? $rows->[0] : undef;
}

sub upsert_user {
    my ($self, $u) = @_;
    my $fp = $u->{fingerprint} or die "upsert_user: fingerprint required\n";
    my $existing = $self->get_user($fp);
    if ($existing) {
        $self->exec(
            'UPDATE users SET username = ?, email = ?, pubkey_type = ?, is_admin = ?, stripe_customer_id = ?, default_payment_method = ?, default_payment_last4 = ? WHERE fingerprint = ?',
            $u->{username}               // $existing->{username},
            $u->{email}                  // $existing->{email},
            $u->{pubkey_type}            // $existing->{pubkey_type},
            defined $u->{is_admin} ? int($u->{is_admin}) : int($existing->{is_admin}),
            $u->{stripe_customer_id}     // $existing->{stripe_customer_id}     // '',
            $u->{default_payment_method} // $existing->{default_payment_method} // '',
            $u->{default_payment_last4}  // $existing->{default_payment_last4}  // '',
            $fp,
        );
    }
    else {
        $self->exec(
            'INSERT INTO users (fingerprint, username, email, pubkey_type, is_admin, stripe_customer_id, default_payment_method, default_payment_last4) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            $fp,
            $u->{username}               // 'guest',
            $u->{email}                  // '',
            $u->{pubkey_type}            // '',
            int($u->{is_admin} // 0),
            $u->{stripe_customer_id}     // '',
            $u->{default_payment_method} // '',
            $u->{default_payment_last4}  // '',
        );
    }
    return $self->get_user($fp);
}

sub save_user_payment_method {
    my ($self, $fp, $pm_id, $last4, $stripe_customer_id) = @_;
    die "save_user_payment_method: fingerprint required\n" unless defined $fp && length $fp;
    my $existing = $self->get_user($fp);
    if (!$existing) {
        $self->upsert_user({
            fingerprint            => $fp,
            username               => 'guest',
            stripe_customer_id     => $stripe_customer_id // '',
            default_payment_method => $pm_id // '',
            default_payment_last4  => $last4 // '',
        });
        return $self->get_user($fp);
    }
    my $cust_id = defined $stripe_customer_id
        ? $stripe_customer_id
        : ($existing->{stripe_customer_id} // '');
    $self->exec(
        'UPDATE users SET default_payment_method = ?, default_payment_last4 = ?, stripe_customer_id = ? WHERE fingerprint = ?',
        $pm_id // '',
        $last4 // '',
        $cust_id,
        $fp,
    );
    return $self->get_user($fp);
}

sub get_default_address {
    my ($self, $user_fp) = @_;
    return undef unless defined $user_fp && length $user_fp;
    my $addrs = $self->list_addresses($user_fp);
    return ($addrs && @$addrs) ? $addrs->[0] : undef;
}

sub list_addresses {
    my ($self, $user_fp) = @_;
    return $self->query(
        'SELECT id, user_fp, label, recipient, line1, line2, city, state, postal_code, country, is_default FROM addresses WHERE user_fp = ? ORDER BY is_default DESC, id ASC',
        $user_fp
    );
}

sub save_address {
    my ($self, $a) = @_;
    my $id = $a->{id} || sprintf('addr_%d_%06d', time(), int(rand(1_000_000)));
    my $rows = $self->query('SELECT id FROM addresses WHERE id = ?', $id);
    if (@$rows) {
        $self->exec(
            'UPDATE addresses SET label = ?, recipient = ?, line1 = ?, line2 = ?, city = ?, state = ?, postal_code = ?, country = ?, is_default = ? WHERE id = ? AND user_fp = ?',
            $a->{label}       // 'Home',
            $a->{recipient}   // '',
            $a->{line1}       // '',
            $a->{line2}       // '',
            $a->{city}        // '',
            $a->{state}       // '',
            $a->{postal_code} // '',
            $a->{country}     // 'US',
            int($a->{is_default} // 0),
            $id,
            $a->{user_fp},
        );
    }
    else {
        $self->exec(
            'INSERT INTO addresses (id, user_fp, label, recipient, line1, line2, city, state, postal_code, country, is_default) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            $id,
            $a->{user_fp},
            $a->{label}       // 'Home',
            $a->{recipient}   // '',
            $a->{line1}       // '',
            $a->{line2}       // '',
            $a->{city}        // '',
            $a->{state}       // '',
            $a->{postal_code} // '',
            $a->{country}     // 'US',
            int($a->{is_default} // 0),
        );
    }
    my $saved = $self->query('SELECT id, user_fp, label, recipient, line1, line2, city, state, postal_code, country, is_default FROM addresses WHERE id = ?', $id);
    return @$saved ? $saved->[0] : { %$a, id => $id };
}

sub delete_address {
    my ($self, $id, $user_fp) = @_;
    return $self->exec('DELETE FROM addresses WHERE id = ? AND user_fp = ?', $id, $user_fp);
}

sub create_order {
    my ($self, $ord, $items) = @_;
    my $order_id = $ord->{id} || sprintf('ORD-%d-%04d', time(), int(rand(10000)));
    my $do_insert = sub {
        $self->txn(sub {
            my ($tx) = @_;
            $tx->exec(
                'INSERT INTO orders (id, user_fp, username, status, subtotal, discount, tax, shipping, total, promo_code, payment_method, payment_ref, shipping_address, receipt_sig, receipt_hash) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                $order_id,
                $ord->{user_fp},
                $ord->{username}         // 'guest',
                $ord->{status}           // 'paid',
                "$ord->{subtotal}",
                "$ord->{discount}",
                "$ord->{tax}",
                "$ord->{shipping}",
                "$ord->{total}",
                $ord->{promo_code}       // '',
                $ord->{payment_method}   // 'mock',
                $ord->{payment_ref}      // '',
                $ord->{shipping_address} // '',
                $ord->{receipt_sig}      // '',
                $ord->{receipt_hash}     // '',
            );
            my $idx = 0;
            for my $it (@$items) {
                $idx++;
                my $item_id = sprintf('%s-%02d', $order_id, $idx);
                $tx->exec(
                    'INSERT INTO order_items (id, order_id, sku, name, qty, unit_price, line_total) VALUES (?, ?, ?, ?, ?, ?, ?)',
                    $item_id,
                    $order_id,
                    $it->{sku},
                    $it->{name} // $it->{sku},
                    int($it->{qty}),
                    "$it->{unit_price}",
                    "$it->{line_total}",
                );
                $tx->exec(
                    'UPDATE products SET stock = stock - ? WHERE sku = ? AND stock >= ?',
                    int($it->{qty}),
                    $it->{sku},
                    int($it->{qty}),
                );
            }
        });
    };
    eval { $do_insert->(); };
    if (my $err = $@) {
        if ($err =~ /no such column|has no column|SQL0206N|42703/i) {
            $self->ensure_v2_columns;
            $do_insert->();
        }
        else {
            die $err;
        }
    }
    return $self->get_order($order_id);
}

sub list_orders {
    my ($self, $user_fp) = @_;
    my $cols = 'id, user_fp, username, status, subtotal, discount, tax, shipping, total, promo_code, payment_method, payment_ref, shipping_address, receipt_sig, receipt_hash, created_at';
    my $run = sub {
        if (defined $user_fp && length $user_fp) {
            return $self->query(
                "SELECT $cols FROM orders WHERE user_fp = ? ORDER BY created_at DESC, id DESC",
                $user_fp
            );
        }
        return $self->query(
            "SELECT $cols FROM orders ORDER BY created_at DESC, id DESC"
        );
    };
    my $rows = eval { $run->() };
    if (my $err = $@) {
        if ($err =~ /no such column|SQL0206N|42703/i) {
            $self->ensure_v2_columns;
            $rows = $run->();
        }
        else {
            die $err;
        }
    }
    return $rows;
}

sub get_order {
    my ($self, $order_id) = @_;
    my $sql = 'SELECT id, user_fp, username, status, subtotal, discount, tax, shipping, total, promo_code, payment_method, payment_ref, shipping_address, receipt_sig, receipt_hash, created_at FROM orders WHERE id = ?';
    my $rows = eval { $self->query($sql, $order_id) };
    if (my $err = $@) {
        if ($err =~ /no such column|SQL0206N|42703/i) {
            $self->ensure_v2_columns;
            $rows = $self->query($sql, $order_id);
        }
        else {
            die $err;
        }
    }
    return undef unless @$rows;
    my $ord = $rows->[0];
    $ord->{items} = $self->query(
        'SELECT id, order_id, sku, name, qty, unit_price, line_total FROM order_items WHERE order_id = ? ORDER BY id ASC',
        $order_id
    );
    return $ord;
}

sub get_order_by_payment_ref {
    my ($self, $payment_ref) = @_;
    return undef unless defined $payment_ref && length $payment_ref;
    my $rows = $self->query('SELECT id FROM orders WHERE payment_ref = ? ORDER BY created_at DESC', $payment_ref);
    return undef unless @$rows;
    return $self->get_order($rows->[0]{id});
}

sub update_order_status {
    my ($self, $order_id, $status) = @_;
    return $self->exec('UPDATE orders SET status = ? WHERE id = ?', $status, $order_id);
}

sub update_order_receipt {
    my ($self, $order_id, $receipt_hash, $receipt_sig) = @_;
    return $self->exec(
        'UPDATE orders SET receipt_hash = ?, receipt_sig = ? WHERE id = ?',
        $receipt_hash // '',
        $receipt_sig  // '',
        $order_id,
    );
}

sub gmv_summary {
    my ($self) = @_;
    my $rows = $self->query("SELECT total FROM orders WHERE LOWER(status) <> 'cancelled'");
    my $sum = MT::Decimal->new('0.00');
    for my $r (@$rows) {
        $sum = $sum + MT::Decimal->new("$r->{total}");
    }
    $sum = $sum->quantize(-2, MT::Decimal::ROUND_HALF_UP);
    return {
        order_count => scalar(@$rows),
        total_gmv   => "$sum",
    };
}

# --- Db2 Repository Methods (with SQLite fallbacks) ---

sub db2_features {
    my ($self) = @_;
    return {
        engine      => 'SQLite 3',
        driver      => $self->driver,
        decfloat34  => 0,
        temporal    => 0,
        final_table => 0,
        merge       => 0,
        compression => 'NONE',
        olap_rollup => 0,
        sp_only     => 0,
    };
}

sub current_timestamp {
    my ($self) = @_;
    my $rows = $self->query("SELECT datetime('now') AS ts");
    return (@$rows && defined $rows->[0]{ts}) ? $rows->[0]{ts} : '';
}

sub decrement_product_stock {
    my ($self, $sku, $qty, $tx) = @_;
    my $runner = $tx // $self;
    my $n = $runner->exec(
        "UPDATE products SET stock = stock - ?, updated_at = datetime('now') WHERE sku = ? AND stock >= ?",
        int($qty), $sku, int($qty)
    );
    return undef unless $n && $n > 0;
    my $rows = $runner->query(
        'SELECT sku, name, price, stock, updated_at FROM products WHERE sku = ?',
        $sku
    );
    return @$rows ? $rows->[0] : undef;
}

sub product_history {
    my ($self, $sku, $limit) = @_;
    $limit = 20 if !defined($limit) || $limit <= 0;
    my $rows = $self->query(
        'SELECT sku, name, price, stock, updated_at AS sys_start FROM products WHERE sku = ?',
        $sku
    );
    return [] unless @$rows;
    my $r = $rows->[0];
    $r->{sys_end} = '9999-12-30T00:00:00';
    return [$r];
}

sub catalog_as_of {
    my ($self, $ts) = @_;
    return $self->query(
        'SELECT sku, name, category, price, stock FROM products ORDER BY sku'
    );
}

sub order_history {
    my ($self, $order_id) = @_;
    my $rows = $self->query(
        'SELECT id, status, total, payment_ref, created_at AS sys_start FROM orders WHERE id = ?',
        $order_id
    );
    return [] unless @$rows;
    my $r = $rows->[0];
    $r->{sys_end} = '9999-12-30T00:00:00';
    return [$r];
}

sub list_orders_masked {
    my ($self, $user_fp) = @_;
    my $rows = $self->list_orders($user_fp);
    for my $r (@$rows) {
        my $addr = $r->{shipping_address} // '';
        if (length($addr) > 8) {
            $r->{shipping_address} = substr($addr, 0, 4) . '***MASKED***' . substr($addr, -4);
        }
        elsif (length($addr) > 0) {
            $r->{shipping_address} = '***MASKED***';
        }
    }
    return $rows;
}

sub category_olap {
    my ($self) = @_;
    my $rows = $self->query(
        "SELECT p.category AS category, o.id AS order_id, oi.qty AS qty, oi.line_total AS line_total "
      . "FROM order_items oi "
      . "JOIN orders o ON o.id = oi.order_id AND LOWER(o.status) <> 'cancelled' "
      . "JOIN products p ON p.sku = oi.sku"
    );
    my %by_cat;
    my $grand_rev = MT::Decimal->new('0.00');
    my $grand_units = 0;
    my %grand_orders;

    for my $r (@$rows) {
        my $cat = $r->{category} // 'General';
        $by_cat{$cat} ||= {
            category => $cat,
            orders   => {},
            units    => 0,
            revenue  => MT::Decimal->new('0.00'),
        };
        $by_cat{$cat}{orders}{ $r->{order_id} } = 1;
        $by_cat{$cat}{units} += int($r->{qty} // 0);
        my $lt = MT::Decimal->new("$r->{line_total}");
        $by_cat{$cat}{revenue} = $by_cat{$cat}{revenue} + $lt;

        $grand_orders{ $r->{order_id} } = 1;
        $grand_units += int($r->{qty} // 0);
        $grand_rev = $grand_rev + $lt;
    }

    my @cats = sort {
        $b->{revenue} <=> $a->{revenue}
            || $a->{category} cmp $b->{category}
    } values %by_cat;

    my $hundred = MT::Decimal->new('100');
    my $zero    = MT::Decimal->new('0');
    my @out;
    my $rank = 0;
    my $prev_rev;
    for my $i (0 .. $#cats) {
        my $c = $cats[$i];
        if (!defined($prev_rev) || $c->{revenue} != $prev_rev) {
            $rank = $i + 1;
            $prev_rev = $c->{revenue};
        }
        my $share = ($grand_rev > $zero)
            ? (($c->{revenue} * $hundred) / $grand_rev)->quantize(-2, MT::Decimal::ROUND_HALF_UP)
            : MT::Decimal->new('0.00');
        push @out, {
            category    => $c->{category},
            order_count => scalar(keys %{ $c->{orders} }),
            units_sold  => $c->{units},
            revenue     => "" . $c->{revenue}->quantize(-2, MT::Decimal::ROUND_HALF_UP),
            share_pct   => "$share",
            rank        => $rank,
        };
    }

    push @out, {
        category    => 'ALL CATEGORIES',
        order_count => scalar(keys %grand_orders),
        units_sold  => $grand_units,
        revenue     => "" . $grand_rev->quantize(-2, MT::Decimal::ROUND_HALF_UP),
        share_pct   => ($grand_rev > $zero) ? '100.00' : '0.00',
        rank        => 0,
    };

    return \@out;
}

# --- Logistics, Warehouses, Purchase Orders, Shipments, and Tax Nexus ---

sub list_warehouses {
    my ($self) = @_;
    return $self->query(
        'SELECT code, name, city, state, postal_code, active FROM warehouses WHERE active = 1 ORDER BY code ASC'
    );
}

sub list_warehouse_stock {
    my ($self, $wh_code) = @_;
    if (defined $wh_code && length $wh_code) {
        return $self->query(
            'SELECT warehouse_code, sku, qty, bin_location FROM warehouse_stock WHERE warehouse_code = ? ORDER BY sku ASC',
            $wh_code
        );
    }
    return $self->query(
        'SELECT warehouse_code, sku, qty, bin_location FROM warehouse_stock ORDER BY warehouse_code ASC, sku ASC'
    );
}

sub create_po {
    my ($self, $po, $lines) = @_;
    $po    ||= {};
    $lines ||= [];
    my $po_id = $po->{id} || sprintf('PO-%d-%04d', time(), int(rand(10000)));
    my $total_cost = $po->{total_cost};
    if (!defined $total_cost) {
        my $sum = MT::Decimal->new('0.0000');
        for my $ln (@$lines) {
            my $q = MT::Decimal->new('' . int($ln->{qty_ordered} // 0));
            my $c = MT::Decimal->new('' . ($ln->{unit_cost} // '0.0000'));
            $sum = $sum + ($q * $c);
        }
        $total_cost = '' . $sum->quantize(-4, MT::Decimal::ROUND_HALF_UP);
    }

    $self->txn(sub {
        my ($tx) = @_;
        $tx->exec(
            'INSERT INTO purchase_orders (id, supplier, warehouse_code, status, total_cost) VALUES (?, ?, ?, ?, ?)',
            $po_id,
            $po->{supplier}       // 'Unknown Supplier',
            $po->{warehouse_code} // 'DAL1',
            $po->{status}         // 'OPEN',
            "$total_cost",
        );
        my $idx = 0;
        for my $ln (@$lines) {
            $idx++;
            my $line_id = $ln->{id} || sprintf('%s-%02d', $po_id, $idx);
            $tx->exec(
                'INSERT INTO po_lines (id, po_id, sku, qty_ordered, qty_received, unit_cost) VALUES (?, ?, ?, ?, ?, ?)',
                $line_id,
                $po_id,
                $ln->{sku},
                int($ln->{qty_ordered}  // 1),
                int($ln->{qty_received} // 0),
                '' . ($ln->{unit_cost}  // '0.0000'),
            );
        }
    });

    my $rows = $self->query(
        'SELECT id, supplier, warehouse_code, status, total_cost, created_at FROM purchase_orders WHERE id = ?',
        $po_id
    );
    return undef unless @$rows;
    my $created = $rows->[0];
    $created->{lines} = $self->get_po_lines($po_id);
    return $created;
}

sub list_pos {
    my ($self) = @_;
    return $self->query(
        'SELECT id, supplier, warehouse_code, status, total_cost, created_at FROM purchase_orders ORDER BY created_at DESC, id DESC'
    );
}

sub get_po_lines {
    my ($self, $po_id) = @_;
    return [] unless defined $po_id && length $po_id;
    return $self->query(
        'SELECT id, po_id, sku, qty_ordered, qty_received, unit_cost FROM po_lines WHERE po_id = ? ORDER BY id ASC',
        $po_id
    );
}

sub receive_po_line {
    my ($self, $po_line_id, $qty) = @_;
    $qty = int($qty // 0);
    if (!defined $po_line_id || !length $po_line_id || $qty <= 0) {
        return { ok => 0, error => 'invalid po_line_id or qty' };
    }
    return $self->txn(sub {
        my ($tx) = @_;
        my $rows = $tx->query(
            'SELECT l.id, l.po_id, p.warehouse_code, l.sku, l.qty_ordered, l.qty_received '
          . 'FROM po_lines l JOIN purchase_orders p ON p.id = l.po_id WHERE l.id = ?',
            $po_line_id
        );
        return { ok => 0, error => "po_line '$po_line_id' not found" } unless @$rows;
        my $ln = $rows->[0];
        my $po_id   = $ln->{po_id};
        my $wh_code = $ln->{warehouse_code};
        my $sku     = $ln->{sku};
        my $new_rcv = int($ln->{qty_received} // 0) + $qty;

        $tx->exec(
            'UPDATE po_lines SET qty_received = qty_received + ? WHERE id = ?',
            $qty, $po_line_id
        );

        my $wh_n = $tx->exec(
            'UPDATE warehouse_stock SET qty = qty + ? WHERE warehouse_code = ? AND sku = ?',
            $qty, $wh_code, $sku
        );
        if (!$wh_n || $wh_n <= 0) {
            $tx->exec(
                'INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES (?, ?, ?, ?)',
                $wh_code, $sku, $qty, 'RCV-01'
            );
        }

        $tx->exec(
            "UPDATE products SET stock = stock + ?, updated_at = datetime('now') WHERE sku = ?",
            $qty, $sku
        );

        my $prows = $tx->query('SELECT stock FROM products WHERE sku = ?', $sku);
        my $new_stock = @$prows ? int($prows->[0]{stock} // 0) : 0;

        my $open = $tx->query(
            'SELECT COUNT(*) AS cnt FROM po_lines WHERE po_id = ? AND qty_received < qty_ordered',
            $po_id
        );
        my $open_cnt  = @$open ? int($open->[0]{cnt} // 0) : 0;
        my $po_status = ($open_cnt == 0) ? 'RECEIVED' : 'PARTIAL';

        $tx->exec(
            'UPDATE purchase_orders SET status = ? WHERE id = ?',
            $po_status, $po_id
        );

        return {
            ok             => 1,
            po_id          => $po_id,
            po_line_id     => $po_line_id,
            warehouse_code => $wh_code,
            sku            => $sku,
            qty_received   => $new_rcv,
            new_stock      => $new_stock,
            po_status      => $po_status,
        };
    });
}

sub create_shipment {
    my ($self, $s) = @_;
    $s ||= {};
    my $id = $s->{id} || sprintf('SHP-%d-%04d', time(), int(rand(10000)));
    $self->exec(
        'INSERT INTO shipments (id, order_id, warehouse_code, carrier, service, rate_amount, tracking_number, label_url, status) '
      . 'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        $id,
        $s->{order_id}        // '',
        $s->{warehouse_code}  // 'DAL1',
        $s->{carrier}         // '',
        $s->{service}         // '',
        '' . ($s->{rate_amount} // '0.0000'),
        $s->{tracking_number} // '',
        $s->{label_url}       // '',
        $s->{status}          // 'PENDING',
    );
    my $rows = $self->query(
        'SELECT id, order_id, warehouse_code, carrier, service, rate_amount, tracking_number, label_url, status, updated_at '
      . 'FROM shipments WHERE id = ?',
        $id
    );
    return @$rows ? $rows->[0] : undef;
}

sub update_shipment {
    my ($self, $id, @rest) = @_;
    return undef unless defined $id && length $id;
    my %fields = (@rest == 1 && ref($rest[0]) eq 'HASH') ? %{ $rest[0] } : @rest;
    my $status   = exists $fields{status}          ? $fields{status}          : undef;
    my $tracking = exists $fields{tracking_number} ? $fields{tracking_number}
                 : exists $fields{tracking}        ? $fields{tracking}        : undef;
    my $label    = exists $fields{label_url}       ? $fields{label_url}       : undef;

    $self->exec(
        "UPDATE shipments SET "
      . "status = COALESCE(?, status), "
      . "tracking_number = COALESCE(?, tracking_number), "
      . "label_url = COALESCE(?, label_url), "
      . "updated_at = datetime('now') "
      . "WHERE id = ?",
        $status, $tracking, $label, $id
    );
    my $rows = $self->query(
        'SELECT id, order_id, warehouse_code, carrier, service, rate_amount, tracking_number, label_url, status, updated_at '
      . 'FROM shipments WHERE id = ?',
        $id
    );
    return @$rows ? $rows->[0] : undef;
}

sub get_shipment_by_order {
    my ($self, $order_id) = @_;
    return undef unless defined $order_id && length $order_id;
    my $rows = $self->query(
        'SELECT id, order_id, warehouse_code, carrier, service, rate_amount, tracking_number, label_url, status, updated_at '
      . 'FROM shipments WHERE order_id = ? ORDER BY updated_at DESC, id DESC LIMIT 1',
        $order_id
    );
    return @$rows ? $rows->[0] : undef;
}

sub get_shipment_by_tracking {
    my ($self, $tracking) = @_;
    return undef unless defined $tracking && length $tracking;
    my $rows = $self->query(
        'SELECT id, order_id, warehouse_code, carrier, service, rate_amount, tracking_number, label_url, status, updated_at '
      . 'FROM shipments WHERE tracking_number = ? ORDER BY updated_at DESC, id DESC LIMIT 1',
        $tracking
    );
    return @$rows ? $rows->[0] : undef;
}

sub list_shipments {
    my ($self, $status) = @_;
    if (defined $status && length $status) {
        return $self->query(
            'SELECT id, order_id, warehouse_code, carrier, service, rate_amount, tracking_number, label_url, status, updated_at '
          . 'FROM shipments WHERE UPPER(status) = UPPER(?) ORDER BY updated_at DESC, id DESC',
            $status
        );
    }
    return $self->query(
        'SELECT id, order_id, warehouse_code, carrier, service, rate_amount, tracking_number, label_url, status, updated_at '
      . 'FROM shipments ORDER BY updated_at DESC, id DESC'
    );
}

sub get_tax_nexus {
    my ($self, $state) = @_;
    return undef unless defined $state && length $state;
    my $rows = $self->query(
        'SELECT state, rate, threshold_sales, threshold_txns, registered FROM tax_nexus WHERE UPPER(state) = UPPER(?)',
        $state
    );
    return @$rows ? $rows->[0] : undef;
}

sub list_tax_nexus {
    my ($self) = @_;
    return $self->query(
        'SELECT state, rate, threshold_sales, threshold_txns, registered FROM tax_nexus ORDER BY state ASC'
    );
}

sub tax_nexus_report {
    my ($self) = @_;
    my $nexus_rows = $self->list_tax_nexus();
    my $orders     = $self->query("SELECT total, shipping_address FROM orders WHERE LOWER(status) <> 'cancelled'");

    my @report;
    for my $tn (@$nexus_rows) {
        my $st  = uc($tn->{state} // '');
        my $sum = MT::Decimal->new('0.0000');
        my $cnt = 0;
        for my $o (@$orders) {
            my $addr = uc($o->{shipping_address} // '');
            if ($addr =~ /(?:,\s*|\s)\Q$st\E(?:,|\s|$)/) {
                $sum = $sum + MT::Decimal->new('' . ($o->{total} // '0'));
                $cnt++;
            }
        }
        push @report, {
            state           => $tn->{state},
            rate            => $tn->{rate},
            threshold_sales => $tn->{threshold_sales},
            threshold_txns  => int($tn->{threshold_txns} // 0),
            registered      => int($tn->{registered}     // 0),
            ytd_sales       => '' . $sum->quantize(-4, MT::Decimal::ROUND_HALF_UP),
            ytd_txns        => $cnt,
        };
    }
    return \@report;
}

# --- Memberships and Recurring Subscriptions ---

sub list_membership_tiers {
    my ($self) = @_;
    return $self->query(
        'SELECT code, name, monthly_price, discount_pct, free_shipping, priority_fulfillment, active '
      . 'FROM membership_tiers WHERE active = 1 ORDER BY CAST(monthly_price AS REAL) ASC, code ASC'
    );
}

sub get_membership {
    my ($self, $fp) = @_;
    return undef unless defined $fp && length $fp;
    my $rows = $self->query(
        'SELECT user_fp, tier_code, status, stripe_sub_id, started_at, renews_at, updated_at '
      . 'FROM memberships WHERE user_fp = ?',
        $fp
    );
    return @$rows ? $rows->[0] : undef;
}

sub upsert_membership {
    my ($self, $m) = @_;
    $m ||= {};
    my $fp = $m->{user_fp} or die "upsert_membership: user_fp required\n";
    my $existing = $self->get_membership($fp);
    if ($existing) {
        $self->exec(
            "UPDATE memberships SET tier_code = ?, status = ?, stripe_sub_id = ?, renews_at = ?, updated_at = datetime('now') WHERE user_fp = ?",
            defined($m->{tier_code})     ? "$m->{tier_code}"     : $existing->{tier_code},
            defined($m->{status})        ? "$m->{status}"        : $existing->{status},
            defined($m->{stripe_sub_id}) ? "$m->{stripe_sub_id}" : $existing->{stripe_sub_id},
            defined($m->{renews_at})     ? "$m->{renews_at}"     : $existing->{renews_at},
            $fp,
        );
    }
    else {
        $self->exec(
            'INSERT INTO memberships (user_fp, tier_code, status, stripe_sub_id, renews_at) VALUES (?, ?, ?, ?, ?)',
            $fp,
            $m->{tier_code}     // 'FREE',
            $m->{status}        // 'ACTIVE',
            $m->{stripe_sub_id} // '',
            $m->{renews_at}     // '',
        );
    }
    return $self->get_membership($fp);
}

sub create_subscription {
    my ($self, $s) = @_;
    $s ||= {};
    die "create_subscription: user_fp and sku required\n"
        unless defined $s->{user_fp} && length $s->{user_fp}
            && defined $s->{sku}     && length $s->{sku};
    my $id = $s->{id} || sprintf('SUB-%d-%04d', time(), int(rand(10000)));
    $self->exec(
        'INSERT INTO subscriptions (id, user_fp, sku, qty, interval_days, unit_price, status, next_bill_at, last_order_id, stripe_sub_id) '
      . 'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        $id,
        "$s->{user_fp}",
        "$s->{sku}",
        int($s->{qty}           // 1),
        int($s->{interval_days} // 30),
        defined($s->{unit_price}) ? "$s->{unit_price}" : '0.0000',
        'ACTIVE',
        $s->{next_bill_at}  // '',
        '',
        $s->{stripe_sub_id} // '',
    );
    return $self->get_subscription($id);
}

sub list_subscriptions {
    my ($self, $fp) = @_;
    my $cols = 'id, user_fp, sku, qty, interval_days, unit_price, status, next_bill_at, last_order_id, stripe_sub_id, created_at, updated_at';
    if (defined $fp && length $fp) {
        return $self->query(
            "SELECT $cols FROM subscriptions WHERE user_fp = ? ORDER BY created_at DESC, id DESC",
            $fp
        );
    }
    return $self->query(
        "SELECT $cols FROM subscriptions ORDER BY created_at DESC, id DESC"
    );
}

sub get_subscription {
    my ($self, $id) = @_;
    return undef unless defined $id && length $id;
    my $rows = $self->query(
        'SELECT id, user_fp, sku, qty, interval_days, unit_price, status, next_bill_at, last_order_id, stripe_sub_id, created_at, updated_at '
      . 'FROM subscriptions WHERE id = ?',
        $id
    );
    return @$rows ? $rows->[0] : undef;
}

sub update_subscription {
    my ($self, $id, @rest) = @_;
    return undef unless defined $id && length $id;
    my %fields = (@rest == 1 && ref($rest[0]) eq 'HASH') ? %{ $rest[0] } : @rest;
    my $status        = exists $fields{status}        ? $fields{status}        : undef;
    my $next_bill_at  = exists $fields{next_bill_at}  ? $fields{next_bill_at}  : undef;
    my $last_order_id = exists $fields{last_order_id} ? $fields{last_order_id} : undef;

    $self->exec(
        "UPDATE subscriptions SET "
      . "status = COALESCE(?, status), "
      . "next_bill_at = COALESCE(?, next_bill_at), "
      . "last_order_id = COALESCE(?, last_order_id), "
      . "updated_at = datetime('now') "
      . "WHERE id = ?",
        $status, $next_bill_at, $last_order_id, $id
    );
    return $self->get_subscription($id);
}

sub due_subscriptions {
    my ($self, $as_of_ts) = @_;
    my $ts = (defined $as_of_ts && length $as_of_ts) ? "$as_of_ts" : $self->current_timestamp();
    return $self->query(
        "SELECT id, user_fp, sku, qty, interval_days, unit_price, status, next_bill_at, last_order_id, stripe_sub_id, created_at, updated_at "
      . "FROM subscriptions "
      . "WHERE UPPER(status) = 'ACTIVE' AND next_bill_at <> '' AND next_bill_at <= ? "
      . "ORDER BY next_bill_at ASC, id ASC",
        $ts
    );
}

sub subscription_metrics {
    my ($self) = @_;
    my $mem_rows = $self->query(
        "SELECT mt.monthly_price AS monthly_price "
      . "FROM memberships m "
      . "JOIN membership_tiers mt ON UPPER(mt.code) = UPPER(m.tier_code) "
      . "WHERE UPPER(m.status) = 'ACTIVE' AND UPPER(m.tier_code) <> 'FREE'"
    );
    my $mem_mrr = MT::Decimal->new('0.00');
    for my $r (@$mem_rows) {
        $mem_mrr = $mem_mrr + MT::Decimal->new('' . ($r->{monthly_price} // '0'));
    }

    my $sub_rows = $self->query(
        "SELECT unit_price, qty, interval_days FROM subscriptions WHERE UPPER(status) = 'ACTIVE'"
    );
    my $sub_mrr = MT::Decimal->new('0.00');
    my $thirty  = MT::Decimal->new('30');
    for my $r (@$sub_rows) {
        my $price = MT::Decimal->new('' . ($r->{unit_price} // '0'));
        my $qty   = MT::Decimal->new('' . int($r->{qty} // 1));
        my $days  = MT::Decimal->new('' . int($r->{interval_days} // 30));
        $sub_mrr  = $sub_mrr + (($price * $qty * $thirty) / $days);
    }

    return {
        active_members       => scalar(@$mem_rows),
        active_subscriptions => scalar(@$sub_rows),
        membership_mrr       => '' . $mem_mrr->quantize(-2, MT::Decimal::ROUND_HALF_UP),
        subscription_mrr     => '' . $sub_mrr->quantize(-2, MT::Decimal::ROUND_HALF_UP),
    };
}

1;
