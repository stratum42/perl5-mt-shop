package Shop::SSH::Transport;

use strict;
use warnings;
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Time::HiRes qw(time);
use Shop::SSH::Crypto qw(
    random_bytes
    x25519_keypair
    x25519_shared
    mlkem768_encapsulate
    ed25519_sign
    sha256
    chacha20_poly1305_openssh_encrypt
    chacha20_poly1305_openssh_decrypt_len
    chacha20_poly1305_openssh_decrypt_body
    aes256_gcm_openssh_encrypt
    aes256_gcm_openssh_decrypt
);
use Shop::SSH::Wire qw(:all);

use constant {
    SERVER_VERSION     => 'SSH-2.0-perl5mt_shop_2.0',
    MAX_PACKET_SIZE    => 262144,            # 256 KiB safety cap
    DEFAULT_REKEY_BYTES => 512 * 1024 * 1024, # 512 MiB
};

sub new {
    my ($class, %args) = @_;
    my $sock    = $args{sock}    or die "Shop::SSH::Transport: sock required";
    my $hostkey = $args{hostkey} or die "Shop::SSH::Transport: hostkey required";

    # Put socket into non-blocking mode
    my $flags = fcntl($sock, F_GETFL, 0);
    if (defined $flags) {
        fcntl($sock, F_SETFL, $flags | O_NONBLOCK);
    }

    my $self = bless {
        sock              => $sock,
        hostkey           => $hostkey,
        compression_level => defined($args{compression_level}) ? $args{compression_level} : 5,
        rekey_limit       => defined($args{rekey_bytes}) ? $args{rekey_bytes} : DEFAULT_REKEY_BYTES,

        rx_buf            => '',
        tx_buf            => '',
        closed            => 0,

        tx_seq            => 0,
        rx_seq            => 0,

        tx_enc            => 0,
        rx_enc            => 0,
        tx_cipher         => 'none',
        rx_cipher         => 'none',
        tx_k1             => undef,
        tx_k2             => undef,
        tx_iv             => undef,
        tx_gcm_seq        => 0,
        rx_k1             => undef,
        rx_k2             => undef,
        rx_iv             => undef,
        rx_gcm_seq        => 0,

        s2c_comp          => 'none',
        c2s_comp          => 'none',
        tx_zlib           => undef,
        rx_zlib           => undef,
        comp_active       => 0,

        server_version    => SERVER_VERSION,
        client_version    => undef,
        session_id        => undef,
        kex_algo          => undef,
        strict_kex        => 0,
        in_initial_kex    => 0,
        in_rekey          => 0,
        rekey_sent_I_S    => undef,
        rekey_count       => 0,
        rekey_tx_bytes    => 0,
        rekey_rx_bytes    => 0,
        client_wants_ext  => 0,

        # Cached decrypted length for partial encrypted packet reads
        _pending_rx_len   => undef,
        _deferred_rx      => [],

        # Telemetry
        raw_tx_bytes      => 0,
        wire_tx_bytes     => 0,
        raw_rx_bytes      => 0,
        wire_rx_bytes     => 0,
    }, $class;

    return $self;
}

sub session_id { $_[0]->{session_id} }
sub is_closed  { $_[0]->{closed} }
sub sock       { $_[0]->{sock} }
sub kex_algo   { $_[0]->{kex_algo} }
sub cipher     { $_[0]->{tx_cipher} }
sub strict_kex { $_[0]->{strict_kex} }
sub rekey_count { $_[0]->{rekey_count} }

sub security_info {
    my ($self) = @_;
    my $kex = $self->{kex_algo} // 'none';
    return {
        kex         => $kex,
        cipher      => $self->{tx_cipher} // 'none',
        compression => $self->{comp_active} ? $self->{s2c_comp} : 'none',
        strict_kex  => $self->{strict_kex} ? 1 : 0,
        is_pq       => ($kex =~ /^mlkem/i) ? 1 : 0,
    };
}

sub stats {
    my ($self) = @_;
    return {
        raw_tx_bytes  => $self->{raw_tx_bytes},
        wire_tx_bytes => $self->{wire_tx_bytes},
        raw_rx_bytes  => $self->{raw_rx_bytes},
        wire_rx_bytes => $self->{wire_rx_bytes},
        compression   => $self->{comp_active} ? $self->{s2c_comp} : 'none',
        kex           => $self->{kex_algo} // 'none',
        cipher        => $self->{tx_cipher} // 'none',
        strict_kex    => $self->{strict_kex} ? 1 : 0,
        rekey_count   => $self->{rekey_count},
    };
}

sub _in_fiber {
    return (defined(&MT::Fiber::current) && MT::Fiber::current()) ? 1 : 0;
}

sub _yield_io {
    my ($self, $want_read, $want_write, $timeout) = @_;
    $timeout //= 0.01;

    if (_in_fiber()) {
        # Never block the worker OS thread (or hit select() FD_SETSIZE=1024) inside a fiber!
        MT::Fiber::pass();
        return;
    }

    my $fd = fileno($self->{sock});
    if (defined $fd && $fd >= 0) {
        if (eval { require IO::Poll; 1 }) {
            my $p = IO::Poll->new();
            my $mask = 0;
            $mask |= IO::Poll::POLLIN()  if $want_read;
            $mask |= IO::Poll::POLLOUT() if $want_write;
            $p->mask($self->{sock}, $mask);
            $p->poll($timeout);
        } else {
            my ($rin, $win) = ('', '');
            vec($rin, $fd, 1) = 1 if $want_read && $fd < 1024;
            vec($win, $fd, 1) = 1 if $want_write && $fd < 1024;
            select($rin, $win, undef, $timeout);
        }
    }
}

sub _write_raw {
    my ($self, $bytes) = @_;
    return 0 if $self->{closed};
    $self->{tx_buf} .= $bytes;
    return $self->flush(0);
}

sub flush {
    my ($self, $nonblock) = @_;
    return 0 if $self->{closed};

    while (length($self->{tx_buf}) > 0) {
        my $n = syswrite($self->{sock}, $self->{tx_buf});
        if (defined $n) {
            if ($n == 0) {
                $self->{closed} = 1;
                return 0;
            }
            substr($self->{tx_buf}, 0, $n, '');
        } elsif ($! == EINTR) {
            next;
        } elsif ($! == EAGAIN || $! == EWOULDBLOCK) {
            return 1 if $nonblock;
            $self->_yield_io(0, 1, 0.01);
        } else {
            $self->{closed} = 1;
            return 0;
        }
    }
    return 1;
}

sub _fill_rx {
    my ($self) = @_;
    return undef if $self->{closed};

    my $total = 0;
    for (1 .. 8) {
        my $buf = '';
        my $n = sysread($self->{sock}, $buf, 16384);
        if (defined $n) {
            if ($n == 0) {
                $self->{closed} = 1;
                return $total > 0 ? $total : undef;
            }
            $self->{rx_buf} .= $buf;
            $total += $n;
            last if $n < 16384;
        } elsif ($! == EINTR) {
            next;
        } elsif ($! == EAGAIN || $! == EWOULDBLOCK) {
            last;
        } else {
            $self->{closed} = 1;
            return $total > 0 ? $total : undef;
        }
    }
    return $total;
}

sub _read_banner_line {
    my ($self, $deadline) = @_;
    while (1) {
        if ((my $idx = index($self->{rx_buf}, "\n")) >= 0) {
            my $line = substr($self->{rx_buf}, 0, $idx + 1, '');
            $line =~ s/\r?\n\z//;
            return $line;
        }
        return undef if length($self->{rx_buf}) > 512;
        my $got = $self->_fill_rx();
        return undef if !defined($got) && length($self->{rx_buf}) == 0;
        if (defined($got) && $got == 0) {
            return undef if defined($deadline) && time() > $deadline;
            $self->_yield_io(1, 0, 0.01);
        }
    }
}

sub _negotiate {
    my ($client_list, $server_list) = @_;
    my %srv = map { $_ => 1 } @$server_list;
    for my $alg (@$client_list) {
        return $alg if $srv{$alg};
    }
    return undef;
}

sub _derive_key {
    my ($K_encoded, $H, $letter, $session_id, $need_bytes) = @_;
    my $k = sha256($K_encoded . $H . $letter . $session_id);
    while (length($k) < $need_bytes) {
        $k .= sha256($K_encoded . $H . $k);
    }
    return substr($k, 0, $need_bytes);
}

sub _build_kexinit {
    my ($self, $is_initial) = @_;
    my @srv_kex = ('mlkem768x25519-sha256', 'curve25519-sha256', 'curve25519-sha256@libssh.org');
    push @srv_kex, 'kex-strict-s-v00@openssh.com' if $is_initial;
    my @srv_hk   = ('ssh-ed25519');
    my @srv_enc  = ('chacha20-poly1305@openssh.com', 'aes256-gcm@openssh.com');
    my @srv_mac  = ('hmac-sha2-256');
    my @srv_comp = ('zlib@openssh.com', 'none');

    return pack_byte(SSH_MSG_KEXINIT)
         . random_bytes(16)
         . pack_namelist(@srv_kex)
         . pack_namelist(@srv_hk)
         . pack_namelist(@srv_enc)
         . pack_namelist(@srv_enc)
         . pack_namelist(@srv_mac)
         . pack_namelist(@srv_mac)
         . pack_namelist(@srv_comp)
         . pack_namelist(@srv_comp)
         . pack_namelist()
         . pack_namelist()
         . pack_bool(0)
         . pack_u32(0);
}

sub handshake {
    my ($self, $timeout) = @_;
    $timeout //= 15;
    my $deadline = time() + $timeout;

    # 1. Send server version banner
    $self->_write_raw($self->{server_version} . "\r\n")
        or die "SSH::Transport: failed to send version banner";

    # 2. Read client version banner (skipping any pre-banner comment lines)
    my $client_ver;
    for (1 .. 16) {
        my $line = $self->_read_banner_line($deadline);
        die "SSH::Transport: EOF/timeout reading client banner" unless defined $line;
        if ($line =~ /^SSH-/) {
            $client_ver = $line;
            last;
        }
    }
    die "SSH::Transport: invalid client banner"
        unless defined($client_ver) && $client_ver =~ /^SSH-(?:2\.0|1\.99)-/;
    $self->{client_version} = $client_ver;

    return $self->_perform_kex(
        is_initial => 1,
        deadline   => $deadline,
    );
}

sub _perform_kex {
    my ($self, %opts) = @_;
    my $is_initial     = $opts{is_initial} ? 1 : 0;
    my $deadline       = $opts{deadline} // (time() + 15);
    my $client_kexinit = $opts{client_kexinit};

    $self->{in_initial_kex} = 1 if $is_initial;
    $self->{in_rekey}       = 1 unless $is_initial;

    # Server KEX algorithms (excluding pseudo-algorithms from actual KEX negotiation)
    my @srv_kex_real = ('mlkem768x25519-sha256', 'curve25519-sha256', 'curve25519-sha256@libssh.org');
    my @srv_hk       = ('ssh-ed25519');
    my @srv_enc      = ('chacha20-poly1305@openssh.com', 'aes256-gcm@openssh.com');
    my @srv_comp     = ('zlib@openssh.com', 'none');

    # 1. Send server KEXINIT (unless already sent for server-initiated rekey)
    my $I_S;
    if (!$is_initial && defined $self->{rekey_sent_I_S}) {
        $I_S = delete $self->{rekey_sent_I_S};
    } else {
        $I_S = $self->_build_kexinit($is_initial);
        $self->send_packet($I_S) or die "SSH::Transport: failed to send KEXINIT";
    }

    # 2. Read client KEXINIT (unless passed in from client-initiated rekey)
    my $I_C = $client_kexinit;
    my $kexinit_seq;
    if (!defined $I_C) {
        if ($is_initial) {
            $kexinit_seq = $self->{rx_seq};
            $I_C = $self->recv_packet_blocking($deadline - time());
            die "SSH::Transport: EOF/timeout waiting for client KEXINIT" unless defined $I_C;
        } else {
            # Server-initiated rekey: peer may have in-flight packets before its KEXINIT
            while (1) {
                my $pkt = $self->recv_packet_blocking($deadline - time());
                die "SSH::Transport: EOF/timeout waiting for client rekey KEXINIT" unless defined $pkt;
                my $mt = ord(substr($pkt, 0, 1));
                if ($mt == SSH_MSG_KEXINIT) {
                    $I_C = $pkt;
                    last;
                }
                push @{ $self->{_deferred_rx} }, $pkt;
            }
        }
    }

    my $off = 0;
    my $msg_type = unpack_byte($I_C, \$off);
    if ($msg_type != SSH_MSG_KEXINIT) {
        $self->disconnect(SSH_DISCONNECT_PROTOCOL_ERROR, "Expected KEXINIT (20), got $msg_type");
        die "SSH::Transport: expected KEXINIT (20), got $msg_type";
    }

    $off += 16; # skip client cookie
    my $cli_kex     = unpack_namelist($I_C, \$off);
    my $cli_hk      = unpack_namelist($I_C, \$off);
    my $cli_enc_c2s = unpack_namelist($I_C, \$off);
    my $cli_enc_s2c = unpack_namelist($I_C, \$off);
    my $cli_mac_c2s = unpack_namelist($I_C, \$off);
    my $cli_mac_s2c = unpack_namelist($I_C, \$off);
    my $cli_cmp_c2s = unpack_namelist($I_C, \$off);
    my $cli_cmp_s2c = unpack_namelist($I_C, \$off);
    my $cli_lang_c  = unpack_namelist($I_C, \$off);
    my $cli_lang_s  = unpack_namelist($I_C, \$off);
    my $first_follows = unpack_bool($I_C, \$off);

    if ($is_initial) {
        $self->{client_wants_ext} = (grep { $_ eq 'ext-info-c' } @$cli_kex) ? 1 : 0;
        $self->{strict_kex}       = (grep { $_ eq 'kex-strict-c-v00@openssh.com' } @$cli_kex) ? 1 : 0;
        if ($self->{strict_kex} && defined($kexinit_seq) && $kexinit_seq != 0) {
            $self->disconnect(SSH_DISCONNECT_PROTOCOL_ERROR, 'Strict KEX: KEXINIT must be seq 0');
            die "SSH::Transport: Strict KEX violation (KEXINIT seq=$kexinit_seq != 0)";
        }
    }

    my $kex_alg = _negotiate($cli_kex, \@srv_kex_real)
        or do {
            $self->disconnect(SSH_DISCONNECT_KEY_EXCHANGE_FAILED, 'No common KEX algorithm');
            die "SSH::Transport: no common KEX algorithm";
        };
    my $hk_alg  = _negotiate($cli_hk, \@srv_hk)
        or do {
            $self->disconnect(SSH_DISCONNECT_KEY_EXCHANGE_FAILED, 'No common hostkey algorithm');
            die "SSH::Transport: no common hostkey algorithm";
        };
    my $enc_c2s = _negotiate($cli_enc_c2s, \@srv_enc)
        or do {
            $self->disconnect(SSH_DISCONNECT_KEY_EXCHANGE_FAILED, 'No common c2s cipher');
            die "SSH::Transport: no common c2s cipher";
        };
    my $enc_s2c = _negotiate($cli_enc_s2c, \@srv_enc)
        or do {
            $self->disconnect(SSH_DISCONNECT_KEY_EXCHANGE_FAILED, 'No common s2c cipher');
            die "SSH::Transport: no common s2c cipher";
        };
    my $cmp_c2s = _negotiate($cli_cmp_c2s, \@srv_comp) || 'none';
    my $cmp_s2c = _negotiate($cli_cmp_s2c, \@srv_comp) || 'none';

    $self->{c2s_comp} = $cmp_c2s;
    $self->{s2c_comp} = $cmp_s2c;

    # Discard guessed packet if client guessed wrong
    if ($first_follows && (($cli_kex->[0] // '') ne $kex_alg || ($cli_hk->[0] // '') ne $hk_alg)) {
        $self->recv_packet_blocking($deadline - time());
    }

    # 3. Read KEX init packet (opcode 30: SSH_MSG_KEX_ECDH_INIT / SSH_MSG_KEX_HYBRID_INIT)
    my $kex_init = $self->recv_packet_blocking($deadline - time());
    die "SSH::Transport: EOF/timeout waiting for KEX_INIT (30)" unless defined $kex_init;
    $off = 0;
    $msg_type = unpack_byte($kex_init, \$off);
    if ($msg_type != SSH_MSG_KEX_ECDH_INIT) {
        $self->disconnect(SSH_DISCONNECT_PROTOCOL_ERROR, "Strict KEX violation: expected opcode 30, got $msg_type");
        die "SSH::Transport: expected KEX_INIT (30), got $msg_type";
    }

    my $Q_C = unpack_string($kex_init, \$off);
    my ($Q_S, $K_encoded);

    if ($kex_alg eq 'mlkem768x25519-sha256') {
        # Post-Quantum Hybrid KEX: C_INIT = ML-KEM-768 ek (1184) || X25519 pk (32)
        if (length($Q_C) != 1216) {
            $self->disconnect(SSH_DISCONNECT_KEY_EXCHANGE_FAILED, 'Invalid mlkem768x25519 C_INIT length');
            die "SSH::Transport: invalid mlkem768x25519 C_INIT length " . length($Q_C);
        }
        my $ek_1184       = substr($Q_C, 0, 1184);
        my $cli_x25519_pk = substr($Q_C, 1184, 32);

        my ($ct_1088, $ss_pq) = mlkem768_encapsulate($ek_1184);
        my ($srv_priv, $srv_x25519_pk) = x25519_keypair();
        my $ss_x25519 = x25519_shared($srv_priv, $cli_x25519_pk);
        if (!defined $ss_x25519) {
            $self->disconnect(SSH_DISCONNECT_KEY_EXCHANGE_FAILED, 'Invalid X25519 shared secret');
            die "SSH::Transport: invalid X25519 shared secret";
        }

        $Q_S = $ct_1088 . $srv_x25519_pk; # 1088 + 32 = 1120 bytes
        my $K_raw = sha256($ss_pq . $ss_x25519);
        # Per draft-kampanakis-curdle-ssh-pq-ke / OpenSSH: K is encoded as SSH string, NOT mpint!
        $K_encoded = pack_string($K_raw);
    } else {
        # Classical curve25519-sha256
        if (length($Q_C) != 32) {
            $self->disconnect(SSH_DISCONNECT_KEY_EXCHANGE_FAILED, 'Invalid client X25519 key length');
            die "SSH::Transport: invalid client X25519 key length";
        }
        my ($srv_priv, $srv_pk) = x25519_keypair();
        my $K_raw = x25519_shared($srv_priv, $Q_C);
        if (!defined $K_raw) {
            $self->disconnect(SSH_DISCONNECT_KEY_EXCHANGE_FAILED, 'Invalid X25519 shared secret');
            die "SSH::Transport: invalid X25519 shared secret";
        }
        $Q_S       = $srv_pk;
        $K_encoded = pack_mpint($K_raw);
    }

    # 4. Compute exchange hash H and hostkey signature
    my $K_S = $self->{hostkey}{pubkey_blob};
    my $H = sha256(
        pack_string($self->{client_version}) .
        pack_string($self->{server_version}) .
        pack_string($I_C) .
        pack_string($I_S) .
        pack_string($K_S) .
        pack_string($Q_C) .
        pack_string($Q_S) .
        $K_encoded
    );
    $self->{session_id} //= $H;

    my $sig_raw  = ed25519_sign($H, $self->{hostkey}{sk});
    my $sig_blob = pack_string('ssh-ed25519') . pack_string($sig_raw);

    my $reply = pack_byte(SSH_MSG_KEX_ECDH_REPLY)
              . pack_string($K_S)
              . pack_string($Q_S)
              . pack_string($sig_blob);
    $self->send_packet($reply) or die "SSH::Transport: failed to send KEX_REPLY";

    # 5. Derive symmetric keys (and IVs for AES-256-GCM)
    my ($tx_k1, $tx_k2, $tx_iv);
    my ($rx_k1, $rx_k2, $rx_iv);

    if ($enc_s2c eq 'aes256-gcm@openssh.com') {
        $tx_iv = _derive_key($K_encoded, $H, 'B', $self->{session_id}, 12);
        $tx_k1 = _derive_key($K_encoded, $H, 'D', $self->{session_id}, 32);
    } else {
        my $key_s2c = _derive_key($K_encoded, $H, 'D', $self->{session_id}, 64);
        $tx_k1 = substr($key_s2c, 0, 32);
        $tx_k2 = substr($key_s2c, 32, 32);
    }

    if ($enc_c2s eq 'aes256-gcm@openssh.com') {
        $rx_iv = _derive_key($K_encoded, $H, 'A', $self->{session_id}, 12);
        $rx_k1 = _derive_key($K_encoded, $H, 'C', $self->{session_id}, 32);
    } else {
        my $key_c2s = _derive_key($K_encoded, $H, 'C', $self->{session_id}, 64);
        $rx_k1 = substr($key_c2s, 0, 32);
        $rx_k2 = substr($key_c2s, 32, 32);
    }

    # 6. Send SSH_MSG_NEWKEYS and activate tx cipher
    $self->send_packet(pack_byte(SSH_MSG_NEWKEYS))
        or die "SSH::Transport: failed to send NEWKEYS";

    $self->{tx_cipher}      = $enc_s2c;
    $self->{tx_k1}          = $tx_k1;
    $self->{tx_k2}          = $tx_k2;
    $self->{tx_iv}          = $tx_iv;
    $self->{tx_gcm_seq}     = 0;
    $self->{tx_enc}         = 1;
    $self->{rekey_tx_bytes} = 0;

    # CVE-2023-48795 Terrapin mitigation (OpenSSH strict-kex): reset tx_seq=0 on NEWKEYS
    if ($self->{strict_kex}) {
        $self->{tx_seq} = 0;
    }

    # On mid-session rekey, OpenSSH resets compression streams at NEWKEYS
    if (!$is_initial && $self->{comp_active}) {
        $self->{tx_zlib} = ($self->{s2c_comp} eq 'zlib@openssh.com')
            ? Shop::SSH::Crypto::Zlib->new($self->{compression_level})
            : undef;
    }

    # RFC 8308: send SSH_MSG_EXT_INFO immediately after initial server NEWKEYS if client asked
    if ($is_initial && $self->{client_wants_ext}) {
        my $ext = pack_byte(SSH_MSG_EXT_INFO)
                . pack_u32(1)
                . pack_string('server-sig-algs')
                . pack_string('ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-256,rsa-sha2-512');
        $self->send_packet($ext);
    }

    # 7. Receive client SSH_MSG_NEWKEYS and activate rx cipher
    my $cli_nk = $self->recv_packet_blocking($deadline - time());
    die "SSH::Transport: EOF/timeout waiting for client NEWKEYS" unless defined $cli_nk;
    $off = 0;
    $msg_type = unpack_byte($cli_nk, \$off);
    if ($msg_type != SSH_MSG_NEWKEYS) {
        $self->disconnect(SSH_DISCONNECT_PROTOCOL_ERROR, "Strict KEX violation: expected NEWKEYS (21), got $msg_type");
        die "SSH::Transport: expected NEWKEYS (21), got $msg_type";
    }

    $self->{rx_cipher}      = $enc_c2s;
    $self->{rx_k1}          = $rx_k1;
    $self->{rx_k2}          = $rx_k2;
    $self->{rx_iv}          = $rx_iv;
    $self->{rx_gcm_seq}     = 0;
    $self->{rx_enc}         = 1;
    $self->{rekey_rx_bytes} = 0;

    # CVE-2023-48795 Terrapin mitigation (OpenSSH strict-kex): reset rx_seq=0 on NEWKEYS
    if ($self->{strict_kex}) {
        $self->{rx_seq} = 0;
    }

    # On mid-session rekey, OpenSSH resets compression streams at NEWKEYS
    if (!$is_initial && $self->{comp_active}) {
        $self->{rx_zlib} = ($self->{c2s_comp} eq 'zlib@openssh.com')
            ? Shop::SSH::Crypto::Zlib->new($self->{compression_level})
            : undef;
    }

    $self->{kex_algo}       = $kex_alg;
    $self->{in_initial_kex} = 0;
    $self->{in_rekey}       = 0;
    $self->{rekey_count}++ unless $is_initial;

    return 1;
}

sub _handle_rekey {
    my ($self, $client_kexinit) = @_;
    eval {
        $self->_perform_kex(
            is_initial     => 0,
            deadline       => time() + 15,
            client_kexinit => $client_kexinit,
        );
    };
    if ($@) {
        $self->{in_rekey} = 0;
        $self->disconnect(SSH_DISCONNECT_KEY_EXCHANGE_FAILED, 'Rekey failed');
        return 0;
    }
    return 1;
}

sub enable_compression {
    my ($self) = @_;
    return if $self->{comp_active};

    my $lvl = $self->{compression_level};
    if ($self->{s2c_comp} eq 'zlib@openssh.com') {
        $self->{tx_zlib} = Shop::SSH::Crypto::Zlib->new($lvl);
    }
    if ($self->{c2s_comp} eq 'zlib@openssh.com') {
        $self->{rx_zlib} = Shop::SSH::Crypto::Zlib->new($lvl);
    }
    $self->{comp_active} = 1;
    return $self->{s2c_comp};
}

sub send_packet {
    my ($self, $payload, $nonblock) = @_;
    return 0 if $self->{closed};

    my $raw_len = length($payload);
    $self->{raw_tx_bytes} += $raw_len;

    my $body = $payload;
    if ($self->{comp_active} && $self->{tx_zlib}) {
        $body = $self->{tx_zlib}->deflate($payload);
    }

    my $body_len = length($body);
    my $pad_len;
    if ($self->{tx_enc}) {
        my $block = ($self->{tx_cipher} eq 'aes256-gcm@openssh.com') ? 16 : 8;
        # Both chacha20-poly1305@openssh.com and aes256-gcm@openssh.com exclude 4-byte length from alignment
        $pad_len = $block - ((1 + $body_len) % $block);
        $pad_len += $block if $pad_len < 4;
    } else {
        my $block = 8;
        # Unencrypted: 4-byte packet_length included in multiple-of-8 alignment
        $pad_len = $block - ((4 + 1 + $body_len) % $block);
        $pad_len += $block if $pad_len < 4;
    }

    my $padding = random_bytes($pad_len);
    my $inner   = pack('C', $pad_len) . $body . $padding;

    my $wire;
    if ($self->{tx_enc}) {
        if ($self->{tx_cipher} eq 'aes256-gcm@openssh.com') {
            my $aad4 = pack('N', length($inner));
            $wire = aes256_gcm_openssh_encrypt(
                $self->{tx_k1}, $self->{tx_iv}, $self->{tx_gcm_seq}, $aad4, $inner
            );
            $self->{tx_gcm_seq}++;
        } else {
            $wire = chacha20_poly1305_openssh_encrypt(
                $self->{tx_k1}, $self->{tx_k2}, $self->{tx_seq}, $inner
            );
        }
    } else {
        $wire = pack('N', length($inner)) . $inner;
    }

    $self->{tx_seq} = ($self->{tx_seq} + 1) & 0xffffffff;
    my $wlen = length($wire);
    $self->{wire_tx_bytes}  += $wlen;
    $self->{rekey_tx_bytes} += $wlen if $self->{tx_enc};

    $self->{tx_buf} .= $wire;
    my $ok = $self->flush($nonblock ? 1 : 0);

    # Trigger server-initiated rekey synchronously per RFC 4253 §7.1 (no non-KEX packets between KEXINIT and NEWKEYS)
    if ($ok && $self->{tx_enc} && !$self->{in_rekey} && !$self->{in_initial_kex}
        && $self->{rekey_limit} > 0 && $self->{rekey_tx_bytes} >= $self->{rekey_limit})
    {
        $self->_handle_rekey(undef) or return 0;
    }

    return $ok;
}

sub recv_packet_nonblock {
    my ($self) = @_;
    if (!$self->{in_rekey} && !$self->{in_initial_kex} && @{ $self->{_deferred_rx} }) {
        return shift @{ $self->{_deferred_rx} };
    }
    return undef if $self->{closed} && length($self->{rx_buf}) == 0;

    while (1) {
        my $got = $self->_fill_rx();

        if ($self->{rx_enc}) {
            if (length($self->{rx_buf}) < 4) {
                return undef if !defined($got);
                return '';
            }

            my $is_gcm = ($self->{rx_cipher} eq 'aes256-gcm@openssh.com') ? 1 : 0;

            if (!defined $self->{_pending_rx_len}) {
                my $len4 = substr($self->{rx_buf}, 0, 4);
                my $plen = $is_gcm
                    ? unpack('N', $len4)
                    : chacha20_poly1305_openssh_decrypt_len($self->{rx_k2}, $self->{rx_seq}, $len4);
                if ($plen < 2 || $plen > MAX_PACKET_SIZE || ($is_gcm && ($plen % 16) != 0)) {
                    $self->disconnect(SSH_DISCONNECT_PROTOCOL_ERROR, 'Invalid packet length');
                    return undef;
                }
                $self->{_pending_rx_len} = $plen;
            }

            my $plen = $self->{_pending_rx_len};
            my $need = 4 + $plen + 16;
            if (length($self->{rx_buf}) < $need) {
                return undef if !defined($got);
                return '';
            }

            my $hdr4     = substr($self->{rx_buf}, 0, 4);
            my $enc_body = substr($self->{rx_buf}, 4, $plen);
            my $tag16    = substr($self->{rx_buf}, 4 + $plen, 16);
            substr($self->{rx_buf}, 0, $need, '');
            $self->{_pending_rx_len} = undef;

            my $inner;
            if ($is_gcm) {
                $inner = aes256_gcm_openssh_decrypt(
                    $self->{rx_k1}, $self->{rx_iv}, $self->{rx_gcm_seq}, $hdr4, $enc_body, $tag16
                );
                $self->{rx_gcm_seq}++ if defined $inner;
            } else {
                $inner = chacha20_poly1305_openssh_decrypt_body(
                    $self->{rx_k1}, $self->{rx_seq}, $hdr4, $enc_body, $tag16
                );
            }

            if (!defined $inner) {
                $self->disconnect(SSH_DISCONNECT_MAC_ERROR, 'MAC verification failed');
                return undef;
            }

            $self->{rx_seq} = ($self->{rx_seq} + 1) & 0xffffffff;
            $self->{wire_rx_bytes}  += $need;
            $self->{rekey_rx_bytes} += $need;

            my $pad_len = ord(substr($inner, 0, 1));
            if (1 + $pad_len > length($inner)) {
                $self->disconnect(SSH_DISCONNECT_PROTOCOL_ERROR, 'Invalid padding length');
                return undef;
            }
            my $payload = substr($inner, 1, length($inner) - 1 - $pad_len);
            if ($self->{comp_active} && $self->{rx_zlib}) {
                $payload = eval { $self->{rx_zlib}->inflate($payload, MAX_PACKET_SIZE) };
                if ($@) {
                    $self->disconnect(SSH_DISCONNECT_COMPRESSION_ERROR, 'Inflate failed');
                    return undef;
                }
            }
            $self->{raw_rx_bytes} += length($payload);

            next if length($payload) == 0;
            my $mtype = ord(substr($payload, 0, 1));
            next if $mtype == SSH_MSG_IGNORE || $mtype == SSH_MSG_DEBUG;
            if ($mtype == SSH_MSG_DISCONNECT) {
                $self->{closed} = 1;
                return undef;
            }
            # Handle client-initiated or completing server-initiated mid-session rekey transparently
            if ($mtype == SSH_MSG_KEXINIT && !$self->{in_rekey}) {
                $self->_handle_rekey($payload) or return undef;
                next;
            }
            return $payload;
        } else {
            if (length($self->{rx_buf}) < 4) {
                return undef if !defined($got);
                return '';
            }
            my $plen = unpack('N', substr($self->{rx_buf}, 0, 4));
            if ($plen < 2 || $plen > MAX_PACKET_SIZE) {
                $self->{closed} = 1;
                return undef;
            }
            my $need = 4 + $plen;
            if (length($self->{rx_buf}) < $need) {
                return undef if !defined($got);
                return '';
            }
            my $inner = substr($self->{rx_buf}, 4, $plen);
            substr($self->{rx_buf}, 0, $need, '');

            $self->{rx_seq} = ($self->{rx_seq} + 1) & 0xffffffff;
            $self->{wire_rx_bytes} += $need;

            my $pad_len = ord(substr($inner, 0, 1));
            if (1 + $pad_len > length($inner)) {
                $self->disconnect(SSH_DISCONNECT_PROTOCOL_ERROR, 'Invalid padding length');
                return undef;
            }
            my $payload = substr($inner, 1, length($inner) - 1 - $pad_len);
            $self->{raw_rx_bytes} += length($payload);

            next if length($payload) == 0;
            my $mtype = ord(substr($payload, 0, 1));
            # During initial KEX, do NOT swallow IGNORE/DEBUG/UNIMPLEMENTED (Terrapin CVE-2023-48795)
            if (!$self->{in_initial_kex}) {
                next if $mtype == SSH_MSG_IGNORE || $mtype == SSH_MSG_DEBUG;
            }
            if ($mtype == SSH_MSG_DISCONNECT) {
                $self->{closed} = 1;
                return undef;
            }
            return $payload;
        }
    }
}

sub recv_packet_blocking {
    my ($self, $timeout) = @_;
    $timeout //= 15;
    my $deadline = time() + $timeout;

    while (1) {
        my $pkt = $self->recv_packet_nonblock();
        return undef if !defined($pkt);
        return $pkt  if length($pkt) > 0;
        return undef if time() > $deadline;
        $self->_yield_io(1, 0, 0.01);
    }
}

sub disconnect {
    my ($self, $reason, $desc) = @_;
    return if $self->{closed};
    $reason //= SSH_DISCONNECT_BY_APPLICATION;
    $desc   //= 'Bye';
    my $pkt = pack_byte(SSH_MSG_DISCONNECT)
            . pack_u32($reason)
            . pack_string($desc)
            . pack_string('');
    eval { $self->send_packet($pkt, 1) };
    $self->{closed} = 1;
    eval { close($self->{sock}) };
}

1;
