#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use lib 'lib';

use MT;
use MT::Channel;
use Shop::State::Inventory;
use Shop::State::EventBus;

my $inv = Shop::State::Inventory->new;
$inv->upsert_product({
    sku         => 'VT-220',
    name        => 'DEC VT220 Amber Terminal',
    category    => 'Terminals',
    description => 'Amber CRT serial terminal',
    price       => '429.0000',
    stock       => 5,
    active      => 1,
});
$inv->upsert_product({
    sku         => 'AC-MUG',
    name        => 'Enamel Mug',
    category    => 'Accessories',
    description => '0xDEADBEEF mug',
    price       => '19.9500',
    stock       => 10,
    active      => 1,
});

is($inv->get_stock('VT-220'), 5, 'initial stock is 5');

my $bus   = Shop::State::EventBus->new;
my $inbox = $bus->register_session('sess-main', { user_fp => 'SHA256:main', username => 'alice' });

sub race_worker {
    my ($p_id, $c_id, $s_id, $out_id, $idx) = @_;
    my $w_inv = Shop::State::Inventory->attach({ products_id => $p_id, cells_id => $c_id });
    my $w_bus = Shop::State::EventBus->attach({ sessions_id => $s_id });
    my $out   = MT::Channel->attach($out_id);
    my ($ok, $rem) = $w_inv->reserve('VT-220', 1);
    if ($ok) {
        $w_bus->broadcast({ type => 'reserved', worker => $idx, rem => $rem });
    }
    $out->send($ok ? 'WIN' : 'FAIL');
}

# Freeze image before spawning MT::Worker threads
MT::Image::freeze();

my $inv_ids = $inv->state_ids;
my $bus_ids = $bus->state_ids;
my $res_ch  = MT::Channel->new(16);
my $res_id  = $res_ch->id;

# Spawn 8 MT::Worker threads racing on stock=5
my @workers;
for my $wid (1 .. 8) {
    my $w = MT::Worker::spawn(
        'main::race_worker',
        $inv_ids->{products_id},
        $inv_ids->{cells_id},
        $bus_ids->{sessions_id},
        $res_id,
        $wid,
    );
    push @workers, $w;
}

MT::Worker::join($_) for @workers;

my ($wins, $fails) = (0, 0);
for (1 .. 8) {
    my $r = $res_ch->recv;
    $wins++  if $r eq 'WIN';
    $fails++ if $r eq 'FAIL';
}

is($wins,  5, 'exactly 5 of 8 racing workers won CAS reservation');
is($fails, 3, 'exactly 3 of 8 racing workers failed CAS reservation');
is($inv->get_stock('VT-220'), 0, 'final stock is 0 (no oversell)');

# Verify EventBus received all 5 cross-worker broadcasts
my $events = $bus->poll_inbox($inbox);
is(scalar(@$events), 5, 'EventBus delivered 5 cross-worker broadcast events to main inbox');
$bus->unregister_session('sess-main');
is(scalar(@{ $bus->list_sessions }), 0, 'session unregistered cleanly');

# Test release + catalog filtering
is($inv->release('VT-220', 2), 2, 'release restores stock atomically');
my $terms = $inv->list_catalog(category => 'Terminals');
is(scalar(@$terms), 1, 'category filter returns 1 terminal');
my $search = $inv->list_catalog(query => 'deadbeef');
is(scalar(@$search), 1, 'search query finds mug');

# Test MT::Checkpoint save & restore
my ($fh, $ckpt_path) = tempfile(UNLINK => 1);
close $fh;
ok($inv->save_checkpoint($ckpt_path), 'save_checkpoint succeeded');

my $inv2 = Shop::State::Inventory->new;
my $loaded = $inv2->load_checkpoint($ckpt_path);
is($loaded, 2, 'load_checkpoint restored 2 products');
is($inv2->get_stock('VT-220'), 2, 'restored VT-220 stock == 2');
is($inv2->get_stock('AC-MUG'), 10, 'restored AC-MUG stock == 10');

done_testing;
