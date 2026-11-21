#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib",
        "$FindBin::Bin/../xs/Shop-SSH-Crypto/blib/lib",
        "$FindBin::Bin/../xs/Shop-SSH-Crypto/blib/arch";
use Test::More;
use IO::Socket::INET;
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep time);
use Shop::SSH::Crypto qw(
    random_bytes
    chacha20_poly1305_openssh_encrypt
    chacha20_poly1305_openssh_decrypt_body
    aes256_gcm_openssh_encrypt
    aes256_gcm_openssh_decrypt
    hmac_sha256
    const_time_eq
);
use Shop::SSH::Wire qw(:all);
use Shop::SSH::Transport;
use Shop::SSH::Session;

my $tmp = tempdir(CLEANUP => 1);
my $hk  = load_or_generate_hostkey("$tmp/host_ed25519");

my $cli_ed = "$tmp/id_ed25519";
system("ssh-keygen -q -t ed25519 -N '' -f '$cli_ed'") == 0 or die "ssh-keygen ed25519 failed";
my ($ed_fp) = (`ssh-keygen -lf '$cli_ed.pub'` =~ /(SHA256:\S+)/);

my $cli_ecdsa = "$tmp/id_ecdsa256";
system("ssh-keygen -q -t ecdsa -b 256 -N '' -f '$cli_ecdsa'") == 0 or die "ssh-keygen ecdsa failed";
my ($ecdsa_fp) = (`ssh-keygen -lf '$cli_ecdsa.pub'` =~ /(SHA256:\S+)/);

sub run_ssh_case {
    my (%args) = @_;
    my $key_file  = $args{key_file}  // $cli_ed;
    my $username  = $args{username}  // 'secuser';
    my $extra_opt  = $args{extra_opt}  // '';
    my $payload_sz = $args{payload_sz} // 2048;
    my $rekey_bytes = $args{rekey_bytes};
    my $res_file   = "$tmp/res_" . int(rand(1e9)) . ".txt";

    my $listen = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 5,
        ReuseAddr => 1,
    ) or die "listen failed: $!";
    my $port = $listen->sockport;

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        eval {
            my $client = $listen->accept() or die "accept failed: $!";
            my $sess = Shop::SSH::Session->accept(
                sock        => $client,
                hostkey     => $hk,
                (defined($rekey_bytes) ? (rekey_bytes => $rekey_bytes) : ()),
            );

            my $chunk = "SEC-OK:" . ("A" x 60) . "\r\n";
            my $sent = 0;
            while ($sent < $payload_sz) {
                $sess->write_output($chunk);
                $sent += length($chunk);
            }
            $sess->write_output("DONE-BANNER\r\n");

            my $buf = '';
            my $deadline = time() + 10;
            while (time() < $deadline) {
                my $in = $sess->read_input_nonblock();
                last if !defined($in);
                if (length($in) > 0) {
                    $buf .= $in;
                    $sess->write_output("ACK:$in");
                    last if $buf =~ /quit/;
                } else {
                    sleep(0.01);
                }
            }

            my $sec  = $sess->security_info();
            my $env  = $sess->env();
            my $user = $sess->user();
            my $st   = $sess->transport->stats();

            open my $rfh, '>', $res_file or die $!;
            print $rfh "kex=$sec->{kex}\n";
            print $rfh "cipher=$sec->{cipher}\n";
            print $rfh "compression=$sec->{compression}\n";
            print $rfh "strict_kex=$sec->{strict_kex}\n";
            print $rfh "is_pq=$sec->{is_pq}\n";
            print $rfh "rekey_count=$st->{rekey_count}\n";
            print $rfh "pubkey_type=$user->{pubkey_type}\n";
            print $rfh "fingerprint=$user->{fingerprint}\n";
            print $rfh "env_term=" . ($env->{TERM} // '') . "\n";
            print $rfh "env_colorterm=" . ($env->{COLORTERM} // '') . "\n";
            close $rfh;

            $sess->close(0);
        };
        if ($@) {
            open my $rfh, '>', $res_file;
            print $rfh "error=$@\n";
            close $rfh;
        }
        close $listen;
        exit 0;
    }

    close $listen;

    my $stderr_file = "$tmp/err_" . int(rand(1e9)) . ".log";
    my $stdout_file = "$tmp/out_" . int(rand(1e9)) . ".log";

    local $ENV{COLORTERM} = 'truecolor';
    my $cmd = "/usr/bin/ssh -vv -tt -C "
            . "-o BatchMode=yes "
            . "-o StrictHostKeyChecking=no "
            . "-o UserKnownHostsFile=/dev/null "
            . "-o IdentitiesOnly=yes "
            . "-o PreferredAuthentications=publickey "
            . "-o SendEnv=COLORTERM "
            . "-o ConnectTimeout=10 "
            . "$extra_opt "
            . "-i '$key_file' -p $port $username\@127.0.0.1 "
            . ">'$stdout_file' 2>'$stderr_file'";

    local $SIG{PIPE} = 'IGNORE';
    open my $ssh_in, '|-', $cmd or die "Failed to spawn ssh: $!";
    sleep(0.5);
    print $ssh_in "ping\nquit\n";
    close $ssh_in;
    my $rc = $? >> 8;

    waitpid($pid, 0);

    my %srv;
    if (open my $rfh, '<', $res_file) {
        while (<$rfh>) {
            chomp;
            my ($k, $v) = split /=/, $_, 2;
            $srv{$k} = $v if defined $k;
        }
        close $rfh;
    }
    local $/;
    my $out = ''; if (open my $f, '<:raw', $stdout_file) { $out = <$f>; close $f; }
    my $err = ''; if (open my $f, '<:raw', $stderr_file) { $err = <$f>; close $f; }

    return ($rc, $out, $err, \%srv);
}

# 1. Post-Quantum Hybrid KEX (mlkem768x25519-sha256) + strict-kex + zlib@openssh.com + env capture
{
    my ($rc, $out, $err, $srv) = run_ssh_case(key_file => $cli_ed, username => 'pq_buyer');
    diag("PQ error: $srv->{error}") if $srv->{error};
    ok(!$srv->{error}, 'PQ hybrid KEX session completed without error');
    is($rc, 0, 'real /usr/bin/ssh exited 0 with PQ hybrid KEX');
    like($err, qr/kex: algorithm: mlkem768x25519-sha256/, 'OpenSSH negotiated mlkem768x25519-sha256');
    like($err, qr/kex-strict-s-v00\@openssh\.com/, 'OpenSSH observed kex-strict-s-v00@openssh.com');
    like($err, qr/zlib\@openssh\.com/, 'OpenSSH negotiated zlib@openssh.com');
    is($srv->{kex}, 'mlkem768x25519-sha256', 'security_info kex is mlkem768x25519-sha256');
    is($srv->{cipher}, 'chacha20-poly1305@openssh.com', 'security_info cipher is chacha20-poly1305@openssh.com');
    is($srv->{compression}, 'zlib@openssh.com', 'security_info compression is zlib@openssh.com');
    is($srv->{strict_kex}, '1', 'security_info strict_kex is 1');
    is($srv->{is_pq}, '1', 'security_info is_pq is 1');
    is($srv->{env_colorterm}, 'truecolor', 'Session->env captured COLORTERM=truecolor');
    ok(length($srv->{env_term}) > 0, "Session->env captured TERM=$srv->{env_term}");
    like($out, qr/DONE-BANNER/, 'client received banner over PQ channel');
}

# 2. aes256-gcm@openssh.com cipher interop with real /usr/bin/ssh
{
    my ($rc, $out, $err, $srv) = run_ssh_case(
        key_file  => $cli_ed,
        username  => 'gcm_buyer',
        extra_opt => '-c aes256-gcm@openssh.com',
    );
    diag("AES-GCM error: $srv->{error}") if $srv->{error};
    ok(!$srv->{error}, 'aes256-gcm@openssh.com session completed without error');
    is($rc, 0, 'real /usr/bin/ssh -c aes256-gcm@openssh.com exited 0');
    like($err, qr/cipher: aes256-gcm\@openssh\.com/, 'OpenSSH negotiated aes256-gcm@openssh.com');
    is($srv->{cipher}, 'aes256-gcm@openssh.com', 'security_info reports aes256-gcm@openssh.com');
    like($out, qr/ACK:.*ping/s, 'bidirectional aes256-gcm traffic succeeded');
}

# 3. ecdsa-sha2-nistp256 user key auth with real /usr/bin/ssh
{
    my ($rc, $out, $err, $srv) = run_ssh_case(
        key_file => $cli_ecdsa,
        username => 'ecdsa_buyer',
    );
    diag("ECDSA error: $srv->{error}") if $srv->{error};
    ok(!$srv->{error}, 'ecdsa-sha2-nistp256 auth session completed without error');
    is($rc, 0, 'real /usr/bin/ssh with ECDSA P-256 key exited 0');
    is($srv->{pubkey_type}, 'ecdsa-sha2-nistp256', 'server authenticated ecdsa-sha2-nistp256');
    is($srv->{fingerprint}, $ecdsa_fp, 'server extracted exact ECDSA P-256 SHA256 fingerprint');
}

# 4. Mid-session rekeying with real /usr/bin/ssh (byte-threshold triggered mid-session KEXINIT)
{
    my ($rc, $out, $err, $srv) = run_ssh_case(
        key_file    => $cli_ed,
        username    => 'rekey_buyer',
        extra_opt   => '-o Compression=no',
        payload_sz  => 24576,
        rekey_bytes => 8192,
    );
    diag("Rekey error: $srv->{error}") if $srv->{error};
    if ($rc != 0) {
        my @lines = split /\n/, $err;
        diag("SSH stderr tail:\n" . join("\n", @lines[-20 .. -1]));
    }
    ok(!$srv->{error}, 'mid-session rekey session completed without error');
    is($rc, 0, 'real /usr/bin/ssh survived mid-session rekey with exit 0');
    cmp_ok($srv->{rekey_count}, '>=', 1, "server completed $srv->{rekey_count} mid-session rekey(s)");
    like($out, qr/ACK:.*ping/s, 'bidirectional traffic continued cleanly after mid-session rekey');
}

# 5. Terrapin (CVE-2023-48795) adversarial pre-NEWKEYS SSH_MSG_IGNORE injection test
{
    my sub pack_plain_ssh_pkt {
        my ($payload) = @_;
        my $pad_len = 8 - ((4 + 1 + length($payload)) % 8);
        $pad_len += 8 if $pad_len < 4;
        my $inner = pack('C', $pad_len) . $payload . ("\x00" x $pad_len);
        return pack('N', length($inner)) . $inner;
    }

    my $listen = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 5,
        ReuseAddr => 1,
    ) or die "listen failed: $!";
    my $port = $listen->sockport;

    my $srv_err_file = "$tmp/terrapin_srv.txt";
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        my $c = $listen->accept();
        my $tr = Shop::SSH::Transport->new(sock => $c, hostkey => $hk);
        eval { $tr->handshake(5) };
        my $err = $@ || 'NO_ERROR';
        open my $fh, '>', $srv_err_file;
        print $fh $err;
        close $fh;
        close $listen;
        exit 0;
    }
    close $listen;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    ) or die "connect failed: $!";

    # Read server banner and send client banner
    my $srv_banner = <$sock>;
    like($srv_banner, qr/^SSH-2\.0-/, 'Terrapin test: received server banner');
    print $sock "SSH-2.0-TerrapinAttacker_1.0\r\n";

    # Send valid client KEXINIT offering kex-strict-c-v00@openssh.com
    my $cli_kexinit = pack_byte(SSH_MSG_KEXINIT)
                    . random_bytes(16)
                    . pack_namelist('curve25519-sha256', 'kex-strict-c-v00@openssh.com')
                    . pack_namelist('ssh-ed25519')
                    . pack_namelist('chacha20-poly1305@openssh.com')
                    . pack_namelist('chacha20-poly1305@openssh.com')
                    . pack_namelist('hmac-sha2-256')
                    . pack_namelist('hmac-sha2-256')
                    . pack_namelist('none')
                    . pack_namelist('none')
                    . pack_namelist()
                    . pack_namelist()
                    . pack_bool(0)
                    . pack_u32(0);
    print $sock pack_plain_ssh_pkt($cli_kexinit);

    # Inject rogue SSH_MSG_IGNORE before NEWKEYS!
    my $ignore_pkt = pack_byte(SSH_MSG_IGNORE) . pack_string('terrapin-sequence-shift');
    print $sock pack_plain_ssh_pkt($ignore_pkt);

    # Read server packets until we see SSH_MSG_DISCONNECT (1)
    my $saw_disconnect = 0;
    my $disconnect_reason = 0;
    my $buf = '';
    my $deadline = time() + 3;
    while (time() < $deadline) {
        my $tmp_in = '';
        my $n = sysread($sock, $tmp_in, 4096);
        last if !defined($n) || $n == 0;
        $buf .= $tmp_in;
        while (length($buf) >= 4) {
            my $plen = unpack('N', substr($buf, 0, 4));
            last if length($buf) < 4 + $plen;
            my $inner = substr($buf, 4, $plen);
            substr($buf, 0, 4 + $plen, '');
            my $pad_len = ord(substr($inner, 0, 1));
            my $pl = substr($inner, 1, length($inner) - 1 - $pad_len);
            my $mtype = ord(substr($pl, 0, 1));
            if ($mtype == SSH_MSG_DISCONNECT) {
                $saw_disconnect = 1;
                my $off = 1;
                $disconnect_reason = unpack_u32($pl, \$off);
                last;
            }
        }
        last if $saw_disconnect;
    }
    close $sock;
    waitpid($pid, 0);

    my $srv_err = '';
    if (open my $fh, '<', $srv_err_file) { local $/; $srv_err = <$fh>; close $fh; }

    ok($saw_disconnect, 'Terrapin: server sent SSH_MSG_DISCONNECT on pre-NEWKEYS SSH_MSG_IGNORE');
    is($disconnect_reason, SSH_DISCONNECT_PROTOCOL_ERROR, 'Terrapin: disconnect reason is SSH_DISCONNECT_PROTOCOL_ERROR (2)');
    like($srv_err, qr/expected KEX_INIT \(30\), got 2/, 'Terrapin: server aborted handshake on opcode 2 (IGNORE)');
}

# 6. Zip-Bomb Protection in Shop::SSH::Crypto::Zlib::inflate
{
    my $z_tx = Shop::SSH::Crypto::Zlib->new(9);
    my $z_rx = Shop::SSH::Crypto::Zlib->new(9);

    # 2 MiB of zeros compresses to ~2 KiB!
    my $zeros = "\x00" x (2 * 1024 * 1024);
    my $bomb  = $z_tx->deflate($zeros);
    cmp_ok(length($bomb), '<', 4096, "2 MiB zip bomb compressed to " . length($bomb) . " bytes");

    eval { $z_rx->inflate($bomb) };
    like($@, qr/SSH_ZIP_BOMB/, 'Zlib::inflate rejects 2 MiB zip bomb with SSH_ZIP_BOMB');

    # Custom max_out boundary test
    my $z2_tx = Shop::SSH::Crypto::Zlib->new(6);
    my $z2_rx = Shop::SSH::Crypto::Zlib->new(6);
    my $exact = "X" x 1024;
    my $c_exact = $z2_tx->deflate($exact);
    is($z2_rx->inflate($c_exact, 1024), $exact, 'Zlib::inflate accepts exact max_out (1024 bytes)');

    my $over = "Y" x 1025;
    my $c_over = $z2_tx->deflate($over);
    eval { $z2_rx->inflate($c_over, 1024) };
    like($@, qr/SSH_ZIP_BOMB/, 'Zlib::inflate rejects max_out+1 (1025 bytes) with SSH_ZIP_BOMB');
}

# 7. Tampered Poly1305 and AES-256-GCM AEAD tag rejection
{
    my $k1 = random_bytes(32);
    my $k2 = random_bytes(32);
    my $iv = random_bytes(12);
    my $pt = ("\x00" x 32);

    my $cp = chacha20_poly1305_openssh_encrypt($k1, $k2, 0, $pt);
    my $cp_tag = substr($cp, -16);
    substr($cp_tag, 15, 1) ^= "\x01";
    ok(!defined(chacha20_poly1305_openssh_decrypt_body($k1, 0, substr($cp, 0, 4), substr($cp, 4, 32), $cp_tag)),
       'tampered Poly1305 tag cleanly rejected with undef');

    my $aad = pack('N', length($pt));
    my $gp = aes256_gcm_openssh_encrypt($k1, $iv, 0, $aad, $pt);
    my $gp_tag = substr($gp, -16);
    substr($gp_tag, 15, 1) ^= "\x01";
    ok(!defined(aes256_gcm_openssh_decrypt($k1, $iv, 0, $aad, substr($gp, 4, 32), $gp_tag)),
       'tampered AES-256-GCM tag cleanly rejected with undef');
}

done_testing();
