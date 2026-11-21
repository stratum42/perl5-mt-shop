#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use IO::Socket::INET;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
use lib 'lib';

use MT;
use MT::Cell;
use MT::Channel;
use MT::Checkpoint;
use MT::Decimal;
use MT::Fault;
use MT::Fiber;
use MT::Pool;
use MT::SharedHash;
use MT::Supervisor;

use Shop::Cache::KeyDB;
use Shop::DB;
use Shop::Domain::Pricing;
use Shop::State::EventBus;
use Shop::State::Inventory;

# ---------------------------------------------------------------------------
# Constants and worker entrypoints (defined before MT::Image::freeze)
# ---------------------------------------------------------------------------

use constant SEALED_TAX_RATE => '0.0825';
my $IMMORTAL_YES = \!!1;

sub w_mutate_boot_image {
    my ($out_id) = @_;
    my $out = MT::Channel->attach($out_id);

    my $immortal_err = '';
    eval { Internals::SvREFCNT($$IMMORTAL_YES, 5) };
    $immortal_err = $@ // '';

    my $readonly_err = '';
    eval {
        my $ref = \SEALED_TAX_RATE();
        $$ref = '0.9900';
    };
    $readonly_err = $@ // '';

    $out->send("IMMORTAL:$immortal_err");
    $out->send("READONLY:$readonly_err");
    return 1;
}

sub w_sibling_cas_decimal {
    my ($p_id, $c_id, $iters) = @_;
    my $inv = Shop::State::Inventory->attach({ products_id => $p_id, cells_id => $c_id });
    my $ok_ops = 0;
    my $last_total = '';
    for (1 .. $iters) {
        my ($ok) = $inv->reserve('VT-220', 1);
        if ($ok) {
            $inv->release('VT-220', 1);
            $ok_ops++;
        }
        my $quote = Shop::Domain::Pricing::calculate(
            [{ sku => 'VT-220', name => 'VT220', qty => 2, unit_price => '429.0000' }],
            tax_rate => SEALED_TAX_RATE,
        );
        $last_total = '' . $quote->{total};
    }
    return "$ok_ops:$last_total";
}

sub w_hung_heartbeat {
    my ($in_id, $out_id) = @_;
    my $in  = MT::Channel->attach($in_id);
    my $out = MT::Channel->attach($out_id);
    MT::Supervisor::beat();
    MT::Supervisor::_pause_heartbeat(1);
    $out->send('paused');
    $in->recv();
    return 'exited';
}

sub w_healthy_heartbeat {
    my ($in_id, $out_id) = @_;
    my $in  = MT::Channel->attach($in_id);
    my $out = MT::Channel->attach($out_id);
    MT::Supervisor::beat();
    $out->send('alive');
    my $beats = 1;
    while (1) {
        my ($got, $msg) = $in->try_recv;
        last if $got && defined $msg && $msg eq 'stop';
        MT::Supervisor::beat();
        $beats++;
        sleep(0.02);
    }
    return $beats;
}

sub paired_checkout_batch {
    my ($spec) = @_;
    my ($total_orders, $crash_at) = split /:/, $spec;
    my $state = MT::Checkpoint::restore() // {
        step       => 0,
        cents_acc  => 0,
        resumed    => 0,
        ckpt_count => 0,
    };
    $state->{resumed} = 1 if MT::Checkpoint::is_backup();

    while ($state->{step} < $total_orders) {
        $state->{step}++;
        $state->{cents_acc} += ($state->{step} * 1995);
        if ($state->{step} % 500 == 0) {
            $state->{ckpt_count}++;
            MT::Checkpoint::save($state);
        }
        if ($crash_at > 0 && $state->{step} == $crash_at && !MT::Checkpoint::is_backup()) {
            MT::Fault::_trigger_sigsegv();
        }
    }
    return $state;
}

sub w_fiber_isolation {
    my ($n_fibers) = @_;
    my @fibers;
    my %results;
    my %errors;

    for my $i (1 .. $n_fibers) {
        my $should_die = ($i == 3 || $i == 7) ? 1 : 0;
        my $fid = MT::Fiber::spawn(sub {
            my ($idx, $fail) = @_;
            my $out;
            my $ok = eval {
                MT::Fiber::yield("step1:$idx");
                die "simulated fiber fault on session $idx\n" if $fail;
                my $q = Shop::Domain::Pricing::calculate(
                    [{ sku => "SKU-$idx", qty => $idx, unit_price => '10.00' }],
                    tax_rate => '0.0800',
                );
                MT::Fiber::yield("step2:$idx");
                $out = "ok:$idx:" . $q->{total};
                1;
            };
            if (!$ok) {
                return "ERR:$idx:$@";
            }
            return $out;
        }, $i, $should_die);
        push @fibers, { id => $fid, idx => $i };
    }

    # Round-robin cooperative scheduling across all fibers
    my $active = scalar(@fibers);
    while ($active > 0) {
        $active = 0;
        for my $f (@fibers) {
            next if $f->{done};
            my ($val) = MT::Fiber::resume($f->{id});
            if (MT::Fiber::is_finished($f->{id})) {
                my $res = MT::Fiber::join($f->{id});
                if (defined $res && $res =~ /^ERR:(\d+):(.*)$/s) {
                    $errors{$1} = $2;
                }
                else {
                    $results{ $f->{idx} } = $res;
                }
                $f->{done} = 1;
            }
            else {
                $active++;
            }
        }
    }

    my $ok_count  = scalar(keys %results);
    my $err_count = scalar(keys %errors);
    my $remaining = MT::Fiber::count();
    return "$ok_count:$err_count:$remaining";
}

# Seed shared hot inventory before freezing the boot image
my $inv = Shop::State::Inventory->new;
$inv->upsert_product({
    sku         => 'VT-220',
    name        => 'DEC VT220 Amber Terminal',
    category    => 'Terminals',
    description => 'Amber CRT serial terminal',
    price       => '429.0000',
    stock       => 50,
    active      => 1,
});
$inv->upsert_product({
    sku         => 'AC-MUG',
    name        => 'Enamel Mug',
    category    => 'Accessories',
    description => '0xDEADBEEF mug',
    price       => '19.9500',
    stock       => 25,
    active      => 1,
});

# Freeze once before spawning workers or pools
MT::Image::freeze();
MT::Fault::reset();

# ---------------------------------------------------------------------------
# Test 1: Sealed Boot Image Isolation
# ---------------------------------------------------------------------------
{
    my $inv_ids = $inv->state_ids;
    my $err_ch  = MT::Channel->new(4);

    my $w_mut = MT::Worker::spawn('main::w_mutate_boot_image', $err_ch->id);
    my $w_sib = MT::Worker::spawn('main::w_sibling_cas_decimal', $inv_ids->{products_id}, $inv_ids->{cells_id}, 50);

    MT::Worker::join($w_mut);
    my $sib_res = MT::Worker::join($w_sib);
    my $imm_msg = $err_ch->recv;
    my $ro_msg  = $err_ch->recv;

    like($imm_msg, qr/MT_IMMORTAL_MUTATION/,
        'Test 1: immortal refcount mutation trapped with MT_IMMORTAL_MUTATION');
    like($ro_msg, qr/read-only/i,
        'Test 1: frozen boot-image constant mutation trapped as read-only error');
    is($sib_res, '50:928.79',
        'Test 1: sibling worker completed 50 CAS + MT::Decimal pricing ops unaffected');
    is($inv->get_stock('VT-220'), 50,
        'Test 1: inventory stock invariant preserved (50)');
}

# ---------------------------------------------------------------------------
# Test 2: MT::Supervisor + MT::Fault Heartbeat Detection
# ---------------------------------------------------------------------------
{
    MT::Fault::reset();
    my @captured_faults;
    MT::Fault::on(sub { push @captured_faults, $_[0] });

    my $hung_in   = MT::Channel->new(4);
    my $hung_out  = MT::Channel->new(4);
    my $good_in   = MT::Channel->new(4);
    my $good_out  = MT::Channel->new(4);

    my $w_hung = MT::Worker::spawn('main::w_hung_heartbeat', $hung_in->id, $hung_out->id);
    my $w_good = MT::Worker::spawn('main::w_healthy_heartbeat', $good_in->id, $good_out->id);

    is($hung_out->recv, 'paused', 'Test 2: hung worker paused heartbeats');
    is($good_out->recv, 'alive',  'Test 2: healthy sibling worker started beating');

    my $t0 = clock_gettime(CLOCK_MONOTONIC);
    my $detected = 0;
    while (clock_gettime(CLOCK_MONOTONIC) - $t0 < 3.0) {
        if (MT::Supervisor::tick() > 0) {
            $detected = 1;
            last;
        }
        sleep(0.01);
    }
    my $detect_ms = (clock_gettime(CLOCK_MONOTONIC) - $t0) * 1000.0;

    my $status = MT::Supervisor::status();
    my ($st_hung) = grep { $_->{unit_kind} eq 'worker' && $_->{unit_id} == $w_hung } @$status;
    my ($st_good) = grep { $_->{unit_kind} eq 'worker' && $_->{unit_id} == $w_good } @$status;

    $hung_in->send('stop');
    $good_in->send('stop');
    MT::Worker::join($w_hung);
    my $good_beats = MT::Worker::join($w_good);

    my ($hb_fault) = grep { ($_->{cause} // '') eq 'HEARTBEAT_TIMEOUT' } @captured_faults;

    ok($detected, sprintf('Test 2: missed-heartbeat fault detected in %.1f ms', $detect_ms));
    ok(defined $hb_fault && $hb_fault->{unit_kind} eq 'worker' && $hb_fault->{unit_id} == $w_hung,
        'Test 2: structured HEARTBEAT_TIMEOUT fault event captured for hung worker');
    is($st_hung ? $st_hung->{state} : 'missing', 'faulted',
        'Test 2: supervisor marked hung worker as faulted');
    is($st_good ? $st_good->{state} : 'missing', 'live',
        'Test 2: healthy sibling worker remained live');
    ok($good_beats >= 2, "Test 2: healthy sibling posted $good_beats heartbeats unaffected");
}

# ---------------------------------------------------------------------------
# Test 3: MT::Pool Supervised Respawn & pairs => 1 Primary/Backup Failover
# ---------------------------------------------------------------------------
{
    my $pool = MT::Pool->new(workers => 2, pairs => 1, max_restarts => 8, backoff_base_ms => 5);

    my $ref = $pool->run(\&paired_checkout_batch, '2000:0')->join;

    my $t0  = clock_gettime(CLOCK_MONOTONIC);
    my $res = $pool->run(\&paired_checkout_batch, '2000:1250')->join;
    my $e2e_ms = (clock_gettime(CLOCK_MONOTONIC) - $t0) * 1000.0;

    my $takeovers   = $pool->takeovers;
    my $takeover_ms = $pool->last_takeover_ms;
    my @faults      = $pool->faults;
    $pool->shutdown;

    is($res->{step}, 2000, 'Test 3: backup completed all 2000 steps');
    is($res->{cents_acc}, $ref->{cents_acc},
        'Test 3: backup restored checkpoint state and matched reference accumulator');
    is($res->{resumed}, 1, 'Test 3: backup observed MT::Checkpoint::is_backup() == 1');
    is($takeovers, 1, sprintf('Test 3: exactly 1 primary->backup takeover (%.2f ms takeover, %.2f ms e2e)', $takeover_ms, $e2e_ms));
    is(scalar(@faults), 1, 'Test 3: pool recorded 1 primary fault event');
}

# ---------------------------------------------------------------------------
# Test 4: Per-Fiber Crash Isolation
# ---------------------------------------------------------------------------
{
    my $w = MT::Worker::spawn('main::w_fiber_isolation', 10);
    my $summary = MT::Worker::join($w);
    is($summary, '8:2:0',
        'Test 4: 8 of 10 fibers completed cleanly, 2 died inside eval guards, 0 leaked fibers');
}

# ---------------------------------------------------------------------------
# Test 5: MT::Checkpoint Atomic Snapshot & Corruption Rejection
# ---------------------------------------------------------------------------
{
    my ($fh, $ckpt_path) = tempfile(UNLINK => 1);
    close $fh;

    ok($inv->save_checkpoint($ckpt_path), 'Test 5: Inventory::save_checkpoint wrote atomic snapshot');

    my $inv_reloaded = Shop::State::Inventory->new;
    my $count = $inv_reloaded->load_checkpoint($ckpt_path);
    is($count, 2, 'Test 5: clean reload restored 2 products');
    is($inv_reloaded->get_stock('VT-220'), 50, 'Test 5: reloaded VT-220 stock matches (50)');
    is($inv_reloaded->get_stock('AC-MUG'), 25, 'Test 5: reloaded AC-MUG stock matches (25)');

    # Flip a byte inside the payload (past the 13-byte MTCK header)
    open my $rfh, '+<:raw', $ckpt_path or die "open $ckpt_path: $!\n";
    seek($rfh, 16, 0) or die "seek: $!\n";
    my $byte;
    read($rfh, $byte, 1) == 1 or die "read: $!\n";
    seek($rfh, 16, 0) or die "seek: $!\n";
    print $rfh chr(ord($byte) ^ 0xff);
    close $rfh;

    my $inv_corrupt = Shop::State::Inventory->new;
    eval { $inv_corrupt->load_checkpoint($ckpt_path) };
    my $corrupt_err = $@ // '';
    like($corrupt_err, qr/checksum mismatch/i,
        'Test 5: corrupted checkpoint byte rejected cleanly with checksum mismatch');
}

# ---------------------------------------------------------------------------
# Test 6: Hot-Tier Graceful Degradation on KeyDB / DB Outage
# ---------------------------------------------------------------------------
{
    local $SIG{PIPE} = 'IGNORE';

    # Reserve an ephemeral port and close it immediately to guarantee ECONNREFUSED
    my $probe = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
    ) or die "socket: $!\n";
    my $closed_port = $probe->sockport;
    close $probe;

    my $kdb = Shop::Cache::KeyDB->new(
        host    => '127.0.0.1',
        port    => $closed_port,
        timeout => 1,
    );
    my $kdb_ok = eval { $kdb->cmd('PING'); 1 };
    ok(!$kdb_ok, "Test 6: KeyDB outage confirmed on closed port $closed_port");

    my $db = Shop::DB->new({
        driver      => 'db2',
        gateway_url => "http://127.0.0.1:$closed_port",
        timeout     => 1,
    });
    my $db_ok = eval { $db->list_products; 1 };
    ok(!$db_ok, "Test 6: DB outage confirmed on closed port $closed_port");

    # Hot-tier operations must continue with 0 errors
    my $hot_errors = 0;
    my $cat = eval { $inv->list_catalog };
    $hot_errors++ if $@ || !ref($cat) || scalar(@$cat) != 2;

    my ($res_ok, $after_res) = eval { $inv->reserve('AC-MUG', 3) };
    $hot_errors++ if $@ || !$res_ok || $after_res != 22;

    my $after_rel = eval { $inv->release('AC-MUG', 3) };
    $hot_errors++ if $@ || !defined($after_rel) || $after_rel != 25;

    my $quote = eval {
        Shop::Domain::Pricing::calculate(
            [{ sku => 'AC-MUG', name => 'Enamel Mug', qty => 3, unit_price => '19.9500' }],
            tax_rate => '0.0825',
        );
    };
    $hot_errors++ if $@ || !$quote || "$quote->{total}" ne '72.74';

    my $bus   = Shop::State::EventBus->new;
    my $inbox = $bus->register_session('degraded-sess', { user_fp => 'SHA256:degraded' });
    my $sent  = eval { $bus->broadcast({ type => 'stock_update', sku => 'AC-MUG', stock => 25 }) };
    $hot_errors++ if $@ || !defined($sent) || $sent != 1;
    my $evs   = eval { $bus->poll_inbox($inbox) };
    $hot_errors++ if $@ || !ref($evs) || scalar(@$evs) != 1 || $evs->[0]{sku} ne 'AC-MUG';
    $bus->unregister_session('degraded-sess');

    is($hot_errors, 0,
        'Test 6: hot-tier catalog, MT::Cell CAS reserve/release, MT::Decimal pricing, and EventBus operated with 0 errors during KeyDB + DB outage');
}

done_testing;
