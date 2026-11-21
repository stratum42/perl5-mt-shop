package Shop::Metrics;

use strict;
use warnings;
use MT;
use MT::SharedHash;
use MT::Cell;

# Lock-free cross-worker Telemetry & Prometheus Metrics backed by MT::SharedHash + MT::Cell.
# Safe across MT::Image::freeze() and all MT::Worker threads with zero locks on reads/increments.

my @STANDARD_METRICS = (
    [ 'ssh_connections_total',        'counter', 'Total SSH TCP connections accepted' ],
    [ 'ssh_active_sessions',          'gauge',   'Currently active SSH TUI sessions' ],
    [ 'ssh_kex_pq_total',             'counter', 'SSH handshakes using post-quantum hybrid KEX' ],
    [ 'ssh_kex_classic_total',        'counter', 'SSH handshakes using classical KEX' ],
    [ 'ssh_auth_blocked_total',       'counter', 'SSH connections or auth attempts blocked by rate limiter' ],
    [ 'ssh_egress_full_bytes',        'counter', 'Estimated naive full-frame ANSI egress bytes' ],
    [ 'ssh_egress_diff_bytes',        'counter', 'Actual cell-diff ANSI egress bytes emitted' ],
    [ 'ssh_egress_wire_bytes',        'counter', 'Actual compressed wire egress bytes transmitted' ],
    [ 'inventory_cas_ok_total',       'counter', 'Successful lock-free MT::Cell CAS inventory operations' ],
    [ 'inventory_cas_conflict_total', 'counter', 'Lock-free MT::Cell CAS contention retries' ],
    [ 'orders_total',                 'counter', 'Total orders committed' ],
    [ 'webhooks_processed_total',     'counter', 'Total Stripe webhooks verified and processed' ],
    [ 'supervisor_faults_total',      'counter', 'Total MT::Supervisor worker faults detected' ],
);

my %METRIC_META = map { $_->[0] => { type => $_->[1], help => $_->[2] } } @STANDARD_METRICS;

sub new {
    my ($class) = @_;
    my $cells     = MT::SharedHash->new;
    my $ratelimit = MT::SharedHash->new;
    my %cache;

    # Pre-allocate all standard metric cells before MT::Image::freeze()
    for my $m (@STANDARD_METRICS) {
        my $name = $m->[0];
        my $cell = MT::Cell->new(0);
        $cells->set($name, $cell->id);
        $cache{$name} = $cell;
    }

    return bless {
        cells      => $cells,
        ratelimit  => $ratelimit,
        cell_cache => \%cache,
    }, $class;
}

sub attach {
    my ($class, $ids) = @_;
    die "Shop::Metrics::attach: ids hashref required\n" unless ref($ids) eq 'HASH';
    return bless {
        cells      => MT::SharedHash->attach($ids->{cells_id}),
        ratelimit  => MT::SharedHash->attach($ids->{ratelimit_id}),
        cell_cache => {},
    }, $class;
}

sub state_ids {
    my ($self) = @_;
    return {
        cells_id     => $self->{cells}->id,
        ratelimit_id => $self->{ratelimit}->id,
    };
}

sub _get_or_create_cell {
    my ($self, $name) = @_;
    return $self->{cell_cache}{$name} if exists $self->{cell_cache}{$name};
    my $cid = $self->{cells}->get($name);
    if (defined $cid) {
        my $cell = MT::Cell->attach($cid);
        $self->{cell_cache}{$name} = $cell;
        return $cell;
    }
    my $cell = MT::Cell->new(0);
    $self->{cells}->set($name, $cell->id);
    $self->{cell_cache}{$name} = $cell;
    return $cell;
}

sub inc {
    my ($self, $name, $delta) = @_;
    $delta = 1 unless defined $delta;
    $delta = int($delta);
    my $cell = $self->_get_or_create_cell($name);
    return int($cell->get) if $delta == 0;

    while (1) {
        my $cur = int($cell->get);
        my $nxt = $cur + $delta;
        return $nxt if $cell->cas($cur, $nxt);
    }
}

sub dec {
    my ($self, $name, $delta) = @_;
    $delta = 1 unless defined $delta;
    return $self->inc($name, -int($delta));
}

sub set {
    my ($self, $name, $val) = @_;
    $val = int($val // 0);
    my $cell = $self->_get_or_create_cell($name);
    $cell->set($val);
    return $val;
}

sub get {
    my ($self, $name) = @_;
    my $cell = $self->{cell_cache}{$name};
    if (!$cell) {
        my $cid = $self->{cells}->get($name);
        return 0 unless defined $cid;
        $cell = MT::Cell->attach($cid);
        $self->{cell_cache}{$name} = $cell;
    }
    return int($cell->get);
}

sub snapshot {
    my ($self) = @_;
    my %snap;
    for my $name ($self->{cells}->keys) {
        $snap{$name} = $self->get($name);
    }
    return \%snap;
}

sub prometheus_text {
    my ($self) = @_;
    my $snap = $self->snapshot;
    my @lines;

    # Emit standard metrics first in deterministic order, then any custom metrics
    my %seen;
    my @order = (map { $_->[0] } @STANDARD_METRICS);
    for my $k (sort keys %$snap) {
        push @order, $k unless exists $METRIC_META{$k};
    }

    for my $name (@order) {
        next if $seen{$name}++;
        my $val  = $snap->{$name} // 0;
        my $meta = $METRIC_META{$name} || { type => 'counter', help => "Custom metric $name" };
        push @lines,
            "# HELP $name $meta->{help}",
            "# TYPE $name $meta->{type}",
            "$name $val";
    }

    return join("\n", @lines) . "\n";
}

# Zero-network per-IP pre-auth fixed-window rate limiter backed by MT::SharedHash.
# Returns 1 (allowed) or 0 (blocked) in scalar context;
# ($allowed, $remaining, $reset_sec) in list context.
sub check_rate_limit {
    my ($self, $ip, $max_per_min) = @_;
    $ip          //= 'unknown';
    $max_per_min   = int($max_per_min // 60);
    $max_per_min   = 1 if $max_per_min < 1;

    my $now   = time();
    my $win   = int($now / 60);
    my $reset = 60 - ($now % 60);

    my $raw = $self->{ratelimit}->get($ip);
    my ($cur_win, $cnt) = (0, 0);
    if (defined $raw && $raw =~ /^(\d+):(\d+)$/) {
        ($cur_win, $cnt) = (int($1), int($2));
    }

    if ($cur_win != $win) {
        $cnt = 1;
    }
    else {
        $cnt++;
    }

    $self->{ratelimit}->set($ip, "$win:$cnt");

    if ($cnt > $max_per_min) {
        $self->inc('ssh_auth_blocked_total', 1);
        return wantarray ? (0, 0, $reset) : 0;
    }

    my $rem = $max_per_min - $cnt;
    return wantarray ? (1, $rem, $reset) : 1;
}

1;
