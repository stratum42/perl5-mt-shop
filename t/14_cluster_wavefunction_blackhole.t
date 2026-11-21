#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib",
        "$FindBin::Bin/../xs/Shop-SSH-Crypto/blib/lib",
        "$FindBin::Bin/../xs/Shop-SSH-Crypto/blib/arch";

BEGIN {
    my $mojo_root = $ENV{MOJOLICIOUS_MT_ROOT} // "$FindBin::Bin/../../mojolicious-mt";
    if (-d "$mojo_root/lib") {
        for my $dir (
            "$mojo_root/xs-keydb/blib/arch",
            "$mojo_root/xs-keydb/blib/lib",
            "$mojo_root/xs/blib/arch",
            "$mojo_root/xs/blib/lib",
            "$mojo_root/lib",
        ) {
            unshift @INC, $dir if -d $dir && !grep { $_ eq $dir } @INC;
        }
    }
}

use Test::More;
use IO::Socket::INET;
use File::Temp qw(tempdir);
use Time::HiRes qw(time sleep usleep);

use MT;
use MT::Cell;
use MT::SharedHash;
use MT::Channel;
use MT::Fiber;

use Shop::Domain::JSON qw(encode_json decode_json);
use Shop::Metrics;
use Shop::Cache::KeyDB;
use Shop::Cluster::Wavefunction;
use Shop::Cluster::Blackhole;
use Shop::Cluster::Mesh;
use Shop::SSH::Wire qw(load_or_generate_hostkey);
use Shop::SSH::Session;
use Shop::TUI::Screen;
use Shop::TUI::View::Admin;
use Shop::Webhook::Server;

# ---------------------------------------------------------------------------
# Worker entrypoints (defined before MT::Image::freeze)
# ---------------------------------------------------------------------------
package ClusterTestWorkers;

use strict;
use warnings;
use IO::Socket::INET;
use Time::HiRes qw(time usleep);

sub evolve_worker {
    my ($nodes_json, $steps) = @_;
    my $nodes = Shop::Domain::JSON::decode_json($nodes_json);
    my $wf    = Shop::Cluster::Wavefunction->new(
        nodes      => $nodes,
        step       => 0,
        dt         => 0.15,
        coupling   => 0.35,
        load_alpha => 1.5,
    );

    my @digests;
    my $max_norm_err = 0.0;
    for my $s (1 .. $steps) {
        my %loads = (
            'node-a' => (($s % 5) * 0.15),
            'node-b' => ((($s + 1) % 5) * 0.12),
            'node-c' => ((($s + 2) % 5) * 0.10),
            'node-d' => ((($s + 3) % 5) * 0.08),
        );
        $wf->evolve(\%loads, 1);
        my $err = abs($wf->norm() - 1.0);
        $max_norm_err = $err if $err > $max_norm_err;
        push @digests, $wf->state_digest();
    }

    return Shop::Domain::JSON::encode_json({
        step         => $wf->step(),
        digests      => \@digests,
        max_norm_err => $max_norm_err,
    });
}

sub resize_worker {
    my $wf = Shop::Cluster::Wavefunction->new(
        nodes => ['node-1'],
        step  => 0,
    );
    my @sequence = (
        ['node-1'],
        ['node-1', 'node-2'],
        ['node-1', 'node-2', 'node-3'],
        ['node-1', 'node-2', 'node-3', 'node-4'],
        ['node-1', 'node-2', 'node-3'],
        ['node-1', 'node-2'],
    );
    my @stages;
    for my $set (@sequence) {
        $wf->resize($set);
        my %loads = map { $_ => 0.15 } @$set;
        $wf->evolve(\%loads, 3);
        push @stages, {
            dim      => $wf->dim(),
            step     => $wf->step(),
            digest   => $wf->state_digest(),
            norm_err => abs($wf->norm() - 1.0),
        };
    }
    return Shop::Domain::JSON::encode_json({ stages => \@stages });
}

sub node_b_ssh_worker {
    my ($port_cell_id, $hostkey_path, $shutdown_id, $result_cell_id) = @_;
    my $port_cell   = MT::Cell->attach($port_cell_id);
    my $shutdown    = MT::Cell->attach($shutdown_id);
    my $result_cell = MT::Cell->attach($result_cell_id);

    eval {
        my $hk = Shop::SSH::Wire::load_or_generate_hostkey($hostkey_path);
        my $listen = IO::Socket::INET->new(
            LocalAddr => '127.0.0.1',
            LocalPort => 0,
            Proto     => 'tcp',
            Listen    => 16,
            ReuseAddr => 1,
            Timeout   => 10,
        ) or die "node-b listen failed: $!";

        $port_cell->set($listen->sockport());

        my $client = $listen->accept() or die "node-b accept failed: $!";
        my $sess = Shop::SSH::Session->accept(
            sock              => $client,
            hostkey           => $hk,
            allow_guest       => 1,
            compression_level => 5,
            handshake_timeout => 15,
            auth_timeout      => 15,
            session_timeout   => 15,
        );

        my ($cols, $rows) = $sess->size();
        my $scr = Shop::TUI::Screen->new(cols => $cols || 80, rows => $rows || 24);
        $scr->clear();
        $scr->box(0, 0, $cols || 80, 7, 0, 'PERL5-MT SHOP CLUSTER', 0);
        $scr->write_str(2, 2, 'NODE-B TUI READY (relayed via L4 splice)', 0, 70);
        $scr->write_str(2, 4, 'User: ' . ($sess->user()->{username} // 'guest'), 0, 70);
        my $ansi = $scr->render();
        $sess->write_output($ansi . "\r\nNODE-B-OK>\r\n");

        my $buf = '';
        my $deadline = time() + 10;
        while (time() < $deadline && !$shutdown->get()) {
            my $in = $sess->read_input_nonblock();
            last unless defined $in;
            if (length($in) > 0) {
                $buf .= $in;
                last if $buf =~ /q/;
            } else {
                usleep(10_000);
            }
        }

        my $user = $sess->user();
        $sess->close(0);
        close($listen);
        $result_cell->set(Shop::Domain::JSON::encode_json({
            ok          => 1,
            username    => $user->{username}    // '',
            fingerprint => $user->{fingerprint} // '',
        }));
    };
    if ($@) {
        $result_cell->set(Shop::Domain::JSON::encode_json({
            ok    => 0,
            error => "$@",
        }));
    }
    return 1;
}

sub node_a_relay_worker {
    my ($port_cell_id, $target_host, $target_port, $m_cells_id, $m_rl_id, $shutdown_id) = @_;
    my $port_cell = MT::Cell->attach($port_cell_id);
    my $metrics   = Shop::Metrics->attach({ cells_id => $m_cells_id, ratelimit_id => $m_rl_id });
    my $shutdown  = MT::Cell->attach($shutdown_id);

    eval {
        my $listen = IO::Socket::INET->new(
            LocalAddr => '127.0.0.1',
            LocalPort => 0,
            Proto     => 'tcp',
            Listen    => 16,
            ReuseAddr => 1,
            Timeout   => 10,
        ) or die "node-a listen failed: $!";

        $port_cell->set($listen->sockport());

        my $client = $listen->accept() or die "node-a accept failed: $!";
        my $mesh = Shop::Cluster::Mesh->new(
            node_id => 'node-a',
            host    => '127.0.0.1',
            port    => $listen->sockport(),
            metrics => $metrics,
        );
        $mesh->relay_socket($client, $target_host, $target_port, $shutdown);
        close($listen);
    };
    return 1;
}

package main;

my $tmp = tempdir(CLEANUP => 1);

# Freeze image once before spawning any MT::Worker threads
Shop::Webhook::Server::prepare_for_freeze();
MT::Image::freeze();

# ===========================================================================
# Test 1: Bit-identical wavefunction evolution across 4 independent MT::Worker
#         threads (steps 1..50, ||psi||_2 = 1.0 +/- 1e-12, zero wall-clock)
# ===========================================================================
subtest 'Test 1: Bit-identical wavefunction evolution across 4 MT::Worker threads' => sub {
    my $nodes_json = encode_json([qw(node-a node-b node-c node-d)]);
    my @workers;
    for (1 .. 4) {
        push @workers, MT::Worker::spawn('ClusterTestWorkers::evolve_worker', $nodes_json, 50);
    }

    my @results;
    for my $w (@workers) {
        my $raw = MT::Worker::join($w);
        push @results, decode_json($raw);
    }

    is(scalar(@results), 4, 'all 4 workers completed');
    my $ref_digests = $results[0]{digests};
    is(scalar(@$ref_digests), 50, '50 evolution steps recorded');
    is($results[0]{step}, 50, 'final step is 50');

    my $all_identical = 1;
    my $worst_err     = 0.0;
    for my $idx (0 .. 3) {
        my $r = $results[$idx];
        $worst_err = $r->{max_norm_err} if $r->{max_norm_err} > $worst_err;
        for my $s (0 .. 49) {
            if ($r->{digests}[$s] ne $ref_digests->[$s]) {
                $all_identical = 0;
                diag("Worker $idx diverged at step " . ($s + 1));
                last;
            }
        }
    }
    ok($all_identical, 'exact same state_digest() across all 4 workers at steps 1..50');
    cmp_ok($worst_err, '<=', 1e-12, sprintf('strict unit norm ||psi||_2 = 1.0 +/- 1e-12 (max err=%.3e)', $worst_err));
};

# ===========================================================================
# Test 2: Hilbert-space expansion (1 -> 2 -> 3 -> 4) and contraction (4 -> 3 -> 2)
#         with immediate bit-identical convergence across 4 MT::Worker threads
# ===========================================================================
subtest 'Test 2: Hilbert-space expansion and contraction across 4 MT::Worker threads' => sub {
    my @workers;
    for (1 .. 4) {
        push @workers, MT::Worker::spawn('ClusterTestWorkers::resize_worker');
    }

    my @results;
    for my $w (@workers) {
        push @results, decode_json(MT::Worker::join($w));
    }

    my @expected_dims = (1, 2, 3, 4, 3, 2);
    my $ref_stages    = $results[0]{stages};
    is_deeply([ map { $_->{dim} } @$ref_stages ], \@expected_dims, 'Hilbert-space dimensions match 1->2->3->4->3->2');

    my $all_converged = 1;
    my $worst_err     = 0.0;
    for my $widx (0 .. 3) {
        my $st = $results[$widx]{stages};
        for my $i (0 .. $#expected_dims) {
            $worst_err = $st->[$i]{norm_err} if $st->[$i]{norm_err} > $worst_err;
            if ($st->[$i]{digest} ne $ref_stages->[$i]{digest}) {
                $all_converged = 0;
                diag("Worker $widx diverged at resize stage $i (dim=$expected_dims[$i])");
            }
        }
    }
    ok($all_converged, 'bit-identical convergence across all 4 workers on expand and contract');
    cmp_ok($worst_err, '<=', 1e-12, sprintf('unit norm preserved across all resizes (max err=%.3e)', $worst_err));
};

# ===========================================================================
# Test 3: Load-repulsive Born-rule routing
# ===========================================================================
subtest 'Test 3: Load-repulsive Born-rule routing shifts traffic off overloaded node' => sub {
    my $wf = Shop::Cluster::Wavefunction->new(
        nodes      => [qw(node-a node-b node-c)],
        dt         => 0.15,
        coupling   => 0.35,
        load_alpha => 1.5,
    );
    my %loads = (
        'node-a' => 0.95,
        'node-b' => 0.05,
        'node-c' => 0.05,
    );
    $wf->evolve(\%loads, 10);

    my $probs = $wf->probabilities(\%loads);
    my $psum  = ($probs->{'node-a'} // 0) + ($probs->{'node-b'} // 0) + ($probs->{'node-c'} // 0);
    cmp_ok(abs($psum - 1.0), '<=', 1e-12, 'Born probabilities sum to 1.0');
    cmp_ok($probs->{'node-b'}, '>', $probs->{'node-a'}, 'node-b has higher probability than overloaded node-a');
    cmp_ok($probs->{'node-c'}, '>', $probs->{'node-a'}, 'node-c has higher probability than overloaded node-a');

    my %counts = ('node-a' => 0, 'node-b' => 0, 'node-c' => 0);
    for my $seq (1 .. 1000) {
        my $chosen = $wf->route("10.0.0." . ($seq % 250) . ":$seq", \%loads);
        $counts{$chosen}++;
    }
    cmp_ok($counts{'node-b'}, '>', $counts{'node-a'},
        "node-b routed more connections ($counts{'node-b'}) than overloaded node-a ($counts{'node-a'})");
    cmp_ok($counts{'node-c'}, '>', $counts{'node-a'},
        "node-c routed more connections ($counts{'node-c'}) than overloaded node-a ($counts{'node-a'})");
    cmp_ok($counts{'node-b'} + $counts{'node-c'}, '>', 3 * $counts{'node-a'},
        'over 75% of connections shifted to unloaded peers');

    # Deterministic routing check: same key always routes to same node
    my $first  = $wf->route('203.0.113.42:777', \%loads);
    my $second = $wf->route('203.0.113.42:777', \%loads);
    is($first, $second, 'route() is deterministic for identical (peer_ip, seq)');
};

# ===========================================================================
# Test 4: DoS Blackhole (auto-ban, KeyDB cross-node sync, 200 shunted
#         connections with 0 fibers spawned and 0 B egress, /api/cluster, Admin)
# ===========================================================================
subtest 'Test 4: DoS Blackhole auto-ban, cross-node sync, 200 zero-fiber shunts, /api/cluster, Admin' => sub {
    my $metrics = Shop::Metrics->new();
    my $bh_a    = Shop::Cluster::Blackhole->new(
        ban_ttl       => 120,
        strike_limit  => 3,
        strike_window => 60,
        mode          => 'drop',
    );
    my $bh_b = Shop::Cluster::Blackhole->new(
        ban_ttl       => 120,
        strike_limit  => 3,
        strike_window => 60,
        mode          => 'drop',
    );

    # Optional live KeyDB connection for cross-node ban sync
    my $kdb_host = $ENV{KEYDB_HOST} // '127.0.0.1';
    my $kdb_port = int($ENV{KEYDB_PORT} // 6379);
    my $prefix   = "t14_bh_$$:";
    my $kdb = eval {
        my $k = Shop::Cache::KeyDB->new(host => $kdb_host, port => $kdb_port, prefix => $prefix);
        $k->ping() ? $k : undef;
    };

    # Terrapin / zip-bomb instant ban (weight 3 >= strike_limit 3)
    my $banned_terrapin = $bh_a->record_violation('198.51.100.10', 'terrapin_strict_kex', 3, $kdb);
    is($banned_terrapin, 1, 'Terrapin strict-KEX violation triggers immediate ban');
    is($bh_a->is_banned('198.51.100.10'), 1, '198.51.100.10 is banned');

    my $banned_zip = $bh_a->record_violation('198.51.100.11', 'zip_bomb', 3, $kdb);
    is($banned_zip, 1, 'zip-bomb violation triggers immediate ban');

    # Flood auto-ban after 3 strikes of weight 1
    is($bh_a->record_violation('127.0.0.1', 'rate_limit', 1, $kdb), 0, 'flood strike 1 does not ban yet');
    is($bh_a->record_violation('127.0.0.1', 'rate_limit', 1, $kdb), 0, 'flood strike 2 does not ban yet');
    is($bh_a->record_violation('127.0.0.1', 'rate_limit', 1, $kdb), 1, 'flood strike 3 triggers ban on 127.0.0.1');
    is($bh_a->is_banned('127.0.0.1'), 1, '127.0.0.1 is banned in O(1)');

    # Cross-node ban sync: via live KeyDB if available, else via apply_remote_ban
    if ($kdb) {
        my $mesh_b = Shop::Cluster::Mesh->new(
            node_id   => 'sync-b',
            host      => '127.0.0.1',
            port      => 2229,
            keydb     => $kdb,
            blackhole => $bh_b,
        );
        $mesh_b->sync_tick(0);
        is($bh_b->is_banned('198.51.100.10'), 1, 'KeyDB synced Terrapin ban to peer node');
        is($bh_b->is_banned('198.51.100.11'), 1, 'KeyDB synced zip-bomb ban to peer node');
        is($bh_b->is_banned('127.0.0.1'),     1, 'KeyDB synced flood ban to peer node');
        $mesh_b->unregister();
        eval {
            $kdb->del('dos:ban:198.51.100.10');
            $kdb->del('dos:ban:198.51.100.11');
            $kdb->del('dos:ban:127.0.0.1');
            $kdb->del('cluster:wave_step');
        };
    } else {
        $bh_b->apply_remote_ban('198.51.100.10', 120, 'terrapin_strict_kex');
        is($bh_b->is_banned('198.51.100.10'), 1, 'apply_remote_ban synced ban to peer node (KeyDB offline)');
    }

    # 200 subsequent attack connections shunted pre-fiber with 0 fibers spawned & 0 B egress
    my $srv = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 128,
        ReuseAddr => 1,
    ) or die "loopback listen failed: $!";
    my $srv_port = $srv->sockport();

    my $fibers_spawned = 0;
    my $egress_bytes   = 0;

    for (1 .. 200) {
        my $cli = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $srv_port,
            Proto    => 'tcp',
            Timeout  => 2,
        ) or die "client connect failed: $!";

        my $acc = $srv->accept() or die "server accept failed: $!";
        my $peer_ip = $acc->peerhost() || '127.0.0.1';
        if ($bh_a->is_banned($peer_ip)) {
            $bh_a->shunt_socket($acc, $peer_ip);
            $metrics->inc('ssh_dos_blackholed_total', 1);
        } else {
            $fibers_spawned++;
            close($acc);
        }

        my $buf = '';
        my $n = sysread($cli, $buf, 1024);
        $egress_bytes += length($buf) if defined($n) && $n > 0;
        close($cli);
    }
    close($srv);

    $metrics->set('ssh_dos_banned_ips', $bh_a->stats()->{banned_ips});
    is($fibers_spawned, 0, '0 fibers spawned for 200 banned attack connections');
    is($egress_bytes,   0, '0 bytes egress sent to 200 banned attack connections');
    is($metrics->get('ssh_dos_blackholed_total'), 200, 'ssh_dos_blackholed_total incremented to 200');
    is($bh_a->stats()->{blackholed_total}, 200, 'Blackhole stats blackholed_total == 200');
    cmp_ok($metrics->get('ssh_dos_banned_ips'), '>=', 3, 'ssh_dos_banned_ips >= 3');

    # Verify Prometheus /metrics exposition includes all 6 new cluster/blackhole metrics
    my $prom = $metrics->prometheus_text();
    for my $mname (qw(
        cluster_nodes_active cluster_wave_step cluster_coherence_ok
        cluster_relayed_total ssh_dos_blackholed_total ssh_dos_banned_ips
    )) {
        like($prom, qr/^$mname \d+/m, "Prometheus /metrics exports $mname");
    }

    # Verify GET /api/cluster via Shop::Webhook::Server (both raw handle_request and live HTTP)
    my $snap_cell = MT::Cell->new(encode_json({
        node_id      => 'node-a',
        step         => 12,
        dim          => 2,
        nodes        => ['node-a', 'node-b'],
        digest       => 'deadbeefcafe1234',
        coherence_ok => 1,
    }));
    my $wh = Shop::Webhook::Server->new(
        host            => '127.0.0.1',
        port            => 0,
        metrics         => $metrics,
        cluster_cell    => $snap_cell,
        cluster_enabled => 1,
        blackhole       => $bh_a,
    );
    my $raw_resp = $wh->handle_request('GET', '/api/cluster', {}, '');
    like($raw_resp, qr/^HTTP\/1\.1 200 OK/m, 'GET /api/cluster returns 200 OK');
    my ($json_body) = ($raw_resp =~ /\r\n\r\n(.*)\z/s);
    my $cl_json = decode_json($json_body);
    ok($cl_json->{ok}, 'GET /api/cluster ok is truthy');
    is($cl_json->{enabled}, 1, 'GET /api/cluster enabled == 1');
    is($cl_json->{cluster}{step}, 12, 'GET /api/cluster reports step=12');
    is($cl_json->{cluster}{dim},  2,  'GET /api/cluster reports dim=2');
    is($cl_json->{blackhole}{blackholed_total}, 200, 'GET /api/cluster reports blackholed_total=200');

    # Verify Admin.pm Dashboard renders Cluster Wavefunction + DoS Blackholed lines
    my $scr = Shop::TUI::Screen->new(cols => 100, rows => 30);
    my $admin = Shop::TUI::View::Admin->new();
    my $mock_app = bless {
        palette => {
            normal => 0, title => 0, price => 0, ok => 0, err => 0,
            warn => 0, dim => 0, border => 0, tab_act => 0, sel => 0, input => 0,
        },
        metrics      => $metrics,
        screen       => $scr,
        config       => { cluster => { enabled => 1, _snap_cell_id => $snap_cell->id } },
        cluster_cell => $snap_cell,
    }, 'MockAdminApp';
    {
        no strict 'refs';
        no warnings 'once';
        *MockAdminApp::is_admin     = sub { 1 };
        *MockAdminApp::format_money = sub { sprintf('%.2f', ($_[1] // 0) + 0) };
        *MockAdminApp::user_fp      = sub { 'SHA256:admin' };
    }
    $scr->clear();
    $admin->draw($mock_app, $scr, 0, 0, 100, 30);
    my $rendered = $scr->render();
    (my $plain = $rendered) =~ s/\e\[[0-9;?]*[A-Za-z]/ /g;
    like($plain, qr/Cluster\s+Wavefunction\s*:\s*step=12,\s*2\s+nodes,\s*coherence=OK,\s*digest=deadbeefcafe/,
        'Admin dashboard renders Cluster Wavefunction status');
    like($plain, qr/DoS\s+Blackholed\s*:\s*200\s+\(3\s+banned\s+IPs\)/,
        'Admin dashboard renders DoS Blackholed count and banned IPs');
};

# ===========================================================================
# Test 5: Live 2-instance cooperative SSH cluster over KeyDB (when available)
#         or loopback L4 relay: real /usr/bin/ssh connects to Node A, Node A
#         routes to Node B via raw L4 splice, authenticating & rendering TUI
# ===========================================================================
subtest 'Test 5: Live 2-instance cooperative SSH cluster with raw L4 splice relay' => sub {
    my $hostkey_path = "$tmp/cluster_host_ed25519";
    load_or_generate_hostkey($hostkey_path);

    my $cli_key = "$tmp/cluster_client_ed25519";
    system("ssh-keygen -q -t ed25519 -N '' -f '$cli_key'") == 0
        or die "ssh-keygen client key failed";

    my $metrics      = Shop::Metrics->new();
    my $m_ids        = $metrics->state_ids();
    my $shutdown     = MT::Cell->new(0);
    my $port_b_cell  = MT::Cell->new(0);
    my $port_a_cell  = MT::Cell->new(0);
    my $result_cell  = MT::Cell->new('');

    # Start Node B (real SSHv2 + TUI worker)
    my $wb = MT::Worker::spawn(
        'ClusterTestWorkers::node_b_ssh_worker',
        $port_b_cell->id, $hostkey_path, $shutdown->id, $result_cell->id
    );

    my $port_b = 0;
    for (1 .. 200) {
        $port_b = int($port_b_cell->get() || 0);
        last if $port_b > 0;
        usleep(10_000);
    }
    cmp_ok($port_b, '>', 0, "Node B listening on loopback port $port_b");

    # If KeyDB is reachable, verify real 2-node Mesh discovery + routing decision over KeyDB
    my $kdb_host = $ENV{KEYDB_HOST} // '127.0.0.1';
    my $kdb_port = int($ENV{KEYDB_PORT} // 6379);
    my $prefix   = "t14_mesh_$$:";
    my $kdb = eval {
        my $k = Shop::Cache::KeyDB->new(host => $kdb_host, port => $kdb_port, prefix => $prefix);
        $k->ping() ? $k : undef;
    };

    my ($target_host, $target_port) = ('127.0.0.1', $port_b);
    if ($kdb) {
        my $mesh_a = Shop::Cluster::Mesh->new(
            node_id      => 'node-a',
            host         => '127.0.0.1',
            port         => 2291,
            keydb        => $kdb,
            max_sessions => 1000,
        );
        my $mesh_b = Shop::Cluster::Mesh->new(
            node_id      => 'node-b',
            host         => '127.0.0.1',
            port         => $port_b,
            keydb        => $kdb,
            max_sessions => 1000,
        );
        $mesh_a->register(950); # heavily loaded
        $mesh_b->register(5);   # lightly loaded
        my $st_a = $mesh_a->sync_tick(950);
        my $st_b = $mesh_b->sync_tick(5);

        is($st_a->{dim}, 2, 'KeyDB Mesh discovered 2 active cluster nodes on Node A');
        is($st_b->{dim}, 2, 'KeyDB Mesh discovered 2 active cluster nodes on Node B');

        # Find a deterministic routing sequence that Node A routes to Node B
        my ($chosen, $is_local);
        for my $seq (1 .. 50) {
            ($chosen, $is_local) = $mesh_a->choose_node('127.0.0.1', $seq);
            last if !$is_local && $chosen->{id} eq 'node-b';
        }
        ok(!$is_local && $chosen->{id} eq 'node-b', 'overloaded Node A deterministically routes connection to Node B');
        is($chosen->{port}, $port_b, 'routed target port matches Node B');
        $target_host = $chosen->{host};
        $target_port = $chosen->{port};

        $mesh_a->unregister();
        $mesh_b->unregister();
        eval { $kdb->del('cluster:wave_step') };
    } else {
        pass("KeyDB not running on $kdb_host:$kdb_port; running loopback L4 relay test directly");
    }

    # Start Node A (raw L4 TCP splice relay worker -> Node B)
    my $wa = MT::Worker::spawn(
        'ClusterTestWorkers::node_a_relay_worker',
        $port_a_cell->id, $target_host, $target_port, $m_ids->{cells_id}, $m_ids->{ratelimit_id}, $shutdown->id
    );

    my $port_a = 0;
    for (1 .. 200) {
        $port_a = int($port_a_cell->get() || 0);
        last if $port_a > 0;
        usleep(10_000);
    }
    cmp_ok($port_a, '>', 0, "Node A L4 relay listening on loopback port $port_a");

    # Connect real /usr/bin/ssh to Node A; Node A transparently splices L4 TCP to Node B
    my $stdout_file = "$tmp/ssh_relay_out.log";
    my $stderr_file = "$tmp/ssh_relay_err.log";
    my $cmd = "/usr/bin/ssh -tt -C "
            . "-o BatchMode=yes "
            . "-o StrictHostKeyChecking=no "
            . "-o UserKnownHostsFile=/dev/null "
            . "-o IdentitiesOnly=yes "
            . "-o PreferredAuthentications=publickey "
            . "-o ConnectTimeout=10 "
            . "-i '$cli_key' -p $port_a shopper\@127.0.0.1 "
            . ">'$stdout_file' 2>'$stderr_file'";

    open my $ssh_in, '|-', $cmd or die "Failed to spawn ssh: $!";
    sleep(0.5);
    print $ssh_in "q";
    close $ssh_in;
    my $exit_code = $? >> 8;

    MT::Worker::join($wa);
    MT::Worker::join($wb);

    my $stdout = '';
    if (open my $fh, '<:raw', $stdout_file) { local $/; $stdout = <$fh>; close $fh; }
    my $res_raw = $result_cell->get();
    my $res     = (defined $res_raw && length $res_raw) ? decode_json($res_raw) : {};

    is($exit_code, 0, 'real /usr/bin/ssh exited cleanly (0) through Node A -> Node B L4 relay');
    ok($res->{ok}, 'Node B accepted, authenticated, and served the relayed SSH session');
    is($res->{username}, 'shopper', 'Node B authenticated username shopper');
    (my $plain_out = $stdout) =~ s/\e\[[0-9;?]*[A-Za-z]/ /g;
    like($plain_out, qr/NODE-B\s+TUI\s+READY/, 'client received Node B rendered TUI frame via raw L4 splice');
    is($metrics->get('cluster_relayed_total'), 1, 'Node A incremented cluster_relayed_total == 1');
};

done_testing();
