package Shop::Webhook::Server;

use strict;
use warnings;
use Socket qw(
    AF_INET SOCK_STREAM SOL_SOCKET SO_REUSEADDR
    inet_aton pack_sockaddr_in unpack_sockaddr_in
);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Digest::SHA qw(hmac_sha256_hex);
use Shop::Domain::JSON qw(encode_json decode_json);
use MT::SharedHash;

# Non-blocking HTTP/1.1 ops, catalog, and webhook worker.
# Runs Shop::Web::App on mojolicious-mt (Mojo::Server::Daemon + Mojo::Reactor::MT
# + Mojo::MT::Accel) when Mojolicious is available, with a raw-socket fallback.
#
# Endpoints:
# - GET  /healthz         -> 200 OK {"ok":true,"engine":"mojolicious-mt","reactor":"Mojo::Reactor::MT","accel":true}
# - GET  /metrics         -> 200 OK Prometheus exposition text from Shop::Metrics
# - GET  /api/catalog     -> 200 OK JSON catalog from hot Inventory or DB
# - POST /webhooks/stripe -> constant-time HMAC-SHA256 verification, idempotency check,
#                            DB order status update to 'paid', and instant EventBus push
#                            to buyer's open SSH TUI session.
# - POST /webhooks/shippo -> HMAC-SHA256 verification, shipment/order status update,
#                            and instant EventBus push.

our $HAS_MOJO = eval {
    require Mojo::MT;
    require Mojo::IOLoop;
    require Mojo::Server::Daemon;
    require Shop::Web::App;
    1;
} ? 1 : 0;

sub prepare_for_freeze {
    return 0 unless $HAS_MOJO;
    if (eval { require Mojo::Server::MT; 1 }) {
        Mojo::Server::MT::_preload_core_modules();
        Mojo::Server::MT::_patch_for_freeze();
    }
    Mojo::MT::prepare_for_freeze();
    return 1;
}

sub new {
    my ($class, %opt) = @_;
    return bless {
        host                  => $opt{host}           // '127.0.0.1',
        port                  => defined $opt{port} ? int($opt{port}) : 8088,
        metrics               => $opt{metrics},
        db                    => $opt{db},
        event_bus             => $opt{event_bus},
        keydb                 => $opt{keydb},
        inventory             => $opt{inventory},
        webhook_secret        => $opt{webhook_secret}        // $ENV{STRIPE_WEBHOOK_SECRET} // 'whsec_test_secret',
        shippo_webhook_secret => $opt{shippo_webhook_secret} // $ENV{SHIPPO_WEBHOOK_SECRET} // '',
        tolerance_sec         => defined $opt{tolerance_sec} ? int($opt{tolerance_sec}) : 300,
        shutdown_cell         => $opt{shutdown_cell},
        idempotency           => $opt{idempotency}    || MT::SharedHash->new,
        http_engine           => $HAS_MOJO ? 'mojolicious-mt' : 'raw-socket',
        daemon                => undef,
        app                   => undef,
        ioloop                => undef,
        _beat_tid             => undef,
        listen_sock           => undef,
        conns                 => {},
    }, $class;
}

sub http_engine { $_[0]->{http_engine} }

sub _set_nonblock {
    my ($fh) = @_;
    my $flags = fcntl($fh, F_GETFL, 0);
    return unless defined $flags;
    fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
}

sub _const_eq {
    my ($a, $b) = @_;
    return 0 unless defined $a && defined $b;
    if (defined &Shop::SSH::Crypto::const_time_eq) {
        return Shop::SSH::Crypto::const_time_eq($a, $b) ? 1 : 0;
    }
    return 0 if length($a) != length($b);
    my $diff = 0;
    for my $i (0 .. length($a) - 1) {
        $diff |= ord(substr($a, $i, 1)) ^ ord(substr($b, $i, 1));
    }
    return $diff == 0 ? 1 : 0;
}

sub _hmac_sha256_hex {
    my ($data, $secret) = @_;
    # Prefer Tier-1 XS Shop::SSH::Crypto::hmac_sha256($key, $data) when available
    if (defined &Shop::SSH::Crypto::hmac_sha256) {
        my $raw = Shop::SSH::Crypto::hmac_sha256($secret, $data);
        return unpack('H*', $raw) if defined $raw && length($raw) == 32;
    }
    return hmac_sha256_hex($data, $secret);
}

sub sign_stripe_payload {
    my ($payload, $secret, $ts) = @_;
    if (defined $payload && !ref($payload) && $payload eq __PACKAGE__) {
        ($payload, $secret, $ts) = ($_[1], $_[2], $_[3]);
    }
    $ts //= time();
    my $sig = _hmac_sha256_hex("$ts.$payload", $secret);
    return "t=$ts,v1=$sig";
}

sub verify_stripe_signature {
    my ($payload, $sig_header, $secret, $tolerance_sec) = @_;
    if (defined $payload && !ref($payload) && $payload eq __PACKAGE__) {
        ($payload, $sig_header, $secret, $tolerance_sec) = ($_[1], $_[2], $_[3], $_[4]);
    }
    return 0 unless defined $payload && defined $sig_header && defined $secret && length($secret);
    $tolerance_sec = 300 unless defined $tolerance_sec;

    my ($ts, @v1_sigs);
    for my $part (split /\s*,\s*/, $sig_header) {
        my ($k, $v) = split /=/, $part, 2;
        next unless defined $k && defined $v;
        if ($k eq 't' && $v =~ /^\d+$/) {
            $ts = int($v);
        }
        elsif ($k eq 'v1' && $v =~ /^[0-9a-fA-F]{64}$/) {
            push @v1_sigs, lc($v);
        }
    }
    return 0 unless defined $ts && @v1_sigs;

    if ($tolerance_sec > 0 && abs(time() - $ts) > $tolerance_sec) {
        return 0;
    }

    my $expected = lc(_hmac_sha256_hex("$ts.$payload", $secret));
    for my $cand (@v1_sigs) {
        return 1 if _const_eq($expected, $cand);
    }
    return 0;
}

sub sign_shippo_payload {
    my ($payload, $secret) = @_;
    if (defined $payload && !ref($payload) && $payload eq __PACKAGE__) {
        ($payload, $secret) = ($_[1], $_[2]);
    }
    return lc(_hmac_sha256_hex($payload // '', $secret // ''));
}

sub verify_shippo_signature {
    my ($payload, $sig_header, $secret) = @_;
    if (defined $payload && !ref($payload) && $payload eq __PACKAGE__) {
        ($payload, $sig_header, $secret) = ($_[1], $_[2], $_[3]);
    }
    return 0 unless defined $payload && defined $sig_header && defined $secret && length($secret);
    my $cand = $sig_header;
    $cand =~ s/^\s*sha256=//i;
    $cand =~ s/^\s+|\s+$//g;
    return 0 unless $cand =~ /^[0-9a-fA-F]{64}$/;
    my $expected = lc(_hmac_sha256_hex($payload, $secret));
    return _const_eq($expected, lc($cand));
}

sub _map_shippo_status {
    my ($raw) = @_;
    my $st = uc($raw // '');
    return ('IN_TRANSIT',       'shipped')   if $st eq 'TRANSIT' || $st eq 'IN_TRANSIT';
    return ('OUT_FOR_DELIVERY', 'shipped')   if $st eq 'OUT_FOR_DELIVERY';
    return ('DELIVERED',        'delivered') if $st eq 'DELIVERED';
    return ('LABEL_CREATED',    undef)       if $st eq 'PRE_TRANSIT';
    return ('EXCEPTION',        undef)       if $st eq 'RETURNED' || $st eq 'FAILURE';
    return ($st || 'UNKNOWN',   undef);
}

sub _utc_ts {
    my ($epoch) = @_;
    $epoch = time() unless defined $epoch;
    my ($S, $M, $H, $d, $m, $y) = gmtime($epoch);
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d', $y + 1900, $m + 1, $d, $H, $M, $S);
}

sub _map_stripe_sub_status {
    my ($ev_type, $raw) = @_;
    return 'CANCELED' if ($ev_type // '') eq 'customer.subscription.deleted';
    return 'ACTIVE'   if ($ev_type // '') eq 'invoice.paid';
    my $st = lc($raw // 'active');
    return 'ACTIVE'   if $st eq 'active' || $st eq 'trialing';
    return 'PAUSED'   if $st eq 'paused';
    return 'PAST_DUE' if $st eq 'past_due';
    return 'CANCELED' if $st eq 'canceled' || $st eq 'cancelled' || $st eq 'unpaid' || $st eq 'incomplete_expired';
    return uc($st);
}

sub _handle_stripe_subscription_event {
    my ($ev, $db, $event_bus, $metrics) = @_;
    my $ev_type = $ev->{type} // '';
    return undef unless $ev_type eq 'invoice.paid'
        || $ev_type eq 'customer.subscription.updated'
        || $ev_type eq 'customer.subscription.deleted';

    my $event_id = $ev->{id} // '';
    my $obj = ($ev->{data} && ref($ev->{data}) eq 'HASH' && ref($ev->{data}{object}) eq 'HASH')
        ? $ev->{data}{object}
        : $ev;
    my $meta = ref($obj->{metadata}) eq 'HASH' ? $obj->{metadata} : {};

    my $user_fp   = $meta->{user_fp}   // $obj->{user_fp}   // '';
    my $tier_code = uc($meta->{tier_code} // $obj->{tier_code} // '');
    my $sub_id    = $meta->{subscription_id} // $meta->{sub_id} // $obj->{subscription_id} // '';
    my $stripe_sub_id = ($ev_type eq 'invoice.paid' ? ($obj->{subscription} // '') : ($obj->{id} // ''))
                     || ($obj->{stripe_sub_id} // '');

    my $mapped_status = _map_stripe_sub_status($ev_type, $obj->{status});

    my ($sub, $updated_membership);
    if ($db) {
        if (length($sub_id) && $db->can('get_subscription')) {
            $sub = eval { $db->get_subscription($sub_id) };
        }
        if (!$sub && length($stripe_sub_id) && $db->can('list_subscriptions')) {
            my $rows = eval { $db->list_subscriptions($user_fp) } || [];
            for my $row (@$rows) {
                if (($row->{stripe_sub_id} // '') eq $stripe_sub_id) {
                    $sub = $row;
                    last;
                }
            }
        }
        if ($sub && !length($user_fp)) {
            $user_fp = $sub->{user_fp} // '';
        }

        if ($sub && $db->can('update_subscription')) {
            my %patch = (status => $mapped_status);
            if ($ev_type eq 'invoice.paid' && defined $obj->{period_end} && $obj->{period_end} =~ /^\d+$/) {
                $patch{next_bill_at} = _utc_ts(int($obj->{period_end}));
            }
            if (defined $meta->{order_id} && length $meta->{order_id}) {
                $patch{last_order_id} = $meta->{order_id};
            }
            eval { $db->update_subscription($sub->{id}, %patch); };
        }

        if (length($user_fp) && $db->can('upsert_membership')) {
            my $cur = $db->can('get_membership') ? eval { $db->get_membership($user_fp) } : undef;
            my $matches_mem = length($tier_code)
                || ($cur && (!length($stripe_sub_id)
                    || !length($cur->{stripe_sub_id} // '')
                    || ($cur->{stripe_sub_id} // '') eq $stripe_sub_id));
            if ($matches_mem) {
                my $eff_tier = length($tier_code)
                    ? $tier_code
                    : ($cur ? ($cur->{tier_code} // 'PRO') : 'PRO');
                my $renews_at = '';
                if ($mapped_status eq 'ACTIVE') {
                    my $pe = $obj->{current_period_end} // $obj->{period_end};
                    $renews_at = (defined $pe && $pe =~ /^\d+$/)
                        ? _utc_ts(int($pe))
                        : _utc_ts(time() + 30 * 86400);
                }
                elsif ($cur) {
                    $renews_at = $cur->{renews_at} // '';
                }
                eval {
                    $db->upsert_membership({
                        user_fp       => $user_fp,
                        tier_code     => $eff_tier,
                        status        => $mapped_status,
                        stripe_sub_id => length($stripe_sub_id) ? $stripe_sub_id : ($cur ? ($cur->{stripe_sub_id} // '') : ''),
                        renews_at     => $renews_at,
                    });
                };
                $updated_membership = {
                    user_fp   => $user_fp,
                    tier_code => $eff_tier,
                    status    => $mapped_status,
                };
            }
        }
    }

    $metrics->inc('webhooks_processed_total', 1) if $metrics;

    if ($updated_membership && $event_bus) {
        $event_bus->send_to_user($user_fp, {
            type      => 'membership_updated',
            user_fp   => $user_fp,
            tier_code => $updated_membership->{tier_code},
            status    => $mapped_status,
            event_id  => $event_id,
            ts        => time(),
        });
    }

    if ($sub && $event_bus) {
        if ($ev_type eq 'invoice.paid') {
            my $total = defined $obj->{amount_paid}
                ? sprintf('%.2f', int($obj->{amount_paid}) / 100)
                : '' . ($sub->{unit_price} // '0.00');
            $event_bus->send_to_user($sub->{user_fp}, {
                type     => 'subscription_renewed',
                sub_id   => $sub->{id},
                order_id => $meta->{order_id} // ($sub->{last_order_id} // ''),
                sku      => $sub->{sku} // '',
                total    => $total,
                status   => $mapped_status,
                event_id => $event_id,
                ts       => time(),
            });
        }
        else {
            $event_bus->send_to_user($sub->{user_fp}, {
                type     => 'subscription_updated',
                sub_id   => $sub->{id},
                sku      => $sub->{sku} // '',
                status   => $mapped_status,
                event_id => $event_id,
                ts       => time(),
            });
        }
    }

    return {
        event_type => $ev_type,
        status     => $mapped_status,
        user_fp    => $user_fp,
        tier_code  => $updated_membership ? $updated_membership->{tier_code} : $tier_code,
        sub_id     => $sub ? $sub->{id} : $sub_id,
    };
}

sub listen {
    my ($self) = @_;

    if ($self->{http_engine} eq 'mojolicious-mt') {
        return $self->{daemon} if $self->{daemon};

        my $loop = Mojo::IOLoop->singleton;
        my $app  = Shop::Web::App->new(
            metrics               => $self->{metrics},
            db                    => $self->{db},
            event_bus             => $self->{event_bus},
            keydb                 => $self->{keydb},
            inventory             => $self->{inventory},
            webhook_secret        => $self->{webhook_secret},
            shippo_webhook_secret => $self->{shippo_webhook_secret},
            tolerance_sec         => $self->{tolerance_sec},
            idempotency           => $self->{idempotency},
            http_engine           => $self->{http_engine},
        );

        my $listen_url = $self->{port} > 0
            ? "http://$self->{host}:$self->{port}"
            : "http://$self->{host}";

        my $daemon = Mojo::Server::Daemon->new(
            app    => $app,
            ioloop => $loop,
            listen => [$listen_url],
            silent => 1,
        );
        $daemon->start;

        my $ports = $daemon->ports;
        if ($ports && @$ports && defined $ports->[0]) {
            $self->{port} = int($ports->[0]);
        }

        $self->{ioloop} = $loop;
        $self->{app}    = $app;
        $self->{daemon} = $daemon;
        return $daemon;
    }

    return $self->{listen_sock} if $self->{listen_sock};

    socket(my $sock, AF_INET, SOCK_STREAM, 0)
        or die "Shop::Webhook::Server: socket() failed: $!\n";
    setsockopt($sock, SOL_SOCKET, SO_REUSEADDR, pack('l', 1));
    my $ip = inet_aton($self->{host})
        or die "Shop::Webhook::Server: invalid host '$self->{host}'\n";
    bind($sock, pack_sockaddr_in($self->{port}, $ip))
        or die "Shop::Webhook::Server: bind $self->{host}:$self->{port} failed: $!\n";
    CORE::listen($sock, 128)
        or die "Shop::Webhook::Server: listen() failed: $!\n";

    binmode($sock);
    _set_nonblock($sock);

    my ($actual_port) = unpack_sockaddr_in(getsockname($sock));
    $self->{listen_sock} = $sock;
    $self->{port}        = $actual_port;
    return $sock;
}

sub start { $_[0]->listen }

sub port { $_[0]->{port} }
sub host { $_[0]->{host} }

sub stop {
    my ($self) = @_;
    if ($self->{http_engine} eq 'mojolicious-mt') {
        if ($self->{ioloop} && defined $self->{_beat_tid}) {
            eval { $self->{ioloop}->remove($self->{_beat_tid}) };
            $self->{_beat_tid} = undef;
        }
        if ($self->{daemon}) {
            eval { $self->{daemon}->stop };
            $self->{daemon} = undef;
        }
        return 1;
    }

    for my $fn (keys %{ $self->{conns} }) {
        my $c = delete $self->{conns}{$fn};
        CORE::close($c->{sock}) if $c && $c->{sock};
    }
    if ($self->{listen_sock}) {
        CORE::close($self->{listen_sock});
        $self->{listen_sock} = undef;
    }
    return 1;
}

sub close { $_[0]->stop }

sub _http_response {
    my ($status, $reason, $ctype, $body) = @_;
    $body //= '';
    return "HTTP/1.1 $status $reason\r\n"
         . "Content-Type: $ctype\r\n"
         . "Content-Length: " . length($body) . "\r\n"
         . "Connection: close\r\n"
         . "\r\n"
         . $body;
}

sub _json_response {
    my ($status, $reason, $data) = @_;
    my $body = encode_json($data) . "\n";
    return _http_response($status, $reason, 'application/json', $body);
}

sub _check_and_mark_idempotent {
    my ($self, $event_id) = @_;
    return 1 unless defined $event_id && length $event_id;

    # Check in-process MT::SharedHash first (zero network)
    if (defined $self->{idempotency}->get($event_id)) {
        return 0;
    }

    # Also check KeyDB if connected
    if ($self->{keydb}) {
        my $seen = eval { $self->{keydb}->get("wh:$event_id") };
        if (defined $seen && length $seen) {
            $self->{idempotency}->set($event_id, '1');
            return 0;
        }
        eval { $self->{keydb}->set("wh:$event_id", '1', 86400); };
    }

    $self->{idempotency}->set($event_id, '1');
    return 1;
}

sub handle_request {
    my ($self, $method, $path, $headers, $body) = @_;
    $method = uc($method // 'GET');
    $path   =~ s/\?.*$// if defined $path;

    if ($method eq 'GET' && $path eq '/healthz') {
        return _json_response(200, 'OK', { ok => \1 });
    }

    if ($method eq 'GET' && $path eq '/metrics') {
        my $text = $self->{metrics} ? $self->{metrics}->prometheus_text : '';
        return _http_response(200, 'OK', 'text/plain; version=0.0.4; charset=utf-8', $text);
    }

    if ($method eq 'GET' && $path eq '/api/memberships') {
        my @tiers;
        if ($self->{db} && $self->{db}->can('list_membership_tiers')) {
            my $rows = eval { $self->{db}->list_membership_tiers } || [];
            for my $t (@$rows) {
                push @tiers, {
                    code                 => $t->{code} // '',
                    name                 => $t->{name} // '',
                    monthly_price        => defined $t->{monthly_price} ? "$t->{monthly_price}" : '0.00',
                    discount_pct         => defined $t->{discount_pct}  ? "$t->{discount_pct}"  : '0.00',
                    free_shipping        => $t->{free_shipping}        ? \1 : \0,
                    priority_fulfillment => $t->{priority_fulfillment} ? \1 : \0,
                    active               => (!defined $t->{active} || $t->{active}) ? \1 : \0,
                };
            }
        }
        return _json_response(200, 'OK', {
            ok    => \1,
            count => scalar(@tiers),
            tiers => \@tiers,
        });
    }

    if ($method eq 'POST' && $path eq '/webhooks/stripe') {
        my $sig_hdr = $headers->{'stripe-signature'} // '';
        if (!verify_stripe_signature($body, $sig_hdr, $self->{webhook_secret}, $self->{tolerance_sec})) {
            return _json_response(400, 'Bad Request', { ok => \0, error => 'Invalid Stripe-Signature' });
        }

        my $ev = eval { decode_json($body) };
        if (!$ev || ref($ev) ne 'HASH') {
            return _json_response(400, 'Bad Request', { ok => \0, error => 'Invalid JSON payload' });
        }

        my $event_id = $ev->{id};
        if (!$self->_check_and_mark_idempotent($event_id)) {
            return _json_response(200, 'OK', { ok => \1, duplicate => \1 });
        }

        if (my $sub_res = _handle_stripe_subscription_event($ev, $self->{db}, $self->{event_bus}, $self->{metrics})) {
            return _json_response(200, 'OK', {
                ok => \1,
                %$sub_res,
            });
        }

        my $obj = ($ev->{data} && ref($ev->{data}) eq 'HASH' && ref($ev->{data}{object}) eq 'HASH')
            ? $ev->{data}{object}
            : $ev;

        my $order_id = $obj->{client_reference_id}
                    // (ref($obj->{metadata}) eq 'HASH' ? $obj->{metadata}{order_id} : undef)
                    // $obj->{order_id};

        my $order;
        if ($self->{db}) {
            if (defined $order_id && length $order_id) {
                $order = eval { $self->{db}->get_order($order_id) };
            }
            if (!$order && defined $obj->{id} && length $obj->{id}) {
                $order = eval { $self->{db}->get_order_by_payment_ref($obj->{id}) };
            }
            if (!$order && defined $obj->{payment_intent} && length $obj->{payment_intent}) {
                $order = eval { $self->{db}->get_order_by_payment_ref($obj->{payment_intent}) };
            }

            if ($order) {
                eval { $self->{db}->update_order_status($order->{id}, 'paid'); };
            }
        }

        $self->{metrics}->inc('webhooks_processed_total', 1) if $self->{metrics};

        if ($order && $self->{event_bus}) {
            $self->{event_bus}->send_to_user($order->{user_fp}, {
                type         => 'payment_confirmed',
                order_id     => $order->{id},
                order_number => $order->{id},
                total        => '' . ($order->{total} // '0.00'),
                status       => 'paid',
                event_id     => $event_id // '',
                ts           => time(),
            });
        }

        return _json_response(200, 'OK', {
            ok       => \1,
            order_id => $order ? $order->{id} : ($order_id // ''),
            status   => $order ? 'paid' : 'ignored',
        });
    }

    if ($method eq 'POST' && $path eq '/webhooks/shippo') {
        my $shippo_secret = $self->{shippo_webhook_secret} // '';
        if (length($shippo_secret)) {
            my $sig_hdr = $headers->{'x-shippo-signature'} // '';
            if (!verify_shippo_signature($body, $sig_hdr, $shippo_secret)) {
                return _json_response(400, 'Bad Request', { ok => \0, error => 'Invalid X-Shippo-Signature' });
            }
        }

        my $ev = eval { decode_json($body) };
        if (!$ev || ref($ev) ne 'HASH') {
            return _json_response(400, 'Bad Request', { ok => \0, error => 'Invalid JSON payload' });
        }

        my $event_id = $ev->{id} // $ev->{event_id};
        if (defined $event_id && length($event_id) && !$self->_check_and_mark_idempotent("shippo:$event_id")) {
            return _json_response(200, 'OK', { ok => \1, duplicate => \1 });
        }

        my $data = (ref($ev->{data}) eq 'HASH') ? $ev->{data} : $ev;
        my $tracking = $data->{tracking_number} // '';
        my $raw_status = (ref($data->{tracking_status}) eq 'HASH' ? $data->{tracking_status}{status} : undef)
                      // $data->{status}
                      // '';
        my ($mapped_status, $order_status) = _map_shippo_status($raw_status);

        my ($shipment, $order);
        if ($self->{db} && length($tracking) && $self->{db}->can('get_shipment_by_tracking')) {
            $shipment = eval { $self->{db}->get_shipment_by_tracking($tracking) };
            if ($shipment && ref($shipment) eq 'HASH') {
                if ($self->{db}->can('update_shipment')) {
                    eval {
                        $self->{db}->update_shipment(
                            $shipment->{id},
                            status          => $mapped_status,
                            tracking_number => $tracking,
                        );
                    };
                }
                if (defined $order_status && defined $shipment->{order_id} && length $shipment->{order_id}) {
                    eval { $self->{db}->update_order_status($shipment->{order_id}, $order_status); };
                }
                if (defined $shipment->{order_id} && length $shipment->{order_id}) {
                    $order = eval { $self->{db}->get_order($shipment->{order_id}) };
                }
            }
        }

        $self->{metrics}->inc('webhooks_processed_total', 1) if $self->{metrics};

        if ($shipment && $order && $self->{event_bus}) {
            $self->{event_bus}->send_to_user($order->{user_fp}, {
                type            => 'shipment_updated',
                order_id        => $shipment->{order_id},
                shipment_id     => $shipment->{id},
                tracking_number => $tracking,
                status          => $mapped_status,
                carrier         => $shipment->{carrier}        // '',
                warehouse_code  => $shipment->{warehouse_code} // '',
                ts              => time(),
            });
        }

        return _json_response(200, 'OK', {
            ok              => \1,
            order_id        => $shipment ? ($shipment->{order_id} // '') : '',
            tracking_number => $tracking,
            status          => $mapped_status,
            matched         => $shipment ? \1 : \0,
        });
    }

    return _json_response(404, 'Not Found', { ok => \0, error => 'Not found' });
}

sub _close_conn {
    my ($self, $fn) = @_;
    my $c = delete $self->{conns}{$fn};
    return unless $c;
    CORE::close($c->{sock}) if $c->{sock};
}

sub _try_parse_and_respond {
    my ($self, $fn) = @_;
    my $c = $self->{conns}{$fn} or return;
    return if length($c->{wbuf});

    my $hdr_end = index($c->{rbuf}, "\r\n\r\n");
    return if $hdr_end < 0;

    my $hdr_raw = substr($c->{rbuf}, 0, $hdr_end);
    my ($req_line, @hdr_lines) = split /\r\n/, $hdr_raw;
    my ($method, $path) = ($req_line // '') =~ /^([A-Z]+)\s+(\S+)\s+HTTP\/\d+\.\d+/;
    if (!$method) {
        $c->{wbuf} = _json_response(400, 'Bad Request', { ok => \0, error => 'Malformed HTTP request' });
        return;
    }

    my %headers;
    for my $line (@hdr_lines) {
        my ($k, $v) = split /:\s*/, $line, 2;
        $headers{lc($k)} = $v if defined $k && defined $v;
    }

    my $clen = int($headers{'content-length'} // 0);
    my $body_start = $hdr_end + 4;
    return if length($c->{rbuf}) < $body_start + $clen;

    my $body = $clen > 0 ? substr($c->{rbuf}, $body_start, $clen) : '';
    $c->{wbuf} = $self->handle_request($method, $path, \%headers, $body);
}

sub tick {
    my ($self, $timeout) = @_;
    $timeout = 0.05 unless defined $timeout;

    if ($self->{http_engine} eq 'mojolicious-mt') {
        $self->listen unless $self->{daemon};
        my $loop = $self->{ioloop};
        my $tid;
        if ($timeout > 0) {
            $tid = $loop->timer($timeout => sub { $loop->stop });
        }
        $loop->one_tick;
        $loop->remove($tid) if defined $tid;
        return 1;
    }

    $self->listen unless $self->{listen_sock};

    my $rin = '';
    my $lfn = fileno($self->{listen_sock});
    vec($rin, $lfn, 1) = 1 if defined $lfn;
    for my $fn (keys %{ $self->{conns} }) {
        vec($rin, $fn, 1) = 1;
    }

    my $nready = select(my $rout = $rin, undef, undef, $timeout);
    if (defined $nready && $nready > 0) {
        if (defined $lfn && vec($rout, $lfn, 1)) {
            while (accept(my $cli, $self->{listen_sock})) {
                binmode($cli);
                _set_nonblock($cli);
                my $fn = fileno($cli);
                $self->{conns}{$fn} = {
                    sock       => $cli,
                    rbuf       => '',
                    wbuf       => '',
                    created_at => time(),
                };
            }
        }
        for my $fn (keys %{ $self->{conns} }) {
            next unless vec($rout, $fn, 1);
            my $c = $self->{conns}{$fn} or next;
            my $buf;
            my $n = sysread($c->{sock}, $buf, 16384);
            if (!defined $n) {
                next if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
                $self->_close_conn($fn);
                next;
            }
            if ($n == 0) {
                $self->_close_conn($fn);
                next;
            }
            $c->{rbuf} .= $buf;
            if (length($c->{rbuf}) > 1_048_576) {
                $c->{wbuf} = _json_response(413, 'Payload Too Large', { ok => \0, error => 'Payload too large' });
            }
            else {
                $self->_try_parse_and_respond($fn);
            }
        }
    }

    # Flush any pending responses
    my $now = time();
    for my $fn (keys %{ $self->{conns} }) {
        my $c = $self->{conns}{$fn} or next;
        if (length($c->{wbuf})) {
            my $n = syswrite($c->{sock}, $c->{wbuf});
            if (!defined $n) {
                next if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
                $self->_close_conn($fn);
                next;
            }
            substr($c->{wbuf}, 0, $n, '');
            if (length($c->{wbuf}) == 0) {
                $self->_close_conn($fn);
            }
        }
        elsif ($now - $c->{created_at} > 10) {
            $self->_close_conn($fn);
        }
    }

    return 1;
}

sub run {
    my ($self) = @_;
    $self->listen;
    my $shutdown = $self->{shutdown_cell};

    if ($self->{http_engine} eq 'mojolicious-mt') {
        my $loop = $self->{ioloop};
        my $tid = $loop->recurring(
            0.05 => sub {
                MT::Supervisor::beat() if defined &MT::Supervisor::beat;
                if ($shutdown && $shutdown->get) {
                    $self->stop;
                    $loop->stop;
                }
            }
        );
        $self->{_beat_tid} = $tid;
        MT::Supervisor::beat() if defined &MT::Supervisor::beat;
        if ($shutdown && $shutdown->get) {
            $self->stop;
            return 1;
        }
        $loop->start;
        $loop->remove($tid) if defined $tid;
        $self->{_beat_tid} = undef;
        $self->stop;
        return 1;
    }

    while (!$shutdown || !$shutdown->get) {
        MT::Supervisor::beat() if defined &MT::Supervisor::beat;
        $self->tick(0.05);
    }
    $self->stop;
    return 1;
}

1;
