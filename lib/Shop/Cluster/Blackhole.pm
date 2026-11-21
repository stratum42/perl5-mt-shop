package Shop::Cluster::Blackhole;

use strict;
use warnings;
use Socket qw(SOL_SOCKET SO_LINGER);
use MT;
use MT::SharedHash;
use MT::Cell;
use Shop::Domain::JSON ();

# Pre-fiber O(1) DoS blackhole backed by MT::SharedHash and MT::Cell.
# Safe across MT::Image::freeze() and all MT::Worker threads.
# Drops banned peers with SO_LINGER {1, 0} before allocating fibers,
# SSH transport state, or TUI buffers.

sub new {
    my ($class, %opt) = @_;
    return bless {
        bans             => MT::SharedHash->new,
        strikes          => MT::SharedHash->new,
        blackholed_count => MT::Cell->new(0),
        banned_count     => MT::Cell->new(0),
        ban_ttl          => int($opt{ban_ttl}       // 300),
        strike_limit     => int($opt{strike_limit}  // 3),
        strike_window    => int($opt{strike_window} // 60),
        mode             => $opt{mode}       // 'drop',
        kernel_cmd       => $opt{kernel_cmd} // '',
    }, $class;
}

sub attach {
    my ($class, $ids, %opt) = @_;
    die "Shop::Cluster::Blackhole::attach: ids hashref required\n"
        unless ref($ids) eq 'HASH';
    return bless {
        bans             => MT::SharedHash->attach($ids->{bans_id}),
        strikes          => MT::SharedHash->attach($ids->{strikes_id}),
        blackholed_count => MT::Cell->attach($ids->{blackholed_count_id}),
        banned_count     => MT::Cell->attach($ids->{banned_count_id}),
        ban_ttl          => int($opt{ban_ttl}       // $ids->{ban_ttl}       // 300),
        strike_limit     => int($opt{strike_limit}  // $ids->{strike_limit}  // 3),
        strike_window    => int($opt{strike_window} // $ids->{strike_window} // 60),
        mode             => $opt{mode}       // $ids->{mode}       // 'drop',
        kernel_cmd       => $opt{kernel_cmd} // $ids->{kernel_cmd} // '',
    }, $class;
}

sub state_ids {
    my ($self) = @_;
    return {
        bans_id             => $self->{bans}->id,
        strikes_id          => $self->{strikes}->id,
        blackholed_count_id => $self->{blackholed_count}->id,
        banned_count_id     => $self->{banned_count}->id,
        ban_ttl             => $self->{ban_ttl},
        strike_limit        => $self->{strike_limit},
        strike_window       => $self->{strike_window},
        mode                => $self->{mode},
        kernel_cmd          => $self->{kernel_cmd},
    };
}

sub _cas_inc {
    my ($cell, $delta) = @_;
    $delta = int($delta // 1);
    return int($cell->get) if $delta == 0;
    while (1) {
        my $cur = int($cell->get);
        my $nxt = $cur + $delta;
        $nxt = 0 if $nxt < 0;
        return $nxt if $cell->cas($cur, $nxt);
    }
}

sub _parse_entry {
    my ($raw) = @_;
    return (0, '') unless defined $raw && length $raw;
    my $idx = index($raw, ':');
    return (0, '') if $idx <= 0;
    my $exp = substr($raw, 0, $idx);
    return (0, '') unless $exp =~ /^\d+$/;
    return (int($exp), substr($raw, $idx + 1));
}

sub _run_kernel_hook {
    my ($self, $ip) = @_;
    my $cmd = $self->{kernel_cmd};
    return 0 unless defined $cmd && length $cmd;
    # Only allow strict IPv4 or IPv6 literals to prevent argument injection
    return 0 unless defined $ip && $ip =~ /^[0-9a-fA-F:.]+$/;

    my @parts = split(/\s+/, $cmd);
    return 0 unless @parts;
    my $replaced = 0;
    for my $p (@parts) {
        if ($p =~ s/\%IP\%/$ip/g) {
            $replaced = 1;
        }
    }
    push @parts, $ip unless $replaced;

    eval { system(@parts) };
    return 1;
}

# O(1) pre-fiber ban lookup in MT::SharedHash.
sub is_banned {
    my ($self, $ip) = @_;
    return 0 unless defined $ip && length $ip;
    my $raw = $self->{bans}->get($ip);
    return 0 unless defined $raw;
    my ($exp) = _parse_entry($raw);
    return ($exp > time()) ? 1 : 0;
}

# Increment strike score for an IP. When score >= strike_limit, ban the IP
# locally, optionally broadcast and persist via KeyDB, and invoke kernel_cmd.
# Returns 1 if the IP is now banned, 0 otherwise.
sub record_violation {
    my ($self, $ip, $reason, $weight, $keydb) = @_;
    return 0 unless defined $ip && length $ip;

    $reason = defined $reason && length $reason ? "$reason" : 'violation';
    $reason =~ tr/\r\n/  /;
    $weight = int($weight // 1);
    $weight = 1 if $weight < 1;

    my $now = time();
    my ($old_exp, $old_score) = _parse_entry($self->{strikes}->get($ip));
    my $score = ($old_exp > $now && $old_score =~ /^\d+$/)
        ? (int($old_score) + $weight)
        : $weight;

    if ($score >= $self->{strike_limit}) {
        my $ttl        = $self->{ban_ttl} > 0 ? $self->{ban_ttl} : 300;
        my $was_banned = $self->is_banned($ip);
        my $ban_exp    = $now + $ttl;

        $self->{bans}->set($ip, "$ban_exp:$reason");
        $self->{strikes}->delete($ip);
        _cas_inc($self->{banned_count}, 1) unless $was_banned;

        if ($keydb) {
            eval {
                my $ban_key = $keydb->can('_k') ? $keydb->_k("dos:ban:$ip") : "dos:ban:$ip";
                if ($keydb->can('cmd')) {
                    $keydb->cmd('SETEX', $ban_key, $ttl, $reason);
                    my $ev = Shop::Domain::JSON::encode_json({
                        type   => 'dos_ban',
                        ip     => $ip,
                        reason => $reason,
                        ttl    => $ttl,
                    });
                    $keydb->cmd('PUBLISH', 'shop:cluster:events', $ev);
                }
                elsif ($keydb->can('set')) {
                    $keydb->set("dos:ban:$ip", $reason, $ttl);
                }
            };
        }

        $self->_run_kernel_hook($ip);
        return 1;
    }

    my $strike_exp = $now + ($self->{strike_window} > 0 ? $self->{strike_window} : 60);
    $self->{strikes}->set($ip, "$strike_exp:$score");
    return 0;
}

# Ingest a ban broadcast from a peer node into the local MT::SharedHash.
sub apply_remote_ban {
    my ($self, $ip, $ttl, $reason) = @_;
    return 0 unless defined $ip && length $ip;
    $ttl = int($ttl // $self->{ban_ttl});
    return 0 if $ttl <= 0;
    $reason = defined $reason && length $reason ? "$reason" : 'remote_ban';
    $reason =~ tr/\r\n/  /;

    my $now     = time();
    my $new_exp = $now + $ttl;
    my $raw     = $self->{bans}->get($ip);
    my ($cur_exp) = _parse_entry($raw);
    my $was_active = ($cur_exp > $now) ? 1 : 0;

    if ($new_exp > $cur_exp) {
        $self->{bans}->set($ip, "$new_exp:$reason");
        _cas_inc($self->{banned_count}, 1) unless $was_active;
        $self->_run_kernel_hook($ip) unless $was_active;
    }
    return 1;
}

# Zero-fiber blackhole: reset the TCP connection immediately with SO_LINGER {1, 0}
# and close the socket without spawning a fiber or transmitting any payload bytes.
sub shunt_socket {
    my ($self, $sock, $ip) = @_;
    if ($sock) {
        eval { setsockopt($sock, SOL_SOCKET, SO_LINGER, pack('ii', 1, 0)) };
        eval { close($sock) };
    }
    _cas_inc($self->{blackholed_count}, 1);
    return 1;
}

# Remove expired bans and strike records so MT::SharedHash stays bounded.
sub prune_expired {
    my ($self) = @_;
    my $now     = time();
    my $pruned  = 0;
    my $active  = 0;

    for my $ip ($self->{bans}->keys) {
        my ($exp) = _parse_entry($self->{bans}->get($ip));
        if ($exp <= $now) {
            $self->{bans}->delete($ip);
            $pruned++;
        }
        else {
            $active++;
        }
    }
    $self->{banned_count}->set($active);

    for my $ip ($self->{strikes}->keys) {
        my ($exp) = _parse_entry($self->{strikes}->get($ip));
        if ($exp <= $now) {
            $self->{strikes}->delete($ip);
            $pruned++;
        }
    }

    return $pruned;
}

sub stats {
    my ($self) = @_;
    return {
        blackholed_total => int($self->{blackholed_count}->get),
        banned_ips       => int($self->{banned_count}->get),
        mode             => $self->{mode},
    };
}

1;
