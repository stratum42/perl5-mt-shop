package Shop::DB::Informix;

use strict;
use warnings;
use parent 'Shop::DB';

use IO::Socket::INET;
use MT::Decimal;
use Shop::Domain::JSON ();
sub _enc_json { Shop::Domain::JSON::encode_json($_[0]) }
sub _dec_json { Shop::Domain::JSON::decode_json($_[0]) }
use Compress::Zlib qw(memGzip memGunzip);

sub new {
    my ($class, $cfg) = @_;
    $cfg ||= {};
    my $url = $cfg->{informix_gateway_url}
           // $cfg->{gateway_url}
           // $ENV{INFORMIX_GATEWAY_URL}
           // 'http://127.0.0.1:50051';
    my ($host, $port) = ('127.0.0.1', 50051);
    if ($url =~ m{^https?://([^:/]+)(?::(\d+))?}) {
        $host = $1;
        $port = $2 || 80;
    }
    return bless {
        host    => $cfg->{host}    // $host,
        port    => $cfg->{port}    // $port,
        timeout => $cfg->{timeout} // 15,
        sock    => undef,
    }, $class;
}

sub driver { 'informix' }

sub db2_features {
    my ($self) = @_;
    return {
        engine      => 'IBM Informix Innovator-C',
        driver      => 'informix',
        decfloat34  => 0,
        decimal32   => 1,
        temporal    => 1,
        spl_procs   => 1,
        sp_only     => 1,
        final_table => 0,
        merge       => 1,
        compression => 'ROW',
        olap_rollup => 1,
    };
}

sub _connect {
    my ($self) = @_;
    if ($self->{sock} && $self->{sock}->connected) {
        return $self->{sock};
    }
    my $sock = IO::Socket::INET->new(
        PeerAddr => $self->{host},
        PeerPort => $self->{port},
        Proto    => 'tcp',
        Timeout  => $self->{timeout},
    ) or die "Shop::DB::Informix: cannot connect to $self->{host}:$self->{port}: $!\n";
    binmode($sock);
    $self->{sock} = $sock;
    return $sock;
}

sub _close {
    my ($self) = @_;
    if ($self->{sock}) {
        close $self->{sock};
        $self->{sock} = undef;
    }
}

sub _read_exact {
    my ($sock, $len) = @_;
    my $buf = '';
    while (length($buf) < $len) {
        my $chunk;
        my $n = sysread($sock, $chunk, $len - length($buf));
        return undef if !defined $n || $n == 0;
        $buf .= $chunk;
    }
    return $buf;
}

sub _read_http_response {
    my ($self, $sock) = @_;
    my $hdr = '';
    while ($hdr !~ /\r\n\r\n/) {
        my $ch;
        my $n = sysread($sock, $ch, 1);
        return undef if !defined $n || $n == 0;
        $hdr .= $ch;
        return undef if length($hdr) > 65536;
    }
    my ($status_line, @lines) = split /\r\n/, $hdr;
    my ($status) = ($status_line =~ m{^HTTP/\d+\.\d+\s+(\d+)});
    my %headers;
    for my $line (@lines) {
        next unless length $line;
        my ($k, $v) = split /:\s*/, $line, 2;
        $headers{lc($k)} = $v if defined $k;
    }
    my $body = '';
    if (defined $headers{'content-length'}) {
        $body = _read_exact($sock, int($headers{'content-length'}));
        return undef unless defined $body;
    }
    if (($headers{'content-encoding'} // '') =~ /gzip/i && length $body) {
        my $inflated = memGunzip($body);
        $body = $inflated if defined $inflated;
    }
    if (($headers{'connection'} // '') =~ /close/i) {
        $self->_close;
    }
    return ($status || 500, $body);
}

sub _request {
    my ($self, $method, $path, $payload) = @_;
    my $body = defined $payload ? _enc_json($payload) : '';
    my $extra_hdr = '';
    if (length($body) > 512) {
        my $gz = memGzip($body);
        if (defined $gz && length($gz) < length($body)) {
            $body = $gz;
            $extra_hdr = "Content-Encoding: gzip\r\n";
        }
    }

    my $req = "$method $path HTTP/1.1\r\n"
            . "Host: $self->{host}:$self->{port}\r\n"
            . "Connection: keep-alive\r\n"
            . "Accept-Encoding: gzip\r\n"
            . ($method eq 'POST' ? "Content-Type: application/json\r\n" : '')
            . $extra_hdr
            . "Content-Length: " . length($body) . "\r\n\r\n"
            . $body;

    # Retry once if a stale keep-alive socket closed
    for my $attempt (1, 2) {
        my $sock = $self->_connect;
        my $written = 0;
        my $ok = 1;
        while ($written < length($req)) {
            my $n = syswrite($sock, $req, length($req) - $written, $written);
            if (!defined $n || $n <= 0) { $ok = 0; last; }
            $written += $n;
        }
        if ($ok) {
            my ($status, $resp_body) = $self->_read_http_response($sock);
            if (defined $status) {
                my $data = eval { _dec_json($resp_body) };
                if (!$data || ref($data) ne 'HASH') {
                    die "Shop::DB::Informix: invalid JSON (HTTP $status): $resp_body\n";
                }
                if ($status >= 400 || !$data->{ok}) {
                    die "Shop::DB::Informix: " . ($data->{error} // "HTTP $status") . "\n";
                }
                return $data;
            }
        }
        $self->_close;
        die "Shop::DB::Informix: request failed on $method $path\n" if $attempt == 2;
    }
}

sub health {
    my ($self) = @_;
    my $ok = eval {
        my $res = $self->_request('GET', '/health');
        return $res->{ok} ? 1 : 0;
    };
    return $ok ? 1 : 0;
}

# Static Informix SPL Stored Procedure invocation (SP_ONLY runtime path)
sub sp_call {
    my ($self, $proc, @params) = @_;
    my $res = $self->_request('POST', '/sp/call', { proc => $proc, params => \@params });
    return $res->{rows} || [];
}

# Ad-hoc SQL endpoints (blocked with 403 SQL_INJECTION_BLOCKED when INFORMIX_SP_ONLY=1)
sub query {
    my ($self, $sql, @params) = @_;
    my $res = $self->_request('POST', '/query', { sql => $sql, params => \@params });
    return $res->{rows} || [];
}

sub exec {
    my ($self, $sql, @params) = @_;
    my $res = $self->_request('POST', '/query', { sql => $sql, params => \@params });
    return $res->{rowcount} // 0;
}

sub txn {
    my ($self, $code) = @_;
    my $begin = $self->_request('POST', '/tx/begin', {});
    my $tx_id = $begin->{tx_id};
    my $tx    = Shop::DB::Informix::Tx->new($self, $tx_id);
    my $want  = wantarray;
    my (@res, $res);
    my $ok = eval {
        if ($want) { @res = $code->($tx); }
        else       { $res = $code->($tx); }
        1;
    };
    if (!$ok) {
        my $err = $@;
        eval { $self->_request('POST', '/tx/rollback', { tx_id => $tx_id }); };
        die $err;
    }
    $self->_request('POST', '/tx/commit', { tx_id => $tx_id });
    return $want ? @res : $res;
}

# --- 100% Stored-Procedure-Only Runtime Repository Methods ---
# Zero ad-hoc SQL is emitted from Shop::DB::Informix at runtime.

sub ensure_v2_columns { 1 }

sub current_timestamp {
    my ($self) = @_;
    my $rows = $self->sp_call('SHOP_SP_CURRENT_TIMESTAMP');
    return (@$rows && defined $rows->[0]{ts}) ? $rows->[0]{ts} : '';
}

sub list_products {
    my ($self) = @_;
    return $self->sp_call('SHOP_SP_LIST_PRODUCTS');
}

sub get_product {
    my ($self, $sku) = @_;
    return undef unless defined $sku && length $sku;
    my $rows = $self->sp_call('SHOP_SP_GET_PRODUCT', "$sku");
    return @$rows ? $rows->[0] : undef;
}

sub upsert_product {
    my ($self, $p) = @_;
    die "upsert_product: sku required\n" unless defined $p->{sku} && length $p->{sku};
    $self->sp_call(
        'SHOP_SP_UPSERT_PRODUCT',
        "$p->{sku}",
        defined($p->{name})        ? "$p->{name}"        : undef,
        defined($p->{category})    ? "$p->{category}"    : undef,
        defined($p->{description}) ? "$p->{description}" : undef,
        defined($p->{ascii_art})   ? "$p->{ascii_art}"   : undef,
        defined($p->{price})       ? "$p->{price}"       : undef,
        defined($p->{stock})       ? int($p->{stock})    : undef,
        defined($p->{active})      ? int($p->{active})   : undef,
    );
    return 1;
}

sub decrement_product_stock {
    my ($self, $sku, $qty, $tx) = @_;
    my $runner = $tx // $self;
    my $rows = $runner->sp_call('SHOP_SP_DECREMENT_STOCK', "$sku", int($qty));
    return @$rows ? $rows->[0] : undef;
}

sub update_product_stock {
    my ($self, $sku, $stock) = @_;
    my $rows = $self->sp_call('SHOP_SP_UPDATE_PRODUCT_STOCK', "$sku", int($stock));
    return @$rows ? $rows->[0] : undef;
}

sub get_promo {
    my ($self, $code) = @_;
    return undef unless defined $code && length $code;
    my $rows = $self->sp_call('SHOP_SP_GET_PROMO', "$code");
    return @$rows ? $rows->[0] : undef;
}

sub get_user {
    my ($self, $fp) = @_;
    return undef unless defined $fp && length $fp;
    my $rows = $self->sp_call('SHOP_SP_GET_USER', "$fp");
    return @$rows ? $rows->[0] : undef;
}

sub upsert_user {
    my ($self, $u) = @_;
    my $fp = $u->{fingerprint} or die "upsert_user: fingerprint required\n";
    my $rows = $self->sp_call(
        'SHOP_SP_UPSERT_USER',
        "$fp",
        defined($u->{username})               ? "$u->{username}"               : undef,
        defined($u->{email})                  ? "$u->{email}"                  : undef,
        defined($u->{pubkey_type})            ? "$u->{pubkey_type}"            : undef,
        defined($u->{is_admin})               ? int($u->{is_admin})            : undef,
        defined($u->{stripe_customer_id})     ? "$u->{stripe_customer_id}"     : undef,
        defined($u->{default_payment_method}) ? "$u->{default_payment_method}" : undef,
        defined($u->{default_payment_last4})  ? "$u->{default_payment_last4}"  : undef,
    );
    return @$rows ? $rows->[0] : undef;
}

sub save_user_payment_method {
    my ($self, $fp, $pm_id, $last4, $stripe_customer_id) = @_;
    die "save_user_payment_method: fingerprint required\n" unless defined $fp && length $fp;
    my $rows = $self->sp_call(
        'SHOP_SP_SAVE_PAYMENT_METHOD',
        "$fp",
        defined($pm_id)              ? "$pm_id"              : '',
        defined($last4)              ? "$last4"              : '',
        defined($stripe_customer_id) ? "$stripe_customer_id" : undef,
    );
    return @$rows ? $rows->[0] : undef;
}

sub list_addresses {
    my ($self, $user_fp) = @_;
    return [] unless defined $user_fp && length $user_fp;
    return $self->sp_call('SHOP_SP_LIST_ADDRESSES', "$user_fp");
}

sub save_address {
    my ($self, $a) = @_;
    my $id = $a->{id} || sprintf('addr_%d_%06d', time(), int(rand(1_000_000)));
    my $rows = $self->sp_call(
        'SHOP_SP_SAVE_ADDRESS',
        "$id",
        "$a->{user_fp}",
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
    return @$rows ? $rows->[0] : { %$a, id => $id };
}

sub delete_address {
    my ($self, $id, $user_fp) = @_;
    $self->sp_call('SHOP_SP_DELETE_ADDRESS', "$id", "$user_fp");
    return 1;
}

sub create_order {
    my ($self, $ord, $items) = @_;
    my $order_id = $ord->{id} || sprintf('ORD-%d-%04d', time(), int(rand(10000)));
    $self->txn(sub {
        my ($tx) = @_;
        $tx->sp_call(
            'SHOP_SP_CREATE_ORDER',
            "$order_id",
            "$ord->{user_fp}",
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
            $tx->sp_call(
                'SHOP_SP_ADD_ORDER_ITEM',
                $item_id,
                "$order_id",
                "$it->{sku}",
                $it->{name} // $it->{sku},
                int($it->{qty}),
                "$it->{unit_price}",
                "$it->{line_total}",
            );
            $tx->sp_call('SHOP_SP_DECREMENT_STOCK', "$it->{sku}", int($it->{qty}));
        }
    });
    return $self->get_order($order_id);
}

sub list_orders {
    my ($self, $user_fp) = @_;
    return $self->sp_call('SHOP_SP_LIST_ORDERS', defined($user_fp) ? "$user_fp" : '');
}

sub list_orders_masked {
    my ($self, $user_fp) = @_;
    return $self->sp_call('SHOP_SP_LIST_ORDERS_MASKED', defined($user_fp) ? "$user_fp" : '');
}

sub get_order {
    my ($self, $order_id) = @_;
    return undef unless defined $order_id && length $order_id;
    my $rows = $self->sp_call('SHOP_SP_GET_ORDER', "$order_id");
    return undef unless @$rows;
    my $ord = $rows->[0];
    $ord->{items} = $self->sp_call('SHOP_SP_GET_ORDER_ITEMS', "$order_id");
    return $ord;
}

sub get_order_by_payment_ref {
    my ($self, $payment_ref) = @_;
    return undef unless defined $payment_ref && length $payment_ref;
    my $rows = $self->sp_call('SHOP_SP_GET_ORDER_BY_REF', "$payment_ref");
    return undef unless @$rows;
    return $self->get_order($rows->[0]{id});
}

sub update_order_status {
    my ($self, $order_id, $status) = @_;
    my $rows = $self->sp_call('SHOP_SP_UPDATE_ORDER_STATUS', "$order_id", "$status");
    return @$rows ? $rows->[0] : undef;
}

sub update_order_receipt {
    my ($self, $order_id, $receipt_hash, $receipt_sig) = @_;
    $self->sp_call(
        'SHOP_SP_UPDATE_ORDER_RECEIPT',
        "$order_id",
        $receipt_hash // '',
        $receipt_sig  // '',
    );
    return 1;
}

sub gmv_summary {
    my ($self) = @_;
    my $rows = $self->sp_call('SHOP_SP_GMV_SUMMARY');
    my $cnt  = @$rows ? int($rows->[0]{order_count} // 0) : 0;
    my $raw  = @$rows ? ($rows->[0]{total_gmv} // '0') : '0';
    my $sum  = MT::Decimal->new("$raw")->quantize(-2, MT::Decimal::ROUND_HALF_UP);
    return {
        order_count => $cnt,
        total_gmv   => "$sum",
    };
}

sub product_history {
    my ($self, $sku, $limit) = @_;
    $limit = 20 if !defined($limit) || $limit <= 0;
    return $self->sp_call('SHOP_SP_PRODUCT_HISTORY', "$sku", int($limit));
}

sub catalog_as_of {
    my ($self, $ts) = @_;
    return $self->sp_call('SHOP_SP_CATALOG_AS_OF', "$ts");
}

sub order_history {
    my ($self, $order_id) = @_;
    return $self->sp_call('SHOP_SP_ORDER_HISTORY', "$order_id");
}

sub category_olap {
    my ($self) = @_;
    return $self->sp_call('SHOP_SP_CATEGORY_OLAP');
}

# --- Logistics, Warehouses, Purchase Orders, Shipments, and Tax Nexus (SP_ONLY) ---

sub list_warehouses {
    my ($self) = @_;
    return $self->sp_call('SHOP_SP_LIST_WAREHOUSES');
}

sub list_warehouse_stock {
    my ($self, $wh_code) = @_;
    return $self->sp_call('SHOP_SP_LIST_WAREHOUSE_STOCK', defined($wh_code) ? "$wh_code" : '');
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

    my ($created, @created_lines);
    $self->txn(sub {
        my ($tx) = @_;
        my $rows = $tx->sp_call(
            'SHOP_SP_CREATE_PO',
            "$po_id",
            $po->{supplier}       // 'Unknown Supplier',
            $po->{warehouse_code} // 'DAL1',
            "$total_cost",
        );
        $created = @$rows ? $rows->[0] : { id => $po_id };
        my $idx = 0;
        for my $ln (@$lines) {
            $idx++;
            my $line_id = $ln->{id} || sprintf('%s-%02d', $po_id, $idx);
            my $lrows = $tx->sp_call(
                'SHOP_SP_ADD_PO_LINE',
                "$line_id",
                "$po_id",
                "$ln->{sku}",
                int($ln->{qty_ordered} // 1),
                '' . ($ln->{unit_cost} // '0.0000'),
            );
            push @created_lines, $lrows->[0] if @$lrows;
        }
    });
    $created->{lines} = \@created_lines;
    return $created;
}

sub list_pos {
    my ($self) = @_;
    return $self->sp_call('SHOP_SP_LIST_POS');
}

sub get_po_lines {
    my ($self, $po_id) = @_;
    return [] unless defined $po_id && length $po_id;
    return $self->sp_call('SHOP_SP_GET_PO_LINES', "$po_id");
}

sub receive_po_line {
    my ($self, $po_line_id, $qty) = @_;
    $qty = int($qty // 0);
    if (!defined $po_line_id || !length $po_line_id || $qty <= 0) {
        return { ok => 0, error => 'invalid po_line_id or qty' };
    }
    my $rows = $self->sp_call('SHOP_SP_RECEIVE_PO_LINE', "$po_line_id", $qty);
    return { ok => 0, error => "po_line '$po_line_id' not found" } unless @$rows;
    my $r = $rows->[0];
    return {
        ok             => 1,
        po_id          => $r->{po_id},
        po_line_id     => $r->{po_line_id},
        warehouse_code => $r->{warehouse_code},
        sku            => $r->{sku},
        qty_received   => int($r->{qty_received} // 0),
        new_stock      => int($r->{new_stock}    // 0),
        po_status      => $r->{po_status},
    };
}

sub create_shipment {
    my ($self, $s) = @_;
    $s ||= {};
    my $id = $s->{id} || sprintf('SHP-%d-%04d', time(), int(rand(10000)));
    my $rows = $self->sp_call(
        'SHOP_SP_CREATE_SHIPMENT',
        "$id",
        $s->{order_id}        // '',
        $s->{warehouse_code}  // 'DAL1',
        $s->{carrier}         // '',
        $s->{service}         // '',
        '' . ($s->{rate_amount} // '0.0000'),
        $s->{tracking_number} // '',
        $s->{label_url}       // '',
        $s->{status}          // 'PENDING',
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

    my $rows = $self->sp_call(
        'SHOP_SP_UPDATE_SHIPMENT',
        "$id",
        defined($status)   ? "$status"   : undef,
        defined($tracking) ? "$tracking" : undef,
        defined($label)    ? "$label"    : undef,
    );
    return @$rows ? $rows->[0] : undef;
}

sub get_shipment_by_order {
    my ($self, $order_id) = @_;
    return undef unless defined $order_id && length $order_id;
    my $rows = $self->sp_call('SHOP_SP_GET_SHIPMENT_BY_ORDER', "$order_id");
    return @$rows ? $rows->[0] : undef;
}

sub get_shipment_by_tracking {
    my ($self, $tracking) = @_;
    return undef unless defined $tracking && length $tracking;
    my $rows = $self->sp_call('SHOP_SP_GET_SHIPMENT_BY_TRACKING', "$tracking");
    return @$rows ? $rows->[0] : undef;
}

sub list_shipments {
    my ($self, $status) = @_;
    return $self->sp_call('SHOP_SP_LIST_SHIPMENTS', defined($status) ? "$status" : '');
}

sub get_tax_nexus {
    my ($self, $state) = @_;
    return undef unless defined $state && length $state;
    my $rows = $self->sp_call('SHOP_SP_GET_TAX_NEXUS', "$state");
    return @$rows ? $rows->[0] : undef;
}

sub list_tax_nexus {
    my ($self) = @_;
    return $self->sp_call('SHOP_SP_LIST_TAX_NEXUS');
}

sub tax_nexus_report {
    my ($self) = @_;
    return $self->sp_call('SHOP_SP_TAX_NEXUS_REPORT');
}

package Shop::DB::Informix::Tx;
use strict;
use warnings;

sub new {
    my ($class, $db, $tx_id) = @_;
    return bless { db => $db, tx_id => $tx_id }, $class;
}

sub sp_call {
    my ($self, $proc, @params) = @_;
    my $res = $self->{db}->_request('POST', '/tx/sp/call', {
        tx_id  => $self->{tx_id},
        proc   => $proc,
        params => \@params,
    });
    return $res->{rows} || [];
}

sub query {
    my ($self, $sql, @params) = @_;
    my $res = $self->{db}->_request('POST', '/tx/query', {
        tx_id  => $self->{tx_id},
        sql    => $sql,
        params => \@params,
    });
    return $res->{rows} || [];
}

sub exec {
    my ($self, $sql, @params) = @_;
    my $res = $self->{db}->_request('POST', '/tx/exec', {
        tx_id  => $self->{tx_id},
        sql    => $sql,
        params => \@params,
    });
    return $res->{rowcount} // 0;
}

1;
