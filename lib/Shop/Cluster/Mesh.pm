package Shop::Cluster::Mesh;

use strict;
use warnings;
use IO::Socket::INET;
use IO::Poll qw(POLLIN POLLOUT POLLHUP POLLERR POLLNVAL);
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Shop::Domain::JSON ();
use Shop::Cluster::Wavefunction;

# Cooperative cluster mesh bus over KeyDB plus a raw L4 TCP splice relay.
# Coordinates node membership, deterministic wavefunction stepping (no wall-clock),
# peer coherence checks, remote DoS ban sync, and zero-decryption TCP forwarding.

use constant RELAY_BUF_SIZE => 8192;
use constant DEFAULT_TTL    => 10;

sub new {
    my ($class, %opt) = @_;
    my $node_id      = $opt{node_id}      // 'node-1';
    my $host         = $opt{host}         // '127.0.0.1';
    my $port         = int($opt{port}     // 2222);
    my $max_sessions = int($opt{max_sessions} // 1000);
    $max_sessions    = 1 if $max_sessions < 1;

    my $wave = Shop::Cluster::Wavefunction->new(
        nodes      => [$node_id],
        step       => int($opt{step} // 0),
        dt         => $opt{dt},
        coupling   => $opt{coupling},
        load_alpha => $opt{load_alpha},
    );

    my $self_node = {
        id     => $node_id,
        host   => $host,
        port   => $port,
        active => 0,
        max    => $max_sessions,
        load   => 0.0,
        digest => $wave->state_digest,
        step   => $wave->step,
    };

    return bless {
        node_id      => $node_id,
        host         => $host,
        port         => $port,
        keydb        => $opt{keydb},
        blackhole    => $opt{blackhole},
        metrics      => $opt{metrics},
        max_sessions => $max_sessions,
        node_ttl     => int($opt{node_ttl} // DEFAULT_TTL),
        wave         => $wave,
        peers        => { $node_id => $self_node },
        last_loads   => { $node_id => 0.0 },
        coherence_ok => 1,
        registered   => 0,
    }, $class;
}

sub wavefunction { return $_[0]->{wave}; }
sub node_id      { return $_[0]->{node_id}; }

sub _keydb_key {
    my ($kdb, $suffix) = @_;
    return $kdb->can('_k') ? $kdb->_k($suffix) : $suffix;
}

sub _scan_keys {
    my ($kdb, $pattern) = @_;
    return () unless $kdb && $kdb->can('cmd');
    my %seen;
    my $cursor = '0';
    for (1 .. 1000) {
        my $res = eval { $kdb->cmd('SCAN', $cursor, 'MATCH', $pattern, 'COUNT', 100) };
        last unless ref($res) eq 'ARRAY' && @$res >= 2;
        $cursor = defined $res->[0] ? "$res->[0]" : '0';
        if (ref($res->[1]) eq 'ARRAY') {
            for my $k (@{ $res->[1] }) {
                $seen{$k} = 1 if defined $k && length $k;
            }
        }
        last if $cursor eq '0';
    }
    return sort keys %seen;
}

sub _build_node_record {
    my ($self, $active) = @_;
    $active = int($active // 0);
    $active = 0 if $active < 0;
    my $load = $active / ($self->{max_sessions} + 0.0);
    return {
        id     => $self->{node_id},
        host   => $self->{host},
        port   => $self->{port},
        active => $active,
        max    => $self->{max_sessions},
        load   => $load,
        digest => $self->{wave}->state_digest,
        step   => $self->{wave}->step,
    };
}

sub _write_node_record {
    my ($self, $rec) = @_;
    $self->{peers}{ $self->{node_id} } = $rec;
    my $kdb = $self->{keydb};
    return 1 unless $kdb;

    my $json = Shop::Domain::JSON::encode_json($rec);
    my $ttl  = $self->{node_ttl} > 0 ? $self->{node_ttl} : DEFAULT_TTL;
    my $ok   = eval {
        $kdb->set("cluster:node:$self->{node_id}", $json, $ttl);
        1;
    };
    return $ok ? 1 : 0;
}

sub register {
    my ($self, $active_sessions) = @_;
    my $rec = $self->_build_node_record($active_sessions // 0);
    my $ok  = $self->_write_node_record($rec);
    $self->{registered} = 1 if $ok;
    return $ok;
}

sub unregister {
    my ($self) = @_;
    my $kdb = $self->{keydb};
    if ($kdb) {
        eval { $kdb->del("cluster:node:$self->{node_id}") };
    }
    $self->{registered} = 0;
    return 1;
}

sub _sync_remote_bans {
    my ($self) = @_;
    my $bh  = $self->{blackhole};
    my $kdb = $self->{keydb};
    return 0 unless $bh;

    $bh->prune_expired();
    return 0 unless $kdb && $kdb->can('cmd');

    my $prefix  = _keydb_key($kdb, 'dos:ban:');
    my @keys    = _scan_keys($kdb, $prefix . '*');
    my $applied = 0;

    for my $full_key (@keys) {
        next unless index($full_key, $prefix) == 0;
        my $ip = substr($full_key, length($prefix));
        next unless defined $ip && length $ip;
        next if $bh->is_banned($ip);

        my ($reason, $ttl);
        if ($kdb->can('pipeline')) {
            my $res = eval { $kdb->pipeline([ [ 'GET', $full_key ], [ 'TTL', $full_key ] ]) };
            if (ref($res) eq 'ARRAY' && @$res >= 2) {
                ($reason, $ttl) = ($res->[0], $res->[1]);
            }
        }
        else {
            $reason = eval { $kdb->cmd('GET', $full_key) };
            $ttl    = eval { $kdb->cmd('TTL', $full_key) };
        }

        if (defined $ttl && $ttl > 0) {
            $bh->apply_remote_ban($ip, int($ttl), $reason // 'remote_ban');
            $applied++;
        }
    }

    return $applied;
}

# Periodic cooperative cluster tick:
# 1. Publish local node record with 10s TTL
# 2. Fetch active peers from KeyDB
# 3. Resize Wavefunction on topology change
# 4. Advance logical step via KeyDB INCR cluster:wave_step (no wall-clock)
# 5. Evolve Wavefunction and republish updated digest
# 6. Check peer digest coherence
# 7. Sync remote dos:ban:* keys into Blackhole
sub sync_tick {
    my ($self, $active_sessions) = @_;
    my $active = int($active_sessions // 0);
    $active    = 0 if $active < 0;

    my $local_rec = $self->_build_node_record($active);
    $self->_write_node_record($local_rec);

    my %peers = ( $self->{node_id} => $local_rec );
    my $kdb   = $self->{keydb};

    if ($kdb && $kdb->can('cmd')) {
        my $node_prefix = _keydb_key($kdb, 'cluster:node:');
        my @node_keys   = _scan_keys($kdb, $node_prefix . '*');
        if (@node_keys) {
            my $vals = eval { $kdb->cmd('MGET', @node_keys) };
            if (ref($vals) eq 'ARRAY') {
                for my $raw (@$vals) {
                    next unless defined $raw && length $raw;
                    my $rec = eval { Shop::Domain::JSON::decode_json($raw) };
                    next unless ref($rec) eq 'HASH' && defined $rec->{id} && length $rec->{id};
                    next if $rec->{id} eq $self->{node_id};
                    $peers{ $rec->{id} } = {
                        id     => "$rec->{id}",
                        host   => $rec->{host} // '127.0.0.1',
                        port   => int($rec->{port} // 2222),
                        active => int($rec->{active} // 0),
                        max    => int($rec->{max} // 1000),
                        load   => defined $rec->{load} ? ($rec->{load} + 0.0) : 0.0,
                        digest => $rec->{digest} // '',
                        step   => defined $rec->{step} ? int($rec->{step}) : undef,
                    };
                }
            }
        }
    }

    my @sorted_ids = sort keys %peers;
    my %loads      = map { $_ => ($peers{$_}{load} // 0.0) + 0.0 } @sorted_ids;

    $self->{wave}->resize(\@sorted_ids);

    # Advance logical step via KeyDB INCR (zero wall-clock)
    my $target_step;
    if ($kdb && $kdb->can('incr')) {
        $target_step = eval { int($kdb->incr('cluster:wave_step')) };
    }
    if (!defined $target_step) {
        $target_step = $self->{wave}->step + 1;
    }

    my $delta = $target_step - $self->{wave}->step;
    if ($delta > 0) {
        $delta = 256 if $delta > 256;
        $self->{wave}->evolve(\%loads, $delta);
    }

    # Publish updated local record with post-evolve digest and step
    $local_rec = $self->_build_node_record($active);
    $peers{ $self->{node_id} } = $local_rec;
    $self->_write_node_record($local_rec);

    # Check peer digest coherence for peers at the same logical step
    my $my_digest = $local_rec->{digest};
    my $my_step   = $local_rec->{step};
    my $coherent  = 1;
    for my $id (@sorted_ids) {
        next if $id eq $self->{node_id};
        my $p = $peers{$id};
        if (defined $p->{step} && $p->{step} == $my_step) {
            if (!defined $p->{digest} || $p->{digest} ne $my_digest) {
                $coherent = 0;
                last;
            }
        }
    }

    $self->{peers}        = \%peers;
    $self->{last_loads}   = \%loads;
    $self->{coherence_ok} = $coherent;

    $self->_sync_remote_bans();

    if ($self->{metrics}) {
        eval {
            $self->{metrics}->set('cluster_wave_step',    $my_step);
            $self->{metrics}->set('cluster_nodes_active', scalar(@sorted_ids));
            $self->{metrics}->set('cluster_coherence_ok', $coherent ? 1 : 0);
        };
    }

    return $self->status();
}

# Route an incoming connection deterministically via the cluster wavefunction.
# Returns ($target_node_hashref, $is_local) in list context, or $target_node_hashref in scalar context.
sub choose_node {
    my ($self, $peer_ip, $conn_seq) = @_;
    my $key       = (defined $peer_ip ? "$peer_ip" : 'unknown') . ':' . int($conn_seq // 0);
    my $target_id = $self->{wave}->route($key, $self->{last_loads}) // $self->{node_id};
    my $target    = $self->{peers}{$target_id} || {
        id     => $self->{node_id},
        host   => $self->{host},
        port   => $self->{port},
        active => 0,
        max    => $self->{max_sessions},
        load   => 0.0,
        digest => $self->{wave}->state_digest,
        step   => $self->{wave}->step,
    };
    my $is_local = ($target->{id} eq $self->{node_id}) ? 1 : 0;
    return wantarray ? ($target, $is_local) : $target;
}

sub _set_nonblock {
    my ($sock) = @_;
    my $flags = fcntl($sock, F_GETFL, 0);
    return unless defined $flags;
    fcntl($sock, F_SETFL, $flags | O_NONBLOCK);
}

sub _write_chunk {
    my ($dst, $buf_ref, $len, $shutdown_cell) = @_;
    my $off = 0;
    while ($off < $len) {
        return 0 if $shutdown_cell && $shutdown_cell->get();
        my $w = syswrite($dst, $$buf_ref, $len - $off, $off);
        if (defined $w && $w > 0) {
            $off += $w;
            next;
        }
        if (!defined $w && ($!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR})) {
            my $wp = IO::Poll->new();
            $wp->mask($dst => POLLOUT | POLLERR | POLLHUP);
            my $rc = $wp->poll(0.1);
            next if defined $rc && $rc >= 0;
            return 0;
        }
        return 0;
    }
    return 1;
}

# Transparent raw L4 TCP splice relay using IO::Poll and a single 8 KiB buffer.
# Performs zero SSH decryption, zero zlib allocation, and zero TUI screen allocation.
# Callable as $mesh->relay_socket($client, $host, $port, $shutdown_cell)
# or Shop::Cluster::Mesh::relay_socket($client, $host, $port, $shutdown_cell).
sub relay_socket {
    my $self;
    if (ref($_[0]) && eval { $_[0]->isa(__PACKAGE__) }) {
        $self = shift;
    }
    elsif (defined $_[0] && !ref($_[0]) && $_[0] eq __PACKAGE__) {
        shift;
    }
    my ($client_sock, $peer_host, $peer_port, $shutdown_cell) = @_;
    return 0 unless $client_sock && defined $peer_host && defined $peer_port;

    local $SIG{PIPE} = 'IGNORE';

    my $peer_sock = IO::Socket::INET->new(
        PeerAddr => $peer_host,
        PeerPort => int($peer_port),
        Proto    => 'tcp',
        Timeout  => 5,
    );
    if (!$peer_sock) {
        eval { close($client_sock) };
        return 0;
    }

    binmode($client_sock);
    binmode($peer_sock);
    eval { setsockopt($client_sock, IPPROTO_TCP, TCP_NODELAY, pack('l', 1)) };
    eval { setsockopt($peer_sock,   IPPROTO_TCP, TCP_NODELAY, pack('l', 1)) };
    _set_nonblock($client_sock);
    _set_nonblock($peer_sock);

    my $poll = IO::Poll->new();
    $poll->mask($client_sock => POLLIN | POLLHUP | POLLERR);
    $poll->mask($peer_sock   => POLLIN | POLLHUP | POLLERR);

    my $buf          = '';
    my $client_eof   = 0;
    my $peer_eof     = 0;
    my $total_bytes  = 0;

    while ((!$client_eof || !$peer_eof) && (!$shutdown_cell || !$shutdown_cell->get())) {
        my $rc = $poll->poll(0.1);
        next if !defined $rc || $rc == 0;

        for my $dir (
            [ $client_sock, $peer_sock,   \$client_eof ],
            [ $peer_sock,   $client_sock, \$peer_eof   ],
        ) {
            my ($src, $dst, $eof_ref) = @$dir;
            next if $$eof_ref;
            my $ev = $poll->events($src);
            next unless $ev;

            if ($ev & (POLLNVAL)) {
                $$eof_ref = 1;
                $poll->remove($src);
                next;
            }

            if ($ev & (POLLIN | POLLHUP | POLLERR)) {
                my $n = sysread($src, $buf, RELAY_BUF_SIZE);
                if (!defined $n) {
                    next if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
                    $client_eof = 1;
                    $peer_eof   = 1;
                    last;
                }
                if ($n == 0) {
                    $$eof_ref = 1;
                    $poll->remove($src);
                    eval { shutdown($dst, 1) };
                    next;
                }
                if (!_write_chunk($dst, \$buf, $n, $shutdown_cell)) {
                    $client_eof = 1;
                    $peer_eof   = 1;
                    last;
                }
                $total_bytes += $n;
            }
        }
    }

    eval { close($peer_sock) };
    eval { close($client_sock) };

    if ($self && $self->{metrics}) {
        eval {
            $self->{metrics}->inc('cluster_relayed_total', 1);
            $self->{metrics}->inc('cluster_relayed_bytes', $total_bytes) if $total_bytes > 0;
        };
    }

    return 1;
}

sub status {
    my ($self) = @_;
    return {
        node_id       => $self->{node_id},
        step          => $self->{wave}->step,
        dim           => $self->{wave}->dim,
        nodes         => $self->{wave}->nodes,
        digest        => $self->{wave}->state_digest,
        coherence_ok  => $self->{coherence_ok} ? 1 : 0,
        probabilities => $self->{wave}->probabilities($self->{last_loads}),
        blackhole     => $self->{blackhole} ? $self->{blackhole}->stats : {},
    };
}

1;
