package Shop::Cluster::Wavefunction;

use strict;
use warnings;
use Digest::SHA qw(sha256 sha256_hex);

# Deterministic discrete-time cluster wavefunction for cooperative load routing.
# Uses no wall-clock time and relies only on IEEE-754 double arithmetic plus
# sin, cos, and sqrt so all perl5-mt nodes compute bit-identical states.

use constant TWO_PI => 6.28318530717958647692;

sub _sorted_unique {
    my ($list) = @_;
    return () unless ref($list) eq 'ARRAY';
    my %seen;
    my @out;
    for my $id (sort @$list) {
        next unless defined $id && length $id;
        next if $seen{$id}++;
        push @out, "$id";
    }
    return @out;
}

sub new {
    my ($class, %opt) = @_;
    my @nodes      = _sorted_unique($opt{nodes} || []);
    my $step       = int($opt{step} // 0);
    my $dt         = defined $opt{dt}         ? ($opt{dt} + 0.0)         : 0.15;
    my $coupling   = defined $opt{coupling}   ? ($opt{coupling} + 0.0)   : 0.35;
    my $load_alpha = defined $opt{load_alpha} ? ($opt{load_alpha} + 0.0) : 1.5;

    my $n = scalar(@nodes);
    my (@re, @im);
    if ($n > 0) {
        my $amp = 1.0 / sqrt($n + 0.0);
        @re = ($amp) x $n;
        @im = (0.0)  x $n;
    }

    my $self = bless {
        nodes      => \@nodes,
        re         => \@re,
        im         => \@im,
        step       => $step,
        dt         => $dt,
        coupling   => $coupling,
        load_alpha => $load_alpha,
    }, $class;

    $self->_normalize() if $n > 0;
    return $self;
}

sub step  { return $_[0]->{step}; }
sub dim   { return scalar(@{ $_[0]->{nodes} }); }
sub nodes { return [ @{ $_[0]->{nodes} } ]; }

sub _normalize {
    my ($self) = @_;
    my $re = $self->{re};
    my $im = $self->{im};
    my $n  = scalar(@$re);
    return 0.0 if $n == 0;

    my $norm_sq = 0.0;
    for (my $j = 0; $j < $n; $j++) {
        $norm_sq += $re->[$j] * $re->[$j] + $im->[$j] * $im->[$j];
    }

    if ($norm_sq <= 0.0) {
        my $amp = 1.0 / sqrt($n + 0.0);
        for (my $j = 0; $j < $n; $j++) {
            $re->[$j] = $amp;
            $im->[$j] = 0.0;
        }
        return 1.0;
    }

    my $inv = 1.0 / sqrt($norm_sq);
    for (my $j = 0; $j < $n; $j++) {
        my $r = $re->[$j] * $inv;
        my $i = $im->[$j] * $inv;
        $re->[$j] = ($r == 0.0) ? 0.0 : $r;
        $im->[$j] = ($i == 0.0) ? 0.0 : $i;
    }
    return 1.0;
}

# Advance logical step k -> k + steps using a split-step unitary ring propagator:
# 1. Load-repulsive diagonal phase kick: theta_j = -(load_alpha * load_j) * dt
# 2. Exact unitary ring kinetic step in discrete Fourier space with kappa = coupling * dt
# 3. Deterministic L2 renormalization
sub evolve {
    my ($self, $loads, $steps) = @_;
    $steps = defined $steps ? int($steps) : 1;
    return $self if $steps <= 0;

    my $nodes      = $self->{nodes};
    my $re         = $self->{re};
    my $im         = $self->{im};
    my $n          = scalar(@$nodes);
    my $dt         = $self->{dt};
    my $load_alpha = $self->{load_alpha};
    my $kappa      = $self->{coupling} * $dt;

    for (1 .. $steps) {
        $self->{step}++;
        next if $n == 0;

        # 1. Load-repulsive phase kick
        for (my $j = 0; $j < $n; $j++) {
            my $id   = $nodes->[$j];
            my $load = ($loads && defined $loads->{$id}) ? ($loads->{$id} + 0.0) : 0.0;
            $load = 0.0 if $load < 0.0;
            my $theta = -($load_alpha * $load) * $dt;
            if ($theta != 0.0) {
                my $c  = cos($theta);
                my $s  = sin($theta);
                my $rj = $re->[$j];
                my $ij = $im->[$j];
                $re->[$j] = $rj * $c - $ij * $s;
                $im->[$j] = $rj * $s + $ij * $c;
            }
        }

        # 2. Exact unitary ring Laplacian kinetic propagator via DFT:
        #    U_kin = F^dagger * diag(exp(-i * kappa * (2 - 2*cos(2*pi*m/N)))) * F
        if ($n >= 2 && $kappa != 0.0) {
            my $inv_sqrt_n = 1.0 / sqrt($n + 0.0);
            my (@fre, @fim);

            # Forward DFT + momentum-space phase rotation
            for (my $m = 0; $m < $n; $m++) {
                my $sr = 0.0;
                my $si = 0.0;
                my $base = TWO_PI * $m / $n;
                for (my $j = 0; $j < $n; $j++) {
                    my $ang = -$base * $j;
                    my $c   = cos($ang);
                    my $s   = sin($ang);
                    my $rj  = $re->[$j];
                    my $ij  = $im->[$j];
                    $sr += $rj * $c - $ij * $s;
                    $si += $rj * $s + $ij * $c;
                }
                $sr *= $inv_sqrt_n;
                $si *= $inv_sqrt_n;

                my $energy = 2.0 - 2.0 * cos($base);
                my $phi    = -$kappa * $energy;
                my $pc     = cos($phi);
                my $ps     = sin($phi);
                $fre[$m] = $sr * $pc - $si * $ps;
                $fim[$m] = $sr * $ps + $si * $pc;
            }

            # Inverse DFT
            for (my $j = 0; $j < $n; $j++) {
                my $sr = 0.0;
                my $si = 0.0;
                my $base = TWO_PI * $j / $n;
                for (my $m = 0; $m < $n; $m++) {
                    my $ang = $base * $m;
                    my $c   = cos($ang);
                    my $s   = sin($ang);
                    my $rm  = $fre[$m];
                    my $imv = $fim[$m];
                    $sr += $rm * $c - $imv * $s;
                    $si += $rm * $s + $imv * $c;
                }
                $re->[$j] = $sr * $inv_sqrt_n;
                $im->[$j] = $si * $inv_sqrt_n;
            }
        }

        # 3. Deterministic renormalization
        $self->_normalize();
    }

    return $self;
}

# Isometrically expand or contract the Hilbert space when nodes join or leave.
# Existing nodes keep their amplitudes; newly joined nodes receive real amplitude
# sqrt(1 / N_new); departed nodes are dropped; the resulting vector is renormalized.
sub resize {
    my ($self, $new_ids) = @_;
    my @new_nodes = _sorted_unique($new_ids || []);
    my $old_nodes = $self->{nodes};

    # Fast no-op check if topology is unchanged
    if (scalar(@new_nodes) == scalar(@$old_nodes)) {
        my $same = 1;
        for (my $i = 0; $i < @new_nodes; $i++) {
            if ($new_nodes[$i] ne $old_nodes->[$i]) {
                $same = 0;
                last;
            }
        }
        return $self if $same;
    }

    my $n_new = scalar(@new_nodes);
    if ($n_new == 0) {
        $self->{nodes} = [];
        $self->{re}    = [];
        $self->{im}    = [];
        return $self;
    }

    my %old_idx;
    for (my $i = 0; $i < @$old_nodes; $i++) {
        $old_idx{$old_nodes->[$i]} = $i;
    }

    my $old_re = $self->{re};
    my $old_im = $self->{im};
    my $seed   = sqrt(1.0 / ($n_new + 0.0));
    my (@re, @im);

    for (my $i = 0; $i < $n_new; $i++) {
        my $id = $new_nodes[$i];
        if (exists $old_idx{$id}) {
            my $oi = $old_idx{$id};
            $re[$i] = $old_re->[$oi];
            $im[$i] = $old_im->[$oi];
        }
        else {
            $re[$i] = $seed;
            $im[$i] = 0.0;
        }
    }

    $self->{nodes} = \@new_nodes;
    $self->{re}    = \@re;
    $self->{im}    = \@im;
    $self->_normalize();
    return $self;
}

# Return { node_id => prob } summing to 1.0, combining Born density |psi_j|^2
# with load-repulsive damping 1 / (1 + load_alpha * load_j).
sub probabilities {
    my ($self, $loads) = @_;
    my $nodes = $self->{nodes};
    my $re    = $self->{re};
    my $im    = $self->{im};
    my $n     = scalar(@$nodes);
    return {} if $n == 0;

    my $alpha = $self->{load_alpha};
    my @weights;
    my $total = 0.0;

    for (my $j = 0; $j < $n; $j++) {
        my $id   = $nodes->[$j];
        my $born = $re->[$j] * $re->[$j] + $im->[$j] * $im->[$j];
        my $load = ($loads && defined $loads->{$id}) ? ($loads->{$id} + 0.0) : 0.0;
        $load = 0.0 if $load < 0.0;
        my $damp = 1.0 / (1.0 + $alpha * $load);
        my $w    = $born * $damp;
        $weights[$j] = $w;
        $total += $w;
    }

    my %probs;
    if ($total > 0.0) {
        for (my $j = 0; $j < $n; $j++) {
            $probs{$nodes->[$j]} = $weights[$j] / $total;
        }
    }
    else {
        my $u = 1.0 / ($n + 0.0);
        for (my $j = 0; $j < $n; $j++) {
            $probs{$nodes->[$j]} = $u;
        }
    }
    return \%probs;
}

# Deterministically pick a target node_id from cumulative probabilities
# using SHA-256 of key_str mapped to [0, 1).
sub route {
    my ($self, $key_str, $loads) = @_;
    my $nodes = $self->{nodes};
    my $n     = scalar(@$nodes);
    return undef if $n == 0;
    return $nodes->[0] if $n == 1;

    my $probs  = $self->probabilities($loads);
    my $digest = sha256(defined $key_str ? "$key_str" : '');
    my ($hi, $lo) = unpack('NN', $digest);
    # 53-bit IEEE-754 uniform double in [0, 1)
    my $u = (($hi * 2097152.0) + int($lo / 2048)) / 9007199254740992.0;

    my $cum = 0.0;
    for (my $j = 0; $j < $n; $j++) {
        my $id = $nodes->[$j];
        $cum += $probs->{$id};
        return $id if $u < $cum;
    }
    return $nodes->[$n - 1];
}

sub norm {
    my ($self) = @_;
    my $re = $self->{re};
    my $im = $self->{im};
    my $n  = scalar(@$re);
    return 0.0 if $n == 0;

    my $sum = 0.0;
    for (my $j = 0; $j < $n; $j++) {
        $sum += $re->[$j] * $re->[$j] + $im->[$j] * $im->[$j];
    }
    return sqrt($sum);
}

sub state_digest {
    my ($self) = @_;
    my $nodes = $self->{nodes};
    my $re    = $self->{re};
    my $im    = $self->{im};
    my $n     = scalar(@$nodes);

    my $buf = pack('NN', $self->{step}, $n);
    for (my $j = 0; $j < $n; $j++) {
        my $r = ($re->[$j] == 0.0) ? 0.0 : $re->[$j];
        my $i = ($im->[$j] == 0.0) ? 0.0 : $im->[$j];
        $buf .= pack('d<d<', $r, $i);
    }
    return sha256_hex($buf);
}

sub snapshot {
    my ($self, $loads) = @_;
    return {
        step          => $self->{step},
        dim           => $self->dim,
        nodes         => $self->nodes,
        norm          => $self->norm,
        digest        => $self->state_digest,
        probabilities => $self->probabilities($loads),
    };
}

1;
