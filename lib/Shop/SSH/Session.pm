package Shop::SSH::Session;

use strict;
use warnings;
use Time::HiRes qw(time);
use Shop::SSH::Wire qw(:all);
use Shop::SSH::Transport;
use Shop::SSH::Auth;

use constant {
    LOCAL_WINDOW_SIZE  => 2 * 1024 * 1024,    # 2 MiB
    LOCAL_MAX_PACKET   => 32768,
    WINDOW_REFILL_MARK => 1024 * 1024,
};

sub new {
    my ($class, %args) = @_;
    my $transport = $args{transport} or die "Shop::SSH::Session: transport required";
    my $user      = $args{user}      or die "Shop::SSH::Session: user required";

    return bless {
        transport         => $transport,
        user              => $user,

        channel_open      => 0,
        local_chan        => 0,
        remote_chan       => undef,
        local_window      => LOCAL_WINDOW_SIZE,
        remote_window     => 0,
        remote_max_packet => 32768,

        term              => 'xterm-256color',
        cols              => 80,
        rows              => 24,
        resized           => 0,
        shell_started     => 0,
        exec_cmd          => undef,
        env               => {},

        input_buf         => '',
        eof               => 0,
        closed            => 0,
        sent_close        => 0,
    }, $class;
}

# Convenience all-in-one server-side acceptor:
#   my $sess = Shop::SSH::Session->accept(sock => $sock, hostkey => $hk, %opts);
sub accept {
    my ($class, %args) = @_;
    my $transport = Shop::SSH::Transport->new(
        sock              => $args{sock},
        hostkey           => $args{hostkey},
        compression_level => $args{compression_level},
        rekey_bytes       => $args{rekey_bytes},
    );
    $transport->handshake($args{handshake_timeout} // 15);
    my $user = Shop::SSH::Auth->authenticate(
        $transport,
        allow_guest      => exists($args{allow_guest}) ? $args{allow_guest} : 1,
        prefer_publickey => exists($args{prefer_publickey}) ? $args{prefer_publickey} : 1,
        timeout          => $args{auth_timeout} // 30,
        verify_key_cb    => $args{verify_key_cb},
    );
    my $sess = $class->new(transport => $transport, user => $user);
    $sess->open_session($args{session_timeout} // 15);
    return $sess;
}

sub open_session {
    my ($self, $timeout) = @_;
    $timeout //= 15;
    my $deadline = time() + $timeout;

    while (!$self->{shell_started} && !$self->{closed}) {
        my $rem = $deadline - time();
        die "SSH::Session: timeout waiting for session/shell" if $rem <= 0;

        my $pkt = $self->{transport}->recv_packet_blocking($rem);
        die "SSH::Session: EOF before shell started" unless defined $pkt;
        $self->_dispatch_packet($pkt);
    }
    return 1;
}

sub _dispatch_packet {
    my ($self, $pkt) = @_;
    return if !defined($pkt) || length($pkt) == 0;

    my $off = 0;
    my $mtype = unpack_byte($pkt, \$off);

    if ($mtype == SSH_MSG_CHANNEL_OPEN) {
        my $ctype  = unpack_string($pkt, \$off);
        my $rchan  = unpack_u32($pkt, \$off);
        my $rwin   = unpack_u32($pkt, \$off);
        my $rmax   = unpack_u32($pkt, \$off);

        if ($ctype eq 'session' && !$self->{channel_open}) {
            $self->{channel_open}      = 1;
            $self->{remote_chan}       = $rchan;
            $self->{remote_window}     = $rwin;
            $self->{remote_max_packet} = ($rmax > 0 && $rmax < 65536) ? $rmax : 32768;
            $self->{local_window}      = LOCAL_WINDOW_SIZE;

            my $conf = pack_byte(SSH_MSG_CHANNEL_OPEN_CONFIRMATION)
                     . pack_u32($rchan)
                     . pack_u32($self->{local_chan})
                     . pack_u32($self->{local_window})
                     . pack_u32(LOCAL_MAX_PACKET);
            $self->{transport}->send_packet($conf);
        } else {
            my $fail = pack_byte(SSH_MSG_CHANNEL_OPEN_FAILURE)
                     . pack_u32($rchan)
                     . pack_u32(3) # SSH_OPEN_UNKNOWN_CHANNEL_TYPE
                     . pack_string("Only single session channel supported")
                     . pack_string('');
            $self->{transport}->send_packet($fail);
        }
        return;
    }

    if ($mtype == SSH_MSG_CHANNEL_REQUEST) {
        my $lchan      = unpack_u32($pkt, \$off);
        my $req_type   = unpack_string($pkt, \$off);
        my $want_reply = unpack_bool($pkt, \$off);

        my $ok = 0;
        if ($req_type eq 'pty-req') {
            my $term = unpack_string($pkt, \$off);
            my $cols = unpack_u32($pkt, \$off);
            my $rows = unpack_u32($pkt, \$off);
            # px_w, px_h, modes follow (ignored)
            if (defined($term) && $term ne '') {
                $self->{term} = $term;
                $self->{env}{TERM} //= $term;
            }
            $self->{cols} = ($cols > 0 && $cols < 1000) ? $cols : 80;
            $self->{rows} = ($rows > 0 && $rows < 1000) ? $rows : 24;
            $ok = 1;
        } elsif ($req_type eq 'shell') {
            $self->{shell_started} = 1;
            $ok = 1;
        } elsif ($req_type eq 'exec') {
            my $cmd = unpack_string($pkt, \$off);
            $self->{exec_cmd}      = $cmd;
            $self->{shell_started} = 1;
            $ok = 1;
        } elsif ($req_type eq 'window-change') {
            my $cols = unpack_u32($pkt, \$off);
            my $rows = unpack_u32($pkt, \$off);
            if ($cols > 0 && $rows > 0 && $cols < 1000 && $rows < 1000) {
                if ($cols != $self->{cols} || $rows != $self->{rows}) {
                    $self->{cols}    = $cols;
                    $self->{rows}    = $rows;
                    $self->{resized} = 1;
                }
            }
            $ok = 1;
        } elsif ($req_type eq 'env') {
            my $name = eval { unpack_string($pkt, \$off) };
            my $val  = eval { unpack_string($pkt, \$off) };
            if (!$@ && defined($name) && length($name) > 0 && length($name) <= 128
                && defined($val) && length($val) <= 1024)
            {
                $self->{env}{$name} = $val;
            }
            $ok = 1;
        } elsif ($req_type eq 'keepalive@openssh.com') {
            $ok = 1;
        }

        if ($want_reply && defined $self->{remote_chan}) {
            my $resp = pack_byte($ok ? SSH_MSG_CHANNEL_SUCCESS : SSH_MSG_CHANNEL_FAILURE)
                     . pack_u32($self->{remote_chan});
            $self->{transport}->send_packet($resp);
        }
        return;
    }

    if ($mtype == SSH_MSG_CHANNEL_DATA) {
        my $lchan = unpack_u32($pkt, \$off);
        my $data  = unpack_string($pkt, \$off);
        my $dlen  = length($data);
        $self->{input_buf}    .= $data;
        $self->{local_window} -= $dlen;

        if ($self->{local_window} < WINDOW_REFILL_MARK && defined $self->{remote_chan}) {
            my $add = LOCAL_WINDOW_SIZE - $self->{local_window};
            $self->{local_window} += $add;
            my $adj = pack_byte(SSH_MSG_CHANNEL_WINDOW_ADJUST)
                    . pack_u32($self->{remote_chan})
                    . pack_u32($add);
            $self->{transport}->send_packet($adj, 1);
        }
        return;
    }

    if ($mtype == SSH_MSG_CHANNEL_WINDOW_ADJUST) {
        my $lchan = unpack_u32($pkt, \$off);
        my $add   = unpack_u32($pkt, \$off);
        $self->{remote_window} += $add;
        return;
    }

    if ($mtype == SSH_MSG_CHANNEL_EOF) {
        $self->{eof} = 1;
        return;
    }

    if ($mtype == SSH_MSG_CHANNEL_CLOSE) {
        $self->{eof}    = 1;
        $self->{closed} = 1;
        if (!$self->{sent_close} && defined $self->{remote_chan}) {
            $self->{sent_close} = 1;
            eval {
                $self->{transport}->send_packet(
                    pack_byte(SSH_MSG_CHANNEL_CLOSE) . pack_u32($self->{remote_chan}),
                    1
                );
            };
        }
        return;
    }

    if ($mtype == SSH_MSG_GLOBAL_REQUEST) {
        my $req_name   = unpack_string($pkt, \$off);
        my $want_reply = unpack_bool($pkt, \$off);
        if ($want_reply) {
            my $reply_type = ($req_name eq 'keepalive@openssh.com')
                ? SSH_MSG_REQUEST_SUCCESS
                : SSH_MSG_REQUEST_FAILURE;
            $self->{transport}->send_packet(pack_byte($reply_type), 1);
        }
        return;
    }
}

sub _pump_nonblock {
    my ($self) = @_;
    return if $self->{closed};

    for (1 .. 32) {
        my $pkt = $self->{transport}->recv_packet_nonblock();
        if (!defined $pkt) {
            $self->{eof}    = 1;
            $self->{closed} = 1;
            last;
        }
        last if $pkt eq '';
        $self->_dispatch_packet($pkt);
        last if $self->{closed};
    }
}

sub read_input_nonblock {
    my ($self) = @_;
    $self->_pump_nonblock();

    if (length($self->{input_buf}) > 0) {
        my $out = $self->{input_buf};
        $self->{input_buf} = '';
        return $out;
    }
    return undef if $self->{eof} || $self->{closed} || $self->{transport}->is_closed;
    return '';
}

sub write_output {
    my ($self, $bytes) = @_;
    return 0 if $self->{closed} || !$self->{channel_open} || !defined($self->{remote_chan});
    return 1 if !defined($bytes) || length($bytes) == 0;

    my $off   = 0;
    my $total = length($bytes);
    my $max_p = $self->{remote_max_packet};
    # Leave headroom for 9-byte SSH_MSG_CHANNEL_DATA header
    my $max_chunk = ($max_p > 64) ? ($max_p - 64) : 1024;

    while ($off < $total && !$self->{closed}) {
        if ($self->{remote_window} <= 0) {
            # Pump incoming packets waiting for SSH_MSG_CHANNEL_WINDOW_ADJUST
            my $deadline = time() + 10;
            while ($self->{remote_window} <= 0 && !$self->{closed}) {
                $self->_pump_nonblock();
                last if $self->{remote_window} > 0 || $self->{closed};
                return 0 if time() > $deadline;
                $self->{transport}->_yield_io(1, 0, 0.01);
            }
            last if $self->{closed};
        }

        my $rem   = $total - $off;
        my $chunk = $rem;
        $chunk = $max_chunk             if $chunk > $max_chunk;
        $chunk = $self->{remote_window} if $chunk > $self->{remote_window};

        my $slice = substr($bytes, $off, $chunk);
        my $pkt   = pack_byte(SSH_MSG_CHANNEL_DATA)
                  . pack_u32($self->{remote_chan})
                  . pack_string($slice);

        $self->{transport}->send_packet($pkt) or return 0;
        $self->{remote_window} -= $chunk;
        $off += $chunk;
    }

    return 1;
}

sub size {
    my ($self) = @_;
    return ($self->{cols}, $self->{rows});
}

sub poll_resize {
    my ($self) = @_;
    $self->_pump_nonblock();
    if ($self->{resized}) {
        $self->{resized} = 0;
        return ($self->{cols}, $self->{rows});
    }
    return ();
}

sub user {
    my ($self) = @_;
    return $self->{user};
}

sub term {
    my ($self) = @_;
    return $self->{term};
}

sub exec_cmd {
    my ($self) = @_;
    return $self->{exec_cmd};
}

sub transport {
    my ($self) = @_;
    return $self->{transport};
}

sub env {
    my ($self) = @_;
    return { %{ $self->{env} } };
}

sub security_info {
    my ($self) = @_;
    return $self->{transport}->security_info();
}

sub egress_stats {
    my ($self) = @_;
    my $st = $self->{transport}->stats();
    return {
        raw_tx_bytes  => $st->{raw_tx_bytes},
        wire_tx_bytes => $st->{wire_tx_bytes},
        compression   => $st->{compression},
    };
}

sub close {
    my ($self, $exit_status) = @_;
    $exit_status //= 0;

    if ($self->{channel_open} && defined($self->{remote_chan}) && !$self->{sent_close}) {
        $self->{sent_close} = 1;
        eval {
            # Send exit-status so OpenSSH exits with clean status code
            my $es = pack_byte(SSH_MSG_CHANNEL_REQUEST)
                   . pack_u32($self->{remote_chan})
                   . pack_string('exit-status')
                   . pack_bool(0)
                   . pack_u32($exit_status);
            $self->{transport}->send_packet($es);

            $self->{transport}->send_packet(
                pack_byte(SSH_MSG_CHANNEL_EOF) . pack_u32($self->{remote_chan})
            );
            $self->{transport}->send_packet(
                pack_byte(SSH_MSG_CHANNEL_CLOSE) . pack_u32($self->{remote_chan})
            );
            $self->{transport}->flush(0);

            # Wait briefly for peer's CHANNEL_CLOSE so OpenSSH exits cleanly with 0
            my $deadline = time() + 0.5;
            while (!$self->{closed} && time() < $deadline) {
                my $pkt = $self->{transport}->recv_packet_nonblock();
                if (!defined $pkt) {
                    $self->{closed} = 1;
                    last;
                }
                if ($pkt ne '') {
                    $self->_dispatch_packet($pkt);
                    last if $self->{closed};
                } else {
                    $self->{transport}->_yield_io(1, 0, 0.01);
                }
            }
        };
    }

    $self->{eof}    = 1;
    $self->{closed} = 1;
    eval { close($self->{transport}->sock) };
    return 1;
}

1;
