package Shop::Web::App;

use Mojo::Base 'Mojolicious';

use Mojo::IOLoop;
use Mojo::JSON qw(decode_json);
use Mojo::MT   qw(HAS_MT_ACCEL);
use Mojo::Reactor;
use Shop::Webhook::Server;

has 'metrics';
has 'db';
has 'event_bus';
has 'keydb';
has 'inventory';
has 'webhook_secret'        => sub { $ENV{STRIPE_WEBHOOK_SECRET} // 'whsec_test_secret' };
has 'shippo_webhook_secret' => sub { $ENV{SHIPPO_WEBHOOK_SECRET} // '' };
has 'tolerance_sec'         => 300;
has 'idempotency';
has 'http_engine'           => 'mojolicious-mt';

sub startup {
    my ($self) = @_;

    $self->secrets(['perl5-mt-shop-ops']);
    $self->log->level($ENV{MOJO_LOG_LEVEL} || 'error');

    my $r = $self->routes;

    $r->get('/healthz' => sub {
        my ($c) = @_;
        my $reactor_class = ref(Mojo::IOLoop->singleton->reactor)
            || Mojo::Reactor->detect
            || 'unknown';
        $c->render(json => {
            ok      => Mojo::JSON::true,
            engine  => $self->http_engine,
            reactor => $reactor_class,
            accel   => HAS_MT_ACCEL ? Mojo::JSON::true : Mojo::JSON::false,
        });
    });

    $r->get('/metrics' => sub {
        my ($c) = @_;
        my $text = $self->metrics ? $self->metrics->prometheus_text : '';
        $c->res->headers->content_type('text/plain; version=0.0.4; charset=utf-8');
        $c->render(text => $text);
    });

    $r->get('/api/catalog' => sub {
        my ($c) = @_;
        my $cat = $c->param('category');
        my $q   = $c->param('q') // $c->param('query');

        my $items = [];
        if (my $inv = $self->inventory) {
            $items = $inv->list_catalog(
                (defined $cat && length $cat ? (category => $cat) : ()),
                (defined $q   && length $q   ? (query    => $q)   : ()),
            );
        }
        elsif (my $db = $self->db) {
            my $all = eval { $db->list_products } || [];
            for my $p (@$all) {
                next if defined $p->{active} && !$p->{active};
                next if defined $cat && length $cat && lc($cat) ne 'all'
                    && lc($p->{category} // '') ne lc($cat);
                if (defined $q && length $q) {
                    my $hay = lc(join(' ', map { $_ // '' } @{$p}{qw(sku name category description)}));
                    next if index($hay, lc($q)) < 0;
                }
                push @$items, {
                    sku         => $p->{sku}         // '',
                    name        => $p->{name}        // '',
                    category    => $p->{category}    // 'General',
                    description => $p->{description} // '',
                    price       => defined $p->{price} ? "$p->{price}" : '0.00',
                    stock       => int($p->{stock} // 0),
                    active      => defined $p->{active} ? int($p->{active}) : 1,
                };
            }
        }

        $c->render(json => {
            ok    => Mojo::JSON::true,
            count => scalar(@$items),
            items => $items,
        });
    });

    $r->get('/api/memberships' => sub {
        my ($c) = @_;
        my @tiers;
        if (my $db = $self->db) {
            if ($db->can('list_membership_tiers')) {
                my $rows = eval { $db->list_membership_tiers } || [];
                for my $t (@$rows) {
                    push @tiers, {
                        code                 => $t->{code} // '',
                        name                 => $t->{name} // '',
                        monthly_price        => defined $t->{monthly_price} ? "$t->{monthly_price}" : '0.00',
                        discount_pct         => defined $t->{discount_pct}  ? "$t->{discount_pct}"  : '0.00',
                        free_shipping        => $t->{free_shipping}        ? Mojo::JSON::true : Mojo::JSON::false,
                        priority_fulfillment => $t->{priority_fulfillment} ? Mojo::JSON::true : Mojo::JSON::false,
                        active               => (!defined $t->{active} || $t->{active}) ? Mojo::JSON::true : Mojo::JSON::false,
                    };
                }
            }
        }
        $c->render(json => {
            ok    => Mojo::JSON::true,
            count => scalar(@tiers),
            tiers => \@tiers,
        });
    });

    $r->post('/webhooks/stripe' => sub {
        my ($c) = @_;
        my $body    = $c->req->body // '';
        my $sig_hdr = $c->req->headers->header('Stripe-Signature') // '';

        if (!Shop::Webhook::Server::verify_stripe_signature(
            $body, $sig_hdr, $self->webhook_secret, $self->tolerance_sec
        )) {
            return $c->render(
                status => 400,
                json   => { ok => Mojo::JSON::false, error => 'Invalid Stripe-Signature' },
            );
        }

        my $ev = eval { decode_json($body) };
        if (!$ev || ref($ev) ne 'HASH') {
            return $c->render(
                status => 400,
                json   => { ok => Mojo::JSON::false, error => 'Invalid JSON payload' },
            );
        }

        my $event_id = $ev->{id};
        if (!$self->_check_and_mark_idempotent($event_id)) {
            return $c->render(json => { ok => Mojo::JSON::true, duplicate => Mojo::JSON::true });
        }

        if (my $sub_res = Shop::Webhook::Server::_handle_stripe_subscription_event(
            $ev, $self->db, $self->event_bus, $self->metrics
        )) {
            return $c->render(json => {
                ok => Mojo::JSON::true,
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
        if (my $db = $self->db) {
            if (defined $order_id && length $order_id) {
                $order = eval { $db->get_order($order_id) };
            }
            if (!$order && defined $obj->{id} && length $obj->{id}) {
                $order = eval { $db->get_order_by_payment_ref($obj->{id}) };
            }
            if (!$order && defined $obj->{payment_intent} && length $obj->{payment_intent}) {
                $order = eval { $db->get_order_by_payment_ref($obj->{payment_intent}) };
            }
            if ($order) {
                eval { $db->update_order_status($order->{id}, 'paid'); };
            }
        }

        $self->metrics->inc('webhooks_processed_total', 1) if $self->metrics;

        if ($order && $self->event_bus) {
            $self->event_bus->send_to_user($order->{user_fp}, {
                type         => 'payment_confirmed',
                order_id     => $order->{id},
                order_number => $order->{id},
                total        => '' . ($order->{total} // '0.00'),
                status       => 'paid',
                event_id     => $event_id // '',
                ts           => time(),
            });
        }

        return $c->render(json => {
            ok       => Mojo::JSON::true,
            order_id => $order ? $order->{id} : ($order_id // ''),
            status   => $order ? 'paid' : 'ignored',
        });
    });

    $r->post('/webhooks/shippo' => sub {
        my ($c) = @_;
        my $body          = $c->req->body // '';
        my $shippo_secret = $self->shippo_webhook_secret // '';

        if (length($shippo_secret)) {
            my $sig_hdr = $c->req->headers->header('X-Shippo-Signature') // '';
            if (!Shop::Webhook::Server::verify_shippo_signature($body, $sig_hdr, $shippo_secret)) {
                return $c->render(
                    status => 400,
                    json   => { ok => Mojo::JSON::false, error => 'Invalid X-Shippo-Signature' },
                );
            }
        }

        my $ev = eval { decode_json($body) };
        if (!$ev || ref($ev) ne 'HASH') {
            return $c->render(
                status => 400,
                json   => { ok => Mojo::JSON::false, error => 'Invalid JSON payload' },
            );
        }

        my $event_id = $ev->{id} // $ev->{event_id};
        if (defined $event_id && length($event_id) && !$self->_check_and_mark_idempotent("shippo:$event_id")) {
            return $c->render(json => { ok => Mojo::JSON::true, duplicate => Mojo::JSON::true });
        }

        my $data       = (ref($ev->{data}) eq 'HASH') ? $ev->{data} : $ev;
        my $tracking   = $data->{tracking_number} // '';
        my $raw_status = (ref($data->{tracking_status}) eq 'HASH' ? $data->{tracking_status}{status} : undef)
                      // $data->{status}
                      // '';
        my ($mapped_status, $order_status) = Shop::Webhook::Server::_map_shippo_status($raw_status);

        my ($shipment, $order);
        if (my $db = $self->db) {
            if (length($tracking) && $db->can('get_shipment_by_tracking')) {
                $shipment = eval { $db->get_shipment_by_tracking($tracking) };
                if ($shipment && ref($shipment) eq 'HASH') {
                    if ($db->can('update_shipment')) {
                        eval {
                            $db->update_shipment(
                                $shipment->{id},
                                status          => $mapped_status,
                                tracking_number => $tracking,
                            );
                        };
                    }
                    if (defined $order_status && defined $shipment->{order_id} && length $shipment->{order_id}) {
                        eval { $db->update_order_status($shipment->{order_id}, $order_status); };
                    }
                    if (defined $shipment->{order_id} && length $shipment->{order_id}) {
                        $order = eval { $db->get_order($shipment->{order_id}) };
                    }
                }
            }
        }

        $self->metrics->inc('webhooks_processed_total', 1) if $self->metrics;

        if ($shipment && $order && $self->event_bus) {
            $self->event_bus->send_to_user($order->{user_fp}, {
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

        return $c->render(json => {
            ok              => Mojo::JSON::true,
            order_id        => $shipment ? ($shipment->{order_id} // '') : '',
            tracking_number => $tracking,
            status          => $mapped_status,
            matched         => $shipment ? Mojo::JSON::true : Mojo::JSON::false,
        });
    });

    $r->any('/*whatever' => { whatever => '' } => sub {
        my ($c) = @_;
        $c->render(status => 404, json => { ok => Mojo::JSON::false, error => 'Not found' });
    });
}

sub _check_and_mark_idempotent {
    my ($self, $event_id) = @_;
    return 1 unless defined $event_id && length $event_id;

    my $idem = $self->idempotency;
    if ($idem && defined $idem->get($event_id)) {
        return 0;
    }

    if (my $kdb = $self->keydb) {
        my $seen = eval { $kdb->get("wh:$event_id") };
        if (defined $seen && length $seen) {
            Shop::Webhook::Server::_mark_idempotent_local($idem, $event_id) if $idem;
            return 0;
        }
        eval { $kdb->set("wh:$event_id", '1', 86400); };
    }

    Shop::Webhook::Server::_mark_idempotent_local($idem, $event_id) if $idem;
    return 1;
}

1;
