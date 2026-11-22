#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../xs/Shop-SSH-Crypto/blib/arch",
        "$FindBin::Bin/../xs/Shop-SSH-Crypto/blib/lib",
        "$FindBin::Bin/../lib";
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(time);

# Write bytes to $cli without deadlocking single-process socketpair on >4KB payloads
sub write_and_shutdown {
    my ($cli, $srv, $bytes) = @_;
    if (length($bytes) <= 4096) {
        syswrite($cli, $bytes);
        shutdown($cli, 1);
        return undef;
    }
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        close($srv);
        local $SIG{PIPE} = 'IGNORE';
        my $off = 0;
        my $len = length($bytes);
        while ($off < $len) {
            my $n = syswrite($cli, $bytes, $len - $off, $off);
            last if !defined($n) || $n <= 0;
            $off += $n;
        }
        shutdown($cli, 1);
        close($cli);
        exit 0;
    }
    return $pid;
}

use Shop::SSH::Crypto qw(
    random_bytes
    x25519_keypair
    x25519_shared
    mlkem768_encapsulate
    ed25519_keypair
    ed25519_seed_keypair
    ed25519_sign
    ed25519_verify
    rsa_sha2_verify
    ecdsa_p256_verify
    sha256
    hmac_sha256
    const_time_eq
    aes256_gcm_openssh_encrypt
    aes256_gcm_openssh_decrypt
    chacha20_poly1305_openssh_encrypt
    chacha20_poly1305_openssh_decrypt_len
    chacha20_poly1305_openssh_decrypt_body
);
use Shop::SSH::Wire qw(:all);
use Shop::SSH::Transport;
use Shop::SSH::Auth;
use Shop::SSH::Session;
use Shop::TUI::Input;
use Shop::Domain::JSON qw(encode_json decode_json);

my $SEED       = defined($ENV{FUZZ_SEED})  ? int($ENV{FUZZ_SEED})  : 0x53484f50;
my $TOTAL_BASE = defined($ENV{FUZZ_ITERS}) ? int($ENV{FUZZ_ITERS}) : 8000;
$TOTAL_BASE = 1000 if $TOTAL_BASE < 1000;

srand($SEED);
note("Fuzz seed=$SEED base_iters=$TOTAL_BASE");

my $xs_iters   = int($TOTAL_BASE * 0.25);
my $wire_iters = int($TOTAL_BASE * 0.25);
my $tui_iters  = int($TOTAL_BASE * 0.25);
my $json_iters = int($TOTAL_BASE * 0.25);
my $sock_iters = ($TOTAL_BASE >= 50000) ? 220 : 60;

sub rand_bytes {
    my ($len) = @_;
    return '' if $len <= 0;
    my $out = '';
    for (1 .. $len) {
        $out .= chr(int(rand(256)));
    }
    return $out;
}

# Helper to build an unencrypted SSH wire packet with arbitrary length/padding
sub raw_ssh_pkt {
    my ($payload, $pad_len) = @_;
    if (!defined $pad_len) {
        $pad_len = 8 - ((4 + 1 + length($payload)) % 8);
        $pad_len += 8 if $pad_len < 4;
    }
    my $inner = pack('C', $pad_len) . $payload . ("\x00" x $pad_len);
    return pack('N', length($inner)) . $inner;
}

sub valid_kexinit_payload {
    my (%o) = @_;
    my $kex  = $o{kex}  // ['curve25519-sha256'];
    my $hk   = $o{hk}   // ['ssh-ed25519'];
    my $enc  = $o{enc}  // ['chacha20-poly1305@openssh.com'];
    my $mac  = $o{mac}  // ['hmac-sha2-256'];
    my $comp = $o{comp} // ['none'];
    return pack_byte(SSH_MSG_KEXINIT)
         . ("\x11" x 16)
         . pack_namelist(@$kex)
         . pack_namelist(@$hk)
         . pack_namelist(@$enc)
         . pack_namelist(@$enc)
         . pack_namelist(@$mac)
         . pack_namelist(@$mac)
         . pack_namelist(@$comp)
         . pack_namelist(@$comp)
         . pack_namelist()
         . pack_namelist()
         . pack_bool($o{first_follows} ? 1 : 0)
         . pack_u32(0);
}

# =====================================================================
# 1. C/XS Shop::SSH::Crypto boundary, undef, random, and Zlib fuzzing
# =====================================================================
{
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };

    # Explicit undef & boundary checks
    eval { sha256(undef) };
    ok($@, 'sha256(undef) croaks cleanly');
    eval { hmac_sha256(undef, 'x') };
    ok($@, 'hmac_sha256(undef, x) croaks cleanly');
    is(const_time_eq(undef, undef), 0, 'const_time_eq(undef, undef) returns 0');
    is(ed25519_verify(undef, undef, undef), 0, 'ed25519_verify(undef...) returns 0');
    is(rsa_sha2_verify(undef, undef, undef, undef, 256), 0, 'rsa_sha2_verify(undef...) returns 0');
    is(ecdsa_p256_verify(undef, undef, undef, undef), 0, 'ecdsa_p256_verify(undef...) returns 0');
    is(rsa_sha2_verify('m', 's', "\xff" x 2048, "\x01\x00\x01", 256), 0, 'rsa_sha2_verify rejects >1024B modulus');
    eval { mlkem768_encapsulate(undef) };
    ok($@, 'mlkem768_encapsulate(undef) croaks cleanly');
    eval { mlkem768_encapsulate("\xff" x 1184) };
    ok($@, 'mlkem768_encapsulate(all-FF) rejects invalid key cleanly');

    # Zlib Z_STREAM_END + trailing garbage byte hang regression
    my $z_def = Shop::SSH::Crypto::Zlib->new(5);
    my $z_inf = Shop::SSH::Crypto::Zlib->new(5);
    # Standard RFC 1950 finished zlib stream ("hello") + trailing byte 0x42
    my $finished_zlib = pack('H*', '789ccb48cdc9c90700062c021542');
    eval { $z_inf->inflate($finished_zlib, 65536) };
    like($@, qr/trailing data|failed/, 'Zlib::inflate rejects Z_STREAM_END + trailing byte without hanging');

    # Zlib zip-bomb guard
    my $zb_def = Shop::SSH::Crypto::Zlib->new(9);
    my $zb_inf = Shop::SSH::Crypto::Zlib->new(5);
    my $bomb   = $zb_def->deflate("\x00" x (512 * 1024));
    eval { $zb_inf->inflate($bomb, 16384) };
    like($@, qr/SSH_ZIP_BOMB/, 'Zlib::inflate catches zip-bomb');

    # Randomized XS fuzz loop
    my @sizes = (0, 1, 3, 4, 12, 16, 31, 32, 33, 64, 65, 128, 1183, 1184, 1185);
    my $k32   = random_bytes(32);
    my $iv12  = random_bytes(12);
    my $aad4  = "\x00\x00\x00\x10";
    for my $i (1 .. $xs_iters) {
        my $op = $i % 9;
        if ($op == 0) {
            my $l = $sizes[$i % @sizes];
            eval { x25519_shared($k32, rand_bytes($l)) };
        } elsif ($op == 1) {
            my $l = $sizes[$i % @sizes];
            eval { mlkem768_encapsulate(rand_bytes($l)) };
        } elsif ($op == 2) {
            my $l = $sizes[$i % @sizes];
            ed25519_verify(rand_bytes($l % 64), rand_bytes($l), rand_bytes($sizes[($i + 3) % @sizes]));
        } elsif ($op == 3) {
            rsa_sha2_verify(
                rand_bytes($i % 64),
                rand_bytes($i % 128),
                rand_bytes($i % 256),
                rand_bytes($i % 8),
                ($i & 1) ? 256 : 512,
            );
        } elsif ($op == 4) {
            my $q = ($i % 3 == 0) ? ("\x04" . rand_bytes(64)) : rand_bytes($sizes[$i % @sizes]);
            ecdsa_p256_verify(rand_bytes($i % 32), rand_bytes($i % 35), rand_bytes(($i + 7) % 35), $q);
        } elsif ($op == 5) {
            my $p = rand_bytes($i % 128);
            my $enc = aes256_gcm_openssh_encrypt($k32, $iv12, $i, $aad4, $p);
            my $body = substr($enc, 4, length($p));
            my $tag  = substr($enc, 4 + length($p), 16);
            if ($i % 2 == 0) {
                my $dec = aes256_gcm_openssh_decrypt($k32, $iv12, $i, $aad4, $body, $tag);
                die "GCM roundtrip mismatch" unless defined($dec) && $dec eq $p;
            } else {
                substr($tag, 0, 1) ^= "\x01";
                my $dec = aes256_gcm_openssh_decrypt($k32, $iv12, $i, $aad4, $body, $tag);
                die "GCM accepted bad tag" if defined $dec;
            }
        } elsif ($op == 6) {
            my $p = rand_bytes($i % 128);
            my $enc = chacha20_poly1305_openssh_encrypt($k32, $k32, $i, $p);
            my $h4   = substr($enc, 0, 4);
            my $body = substr($enc, 4, length($p));
            my $tag  = substr($enc, 4 + length($p), 16);
            my $dlen = chacha20_poly1305_openssh_decrypt_len($k32, $i, $h4);
            die "ChaCha len mismatch" unless $dlen == length($p);
            if ($i % 2 == 0) {
                my $dec = chacha20_poly1305_openssh_decrypt_body($k32, $i, $h4, $body, $tag);
                die "ChaCha roundtrip mismatch" unless defined($dec) && $dec eq $p;
            } else {
                substr($tag, 0, 1) ^= "\x80";
                my $dec = chacha20_poly1305_openssh_decrypt_body($k32, $i, $h4, $body, $tag);
                die "ChaCha accepted bad tag" if defined $dec;
            }
        } elsif ($op == 7) {
            my $zi = Shop::SSH::Crypto::Zlib->new(5);
            my $raw = ($i % 2 == 0) ? ("\x78\x9c" . rand_bytes(1 + ($i % 48))) : rand_bytes(1 + ($i % 48));
            eval { $zi->inflate($raw, 8192) };
        } else {
            my $p = rand_bytes($i % 256);
            my $c = $z_def->deflate($p);
            eval { Shop::SSH::Crypto::Zlib->new(5)->inflate($c, 8192) };
        }
    }

    is(scalar(@warns), 0, "XS Crypto fuzz ($xs_iters iters): 0 warnings, 0 crashes")
        or diag("First warning: $warns[0]");
}

# =====================================================================
# 2. Shop::SSH::Wire parser fuzzing
# =====================================================================
{
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };

    # Undef / negative offset / huge length checks
    for my $bad_len (0xffffffff, 0x7fffffff, 0x80000000, 0x00100000) {
        my $buf = pack('N', $bad_len) . 'abcd';
        my $off = 0;
        eval { unpack_string($buf, \$off) };
        like($@, qr/truncated/, sprintf("unpack_string rejects 0x%08x length", $bad_len));
    }

    my $off = -5;
    eval { unpack_byte('abc', \$off) };
    ok($@, 'unpack_byte rejects negative offset');
    $off = 0;
    eval { unpack_u32(undef, \$off) };
    ok($@, 'unpack_u32(undef) dies cleanly');
    is(parse_ed25519_pubkey_blob(undef), undef, 'parse_ed25519_pubkey_blob(undef) returns undef');
    my @rsa_undef = parse_rsa_pubkey_blob(undef);
    is(scalar(@rsa_undef), 0, 'parse_rsa_pubkey_blob(undef) returns empty');
    is(parse_ecdsa_p256_pubkey_blob(undef), undef, 'parse_ecdsa_p256_pubkey_blob(undef) returns undef');

    my $huge_rsa = pack_string('ssh-rsa') . pack_mpint("\x01\x00\x01") . pack_mpint("\xff" x 2048);
    my @rsa_huge = parse_rsa_pubkey_blob($huge_rsa);
    is(scalar(@rsa_huge), 0, 'parse_rsa_pubkey_blob rejects >1024B modulus');

    for my $i (1 .. $wire_iters) {
        my $len = $i % 96;
        my $buf = rand_bytes($len);
        if ($i % 5 == 0 && $len >= 4) {
            my @evil = (0xffffffff, 0x7fffffff, 0x80000000, 0, 1, 32, 65);
            substr($buf, 0, 4) = pack('N', $evil[$i % @evil]);
        }
        my $o = 0;
        eval { unpack_byte($buf, \$o) };
        $o = 0;
        eval { unpack_bool($buf, \$o) };
        $o = 0;
        eval { unpack_u32($buf, \$o) };
        $o = 0;
        eval { unpack_string($buf, \$o) };
        $o = 0;
        eval { unpack_namelist($buf, \$o) };
        $o = 0;
        eval { unpack_mpint($buf, \$o) };
        parse_ed25519_pubkey_blob($buf);
        parse_rsa_pubkey_blob($buf);
        parse_ecdsa_p256_pubkey_blob($buf);
        pubkey_fingerprint($buf) if ($i % 10 == 0);
    }

    is(scalar(@warns), 0, "Wire.pm fuzz ($wire_iters iters): 0 warnings, 0 crashes")
        or diag("First warning: $warns[0]");
}

# =====================================================================
# 3. Adversarial SSHv2 Transport / Auth / Session socketpair fuzzing
# =====================================================================
{
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };

    my $hk = load_or_generate_hostkey(undef);

    # 3a. Adversarial banners & pre-KEX framing over socketpairs
    my @banner_attacks = (
        ("A" x 100_000),                                # 100 KB no newline
        ("SSH-2.0-" . ("X" x 300) . "\r\n"),            # >255 byte banner with newline
        "SSH-2.0-evil\x00client\r\n",                   # NUL byte in banner
        ("\r" x 2000) . "\n",                           # CR storm
        "\r\n",                                         # empty banner
        "SSH-1.99-\r\n",                                # empty software version
        "SSH-1.5-legacy\r\n",                           # SSHv1 rejected
        ("comment\r\n" x 20) . "SSH-2.0-ok\r\n",        # >16 pre-banner lines
    );

    for my $idx (0 .. $#banner_attacks) {
        socketpair(my $srv, my $cli, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
        my $wpid = write_and_shutdown($cli, $srv, $banner_attacks[$idx]);
        my $t = Shop::SSH::Transport->new(sock => $srv, hostkey => $hk);
        eval { $t->handshake(0.3) };
        ok($@, "Adversarial banner #$idx cleanly rejected");
        close($srv);
        close($cli);
        waitpid($wpid, 0) if defined $wpid;
    }

    # 3b. Adversarial packet framing & KEXINIT / KEX_ECDH_INIT / KEX_HYBRID_INIT
    my @kex_attacks = (
        pack('N', 0) . ("\x00" x 16),                                    # plen=0
        pack('N', 1) . ("\x00" x 16),                                    # plen=1
        pack('N', 3) . ("\x00" x 16),                                    # plen=3
        pack('N', 0xffffffff) . ("\x00" x 16),                           # plen=0xffffffff
        pack('N', 262145) . ("\x00" x 16),                               # plen>MAX_PACKET_SIZE
        pack('N', 7) . ("\x04\x14\x00\x00\x00\x00\x00"),                 # unaligned plen
        raw_ssh_pkt(pack_byte(SSH_MSG_KEXINIT) . ("\x00" x 10), 2),      # pad_len < 4
        pack('N', 12) . pack('C', 20) . ("\x00" x 11),                   # pad_len >= plen
        raw_ssh_pkt(pack_byte(SSH_MSG_KEXINIT)),                         # truncated KEXINIT (1B)
        raw_ssh_pkt(pack_byte(SSH_MSG_KEXINIT) . ("\x00" x 16)),         # truncated KEXINIT (17B)
        raw_ssh_pkt(valid_kexinit_payload(kex => ['nonexistent-kex'])),  # no common KEX
        raw_ssh_pkt(valid_kexinit_payload(enc => ['aes128-cbc'])),       # no common cipher
        raw_ssh_pkt(valid_kexinit_payload(kex => [('a' x 60000)])),      # 60KB namelist
        # Valid KEXINIT followed by bad KEX_ECDH_INIT
        raw_ssh_pkt(valid_kexinit_payload())
            . raw_ssh_pkt(pack_byte(SSH_MSG_KEX_ECDH_INIT) . pack_string("\x00" x 32)),  # all-zero X25519
        raw_ssh_pkt(valid_kexinit_payload())
            . raw_ssh_pkt(pack_byte(SSH_MSG_KEX_ECDH_INIT) . pack_string("A" x 31)),     # 31B X25519
        raw_ssh_pkt(valid_kexinit_payload(kex => ['mlkem768x25519-sha256']))
            . raw_ssh_pkt(pack_byte(SSH_MSG_KEX_HYBRID_INIT) . pack_string("\xff" x 1216)), # invalid ML-KEM-768
        raw_ssh_pkt(valid_kexinit_payload(kex => ['mlkem768x25519-sha256']))
            . raw_ssh_pkt(pack_byte(SSH_MSG_KEX_HYBRID_INIT) . pack_string("X" x 32)),   # wrong hybrid len
        raw_ssh_pkt(valid_kexinit_payload(kex => ['curve25519-sha256', 'kex-strict-c-v00@openssh.com']))
            . raw_ssh_pkt(pack_byte(SSH_MSG_IGNORE) . pack_string('terrapin')),          # strict-kex violation
        raw_ssh_pkt(valid_kexinit_payload())
            . raw_ssh_pkt(pack_byte(SSH_MSG_USERAUTH_REQUEST) . pack_string('root')),    # auth before NEWKEYS
    );

    for my $idx (0 .. $#kex_attacks) {
        socketpair(my $srv, my $cli, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
        my $wpid = write_and_shutdown($cli, $srv, "SSH-2.0-fuzz_client\r\n" . $kex_attacks[$idx]);
        my $t = Shop::SSH::Transport->new(sock => $srv, hostkey => $hk);
        eval { $t->handshake(0.3) };
        ok($@, "Adversarial KEX/framing #$idx cleanly rejected");
        close($srv);
        close($cli);
        waitpid($wpid, 0) if defined $wpid;
    }

    # Randomized adversarial byte streams into handshake
    my $rand_sock_count = $sock_iters - scalar(@banner_attacks) - scalar(@kex_attacks);
    $rand_sock_count = 20 if $rand_sock_count < 20;
    for my $i (1 .. $rand_sock_count) {
        socketpair(my $srv, my $cli, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
        my $payload = ($i % 2 == 0)
            ? ("SSH-2.0-fuzzer\r\n" . rand_bytes(1 + ($i % 256)))
            : rand_bytes(1 + ($i % 256));
        syswrite($cli, $payload);
        shutdown($cli, 1);
        my $t = Shop::SSH::Transport->new(sock => $srv, hostkey => $hk);
        eval { $t->handshake(0.2) };
        close($cli);
        close($srv);
    }
    pass("Randomized adversarial socketpair handshake fuzz ($rand_sock_count clients) completed cleanly");

    # 3c. Adversarial Auth.pm fuzzing over socketpair (pre-authenticated unencrypted transport harness)
    {
        socketpair(my $srv, my $cli, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
        my $t = Shop::SSH::Transport->new(sock => $srv, hostkey => $hk);
        $t->{session_id} = random_bytes(32);

        my $pk_blob = ed25519_pubkey_blob((ed25519_keypair())[1]);
        my $stream = '';
        $stream .= raw_ssh_pkt(pack_byte(SSH_MSG_SERVICE_REQUEST) . pack_string('ssh-userauth'));
        # 64 KB username -> rejected
        $stream .= raw_ssh_pkt(
            pack_byte(SSH_MSG_USERAUTH_REQUEST)
            . pack_string('u' x 65536)
            . pack_string('ssh-connection')
            . pack_string('none')
        );
        # Invalid pubkey blobs & truncated signatures
        $stream .= raw_ssh_pkt(
            pack_byte(SSH_MSG_USERAUTH_REQUEST)
            . pack_string('bob')
            . pack_string('ssh-connection')
            . pack_string('publickey')
            . pack_bool(1)
            . pack_string('ssh-ed25519')
            . pack_string('garbage-blob')
            . pack_string('bad-sig')
        );
        $stream .= raw_ssh_pkt(
            pack_byte(SSH_MSG_USERAUTH_REQUEST)
            . pack_string('bob')
            . pack_string('ssh-connection')
            . pack_string('publickey')
            . pack_bool(1)
            . pack_string('ssh-ed25519')
            . pack_string($pk_blob)
            . pack_string(pack_string('ssh-ed25519') . pack_string('short'))
        );
        # Unknown method + auth flood
        for (1 .. 15) {
            $stream .= raw_ssh_pkt(
                pack_byte(SSH_MSG_USERAUTH_REQUEST)
                . pack_string('bob')
                . pack_string('ssh-connection')
                . pack_string('hostbased')
            );
        }
        my $wpid = write_and_shutdown($cli, $srv, $stream);

        eval { Shop::SSH::Auth->authenticate($t, allow_guest => 0, max_attempts => 10, timeout => 1) };
        like($@, qr/too many authentication attempts|EOF/, 'Auth.pm rejects 64KB username, bad pubkeys, and auth flood');
        close($srv);
        close($cli);
        waitpid($wpid, 0) if defined $wpid;
    }

    # 3d. Adversarial Auth.pm non-auth packet flood
    {
        socketpair(my $srv, my $cli, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
        my $t = Shop::SSH::Transport->new(sock => $srv, hostkey => $hk);
        $t->{session_id} = random_bytes(32);

        my $stream = raw_ssh_pkt(pack_byte(SSH_MSG_SERVICE_REQUEST) . pack_string('ssh-userauth'));
        for (1 .. 80) {
            $stream .= raw_ssh_pkt(pack_byte(SSH_MSG_UNIMPLEMENTED) . pack_u32($_));
        }
        syswrite($cli, $stream);
        shutdown($cli, 1);

        eval { Shop::SSH::Auth->authenticate($t, allow_guest => 0, timeout => 1) };
        like($@, qr/too many non-auth packets/, 'Auth.pm bounds non-auth packet flood');
        close($cli);
        close($srv);
    }

    # 3e. Adversarial Session.pm fuzzing (pty-req 0xFFFFFFFF, 1000 env flood, window-change, CHANNEL_DATA > window)
    {
        socketpair(my $srv, my $cli, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
        my $t = Shop::SSH::Transport->new(sock => $srv, hostkey => $hk);
        my $sess = Shop::SSH::Session->new(
            transport => $t,
            user      => { username => 'fuzz', is_guest => 1 },
        );

        # Open session channel
        $sess->_dispatch_packet(
            pack_byte(SSH_MSG_CHANNEL_OPEN)
            . pack_string('session')
            . pack_u32(7)
            . pack_u32(65536)
            . pack_u32(32768)
        );
        ok($sess->{channel_open}, 'Session channel opened');

        # Huge pty-req cols/rows 0xFFFFFFFF and oversized term
        $sess->_dispatch_packet(
            pack_byte(SSH_MSG_CHANNEL_REQUEST)
            . pack_u32(0)
            . pack_string('pty-req')
            . pack_bool(1)
            . pack_string('X' x 5000)
            . pack_u32(0xffffffff)
            . pack_u32(0xffffffff)
        );
        my ($cols, $rows) = $sess->size();
        is($cols, 80, 'pty-req clamps 0xFFFFFFFF cols to 80');
        is($rows, 24, 'pty-req clamps 0xFFFFFFFF rows to 24');
        cmp_ok(length($sess->term), '<=', 128, 'pty-req caps term length');

        # 1,000 env requests flood -> %env must be bounded to <= 64
        for my $i (1 .. 1000) {
            $sess->_dispatch_packet(
                pack_byte(SSH_MSG_CHANNEL_REQUEST)
                . pack_u32(0)
                . pack_string('env')
                . pack_bool(0)
                . pack_string("FUZZ_VAR_$i")
                . pack_string("VAL_$i")
            );
        }
        my $env_count = scalar(keys %{ $sess->env });
        cmp_ok($env_count, '<=', 64, "Session env flood bounded (got $env_count <= 64)");

        # window-change flood & WINDOW_ADJUST overflow clamp
        for my $i (1 .. 100) {
            $sess->_dispatch_packet(
                pack_byte(SSH_MSG_CHANNEL_REQUEST)
                . pack_u32(0)
                . pack_string('window-change')
                . pack_bool(0)
                . pack_u32(($i % 2) ? 0xffffffff : 120)
                . pack_u32(($i % 2) ? 0xffffffff : 40)
            );
        }
        $sess->_dispatch_packet(
            pack_byte(SSH_MSG_CHANNEL_WINDOW_ADJUST) . pack_u32(0) . pack_u32(0xffffffff)
        );
        $sess->_dispatch_packet(
            pack_byte(SSH_MSG_CHANNEL_WINDOW_ADJUST) . pack_u32(0) . pack_u32(0xffffffff)
        );
        cmp_ok($sess->{remote_window}, '<=', 0xffffffff, 'remote_window clamped to 0xFFFFFFFF');

        # Unknown opcode is safely ignored
        $sess->_dispatch_packet(pack_byte(250) . 'random');
        ok(!$sess->{closed}, 'Unknown opcode ignored without closing');

        # Truncated CHANNEL_REQUEST closes cleanly without throwing
        $sess->_dispatch_packet(pack_byte(SSH_MSG_CHANNEL_REQUEST) . "\x00\x00");
        ok($sess->{closed}, 'Truncated CHANNEL_REQUEST closes session cleanly');

        close($cli);
        close($srv);
    }

    # 3f. Session CHANNEL_DATA exceeding MAX_INPUT_BUF / local_window disconnects cleanly
    {
        socketpair(my $srv, my $cli, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
        my $t = Shop::SSH::Transport->new(sock => $srv, hostkey => $hk);
        my $sess = Shop::SSH::Session->new(
            transport => $t,
            user      => { username => 'fuzz', is_guest => 1 },
        );
        $sess->_dispatch_packet(
            pack_byte(SSH_MSG_CHANNEL_OPEN)
            . pack_string('session')
            . pack_u32(1)
            . pack_u32(65536)
            . pack_u32(32768)
        );
        for (1 .. 20) {
            last if $sess->{closed};
            $sess->_dispatch_packet(
                pack_byte(SSH_MSG_CHANNEL_DATA)
                . pack_u32(0)
                . pack_string('A' x 32768)
            );
        }
        ok($sess->{closed}, 'Session disconnects when CHANNEL_DATA floods unread input_buf');
        cmp_ok(length($sess->{input_buf}), '<=', 262144, 'Session input_buf stayed bounded <= 256 KiB');
        close($cli);
        close($srv);
    }

    is(scalar(@warns), 0, 'SSHv2 Transport/Auth/Session adversarial fuzz: 0 warnings, 0 crashes')
        or diag("First warning: $warns[0]");
}

# =====================================================================
# 4. Shop::TUI::Input fuzzing
# =====================================================================
{
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };

    my $in = Shop::TUI::Input->new();

    # 100 KB unterminated CSI + 100 KB overlong CSI + huge SGR coordinates
    my $t0 = time();
    $in->parse("\e[" . ("0" x 100_000));
    $in->parse("\e[" . ("0" x 100_000) . "A");
    $in->parse("\e[<" . ("9" x 50) . ";9999999999;9999999999M");
    $in->parse("\e]0;" . ("T" x 10_000) . "\x07");
    $in->parse(undef);
    my $dt = time() - $t0;
    cmp_ok($dt, '<', 2.0, sprintf("Input.pm 200KB malformed CSI/OSC finished in %.3fs", $dt));
    cmp_ok(length($in->{buf}), '<=', 32, 'Input.pm internal buffer stays bounded <= 32 bytes');

    my @prefixes = ("\e[", "\eO", "\e]", "\e[<", "\e", "\xc3", "\xe2\x82", "\xf0\x9f", "");
    my $max_buf = 0;
    for my $i (1 .. $tui_iters) {
        my $chunk = $prefixes[$i % @prefixes] . rand_bytes($i % 40);
        my @evs = $in->parse($chunk);
        my $bl = length($in->{buf});
        $max_buf = $bl if $bl > $max_buf;
    }

    cmp_ok($max_buf, '<=', 32, "Input.pm fuzz ($tui_iters iters): max buf=$max_buf <= 32");
    is(scalar(@warns), 0, "Input.pm fuzz ($tui_iters iters): 0 warnings, 0 crashes")
        or diag("First warning: $warns[0]");
}

# =====================================================================
# 5. Shop::Domain::JSON fuzzing
# =====================================================================
{
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };

    # Deep nesting 500 levels -> must die cleanly without Deep recursion warning
    eval { decode_json(("[" x 500) . ("]" x 500)) };
    like($@, qr/maximum nesting depth/, 'JSON decode_json caps deep array nesting (500)');

    eval { decode_json(('{"a":' x 500) . '1' . ('}' x 500)) };
    like($@, qr/maximum nesting depth/, 'JSON decode_json caps deep object nesting (500)');

    # Malformed escapes, truncated inputs, huge numbers
    for my $bad (
        undef, '', '{', '[', '{"a"', '{"a":', '[1,', '"unterminated',
        '"\\', '"\\u', '"\\u12', '"\\uZZZZ"', '"\\x41"', 'tru', 'fals', 'nul',
        '1e', '1e+', '-', '01', '{"a":1} trailing', '[1] 2',
    ) {
        eval { decode_json($bad) };
        ok($@, 'JSON rejects malformed input: ' . (defined($bad) ? substr($bad, 0, 20) : 'undef'));
    }

    # Randomized JSON fuzz loop
    my @seeds = (
        '{"k":"v","n":123,"a":[true,false,null,-0.5e+2]}',
        '["\\u0041\\n\\t\\"\\\\",{"x":0}]',
        '{"nested":{"deep":[1,2,3]}}',
    );
    for my $i (1 .. $json_iters) {
        my $s;
        if ($i % 3 == 0) {
            # Mutate a valid JSON string
            $s = $seeds[$i % @seeds];
            my $pos = int(rand(length($s)));
            my $mode = $i % 4;
            if    ($mode == 0) { substr($s, $pos, 1) = chr(int(rand(128))); }
            elsif ($mode == 1) { $s = substr($s, 0, $pos); }
            elsif ($mode == 2) { substr($s, $pos, 0) = '\\u' . rand_bytes(3); }
            else               { $s .= rand_bytes(1 + ($i % 8)); }
        } else {
            $s = rand_bytes(1 + ($i % 64));
        }
        eval { decode_json($s) };
    }

    is(scalar(@warns), 0, "JSON.pm fuzz ($json_iters iters): 0 warnings, 0 crashes")
        or diag("First warning: $warns[0]");
}

done_testing();
