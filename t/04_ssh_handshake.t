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
use Shop::SSH::Wire qw(load_or_generate_hostkey load_openssh_ed25519_key);
use Shop::SSH::Session;

my $tmp = tempdir(CLEANUP => 1);

# 1. Hostkey generation + reload + ssh-keygen -lf interop
my $hostkey_path = "$tmp/ssh_host_ed25519_key";
my $hk1 = load_or_generate_hostkey($hostkey_path);
ok(-f $hostkey_path, 'hostkey file created');
like($hk1->{fingerprint}, qr/^SHA256:[A-Za-z0-9+\/]+$/, 'hostkey fingerprint format');

my $hk2 = load_openssh_ed25519_key($hostkey_path);
is($hk2->{pk}, $hk1->{pk}, 'reloaded hostkey pk matches');
is($hk2->{sk}, $hk1->{sk}, 'reloaded hostkey sk matches');
is($hk2->{fingerprint}, $hk1->{fingerprint}, 'reloaded hostkey fingerprint matches');

# Verify ssh-keygen can read our generated hostkey and computes identical fingerprint
my $skg_fp_out = `ssh-keygen -lf '$hostkey_path' 2>&1`;
is($?, 0, 'ssh-keygen -lf parses our generated OpenSSH ed25519 hostkey');
like($skg_fp_out, qr/\Q$hk1->{fingerprint}\E/, 'hostkey SHA256 fingerprint matches ssh-keygen -lf');

# 2. Generate client ed25519 key and client RSA key
my $cli_ed = "$tmp/client_ed25519";
system("ssh-keygen -q -t ed25519 -N '' -f '$cli_ed'") == 0 or die "ssh-keygen ed25519 failed";
my ($expected_ed_fp) = (`ssh-keygen -lf '$cli_ed.pub'` =~ /(SHA256:\S+)/);
ok(defined $expected_ed_fp, "client ed25519 fingerprint: $expected_ed_fp");

my $cli_rsa = "$tmp/client_rsa";
system("ssh-keygen -q -t rsa -b 2048 -N '' -f '$cli_rsa'") == 0 or die "ssh-keygen rsa failed";
my ($expected_rsa_fp) = (`ssh-keygen -lf '$cli_rsa.pub'` =~ /(SHA256:\S+)/);
ok(defined $expected_rsa_fp, "client rsa fingerprint: $expected_rsa_fp");

sub run_ssh_roundtrip {
    my (%args) = @_;
    my $key_file  = $args{key_file};
    my $username  = $args{username} // 'shopper';
    my $extra_opt = $args{extra_opt} // '';
    my $res_file  = "$tmp/srv_result_" . int(rand(1e9)) . ".txt";

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
        # Child: run native Perl SSHv2 server for 1 connection
        eval {
            my $client = $listen->accept() or die "accept failed: $!";
            my $sess = Shop::SSH::Session->accept(
                sock    => $client,
                hostkey => $hk1,
            );

            my ($cols, $rows) = $sess->size();
            # Send repetitive ANSI TUI payload to exercise zlib@openssh.com compression
            my $banner = "WELCOME:$username:${cols}x${rows}\r\n"
                       . ("\e[32m| ITEM-001 | Artisan Espresso | \$19.99 | STOCK: 50 |\e[0m\r\n" x 40)
                       . "READY>\r\n";
            $sess->write_output($banner);

            my $buf = '';
            my $deadline = time() + 10;
            while (time() < $deadline) {
                my $in = $sess->read_input_nonblock();
                last if !defined($in);
                if (length($in) > 0) {
                    $buf .= $in;
                    $sess->write_output("ECHO:$in");
                    last if $buf =~ /quit/;
                } else {
                    sleep(0.01);
                }
            }

            my $st   = $sess->egress_stats();
            my $user = $sess->user();
            open my $rfh, '>', $res_file or die $!;
            print $rfh "username=$user->{username}\n";
            print $rfh "fingerprint=$user->{fingerprint}\n";
            print $rfh "pubkey_type=$user->{pubkey_type}\n";
            print $rfh "is_guest=$user->{is_guest}\n";
            print $rfh "cols=$cols\n";
            print $rfh "rows=$rows\n";
            print $rfh "compression=$st->{compression}\n";
            print $rfh "raw_tx_bytes=$st->{raw_tx_bytes}\n";
            print $rfh "wire_tx_bytes=$st->{wire_tx_bytes}\n";
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

    # Parent: launch real /usr/bin/ssh client
    my $stderr_file = "$tmp/ssh_stderr_" . int(rand(1e9)) . ".log";
    my $stdout_file = "$tmp/ssh_stdout_" . int(rand(1e9)) . ".log";

    my $cmd = "/usr/bin/ssh -v -tt -C "
            . "-o BatchMode=yes "
            . "-o StrictHostKeyChecking=no "
            . "-o UserKnownHostsFile=/dev/null "
            . "-o IdentitiesOnly=yes "
            . "-o PreferredAuthentications=publickey "
            . "-o ConnectTimeout=10 "
            . "$extra_opt "
            . "-i '$key_file' -p $port $username\@127.0.0.1 "
            . ">'$stdout_file' 2>'$stderr_file'";

    open my $ssh_in, '|-', $cmd or die "Failed to spawn ssh: $!";
    # Wait briefly for banner then send "quit\n"
    sleep(0.4);
    print $ssh_in "hello-perl5-mt\nquit\n";
    close $ssh_in;
    my $exit_code = $? >> 8;

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
    my $stdout = '';
    if (open my $fh, '<:raw', $stdout_file) { $stdout = <$fh>; close $fh; }
    my $stderr = '';
    if (open my $fh, '<:raw', $stderr_file) { $stderr = <$fh>; close $fh; }

    return ($exit_code, $stdout, $stderr, \%srv);
}

# 3. Real /usr/bin/ssh test with ed25519 key + zlib@openssh.com compression
{
    my ($rc, $out, $err, $srv) = run_ssh_roundtrip(
        key_file => $cli_ed,
        username => 'alice',
    );
    diag("Server error: $srv->{error}") if $srv->{error};
    ok(!$srv->{error}, 'ed25519 server session completed without error');
    is($rc, 0, 'real /usr/bin/ssh exited cleanly with status 0');
    like($err, qr/kex: algorithm: (?:mlkem768x25519-sha256|curve25519-sha256)/, 'OpenSSH negotiated PQ mlkem768x25519-sha256 or curve25519-sha256');
    like($err, qr/kex: host key algorithm: ssh-ed25519/, 'OpenSSH verified ssh-ed25519 hostkey');
    like($err, qr/chacha20-poly1305\@openssh\.com/, 'OpenSSH negotiated chacha20-poly1305@openssh.com');
    like($err, qr/zlib\@openssh\.com/, 'OpenSSH negotiated zlib@openssh.com compression');

    is($srv->{username}, 'alice', 'server received username alice');
    is($srv->{fingerprint}, $expected_ed_fp, 'server extracted exact ed25519 SHA256 fingerprint');
    is($srv->{pubkey_type}, 'ssh-ed25519', 'server recorded pubkey_type ssh-ed25519');
    is($srv->{is_guest}, '0', 'authenticated user is not guest');
    is($srv->{compression}, 'zlib@openssh.com', 'server activated zlib@openssh.com after USERAUTH_SUCCESS');

    like($out, qr/WELCOME:alice:/, 'client received server welcome banner over encrypted+compressed channel');
    like($out, qr/ECHO:.*hello-perl5-mt/s, 'client received PTY echo back from server');

    cmp_ok($srv->{raw_tx_bytes}, '>', 2000, "raw_tx_bytes ($srv->{raw_tx_bytes}) > 2000");
    cmp_ok($srv->{wire_tx_bytes}, '<', $srv->{raw_tx_bytes},
           sprintf("zlib\@openssh.com reduced wire egress: %d -> %d bytes (%.1f%% savings)",
                   $srv->{raw_tx_bytes}, $srv->{wire_tx_bytes},
                   100.0 * (1.0 - $srv->{wire_tx_bytes} / $srv->{raw_tx_bytes})));
}

# 4. Real /usr/bin/ssh test with RSA key (rsa-sha2-512 / rsa-sha2-256)
{
    my ($rc, $out, $err, $srv) = run_ssh_roundtrip(
        key_file => $cli_rsa,
        username => 'bob',
    );
    diag("Server error: $srv->{error}") if $srv->{error};
    ok(!$srv->{error}, 'RSA server session completed without error');
    is($rc, 0, 'real /usr/bin/ssh (RSA) exited cleanly with status 0');
    is($srv->{username}, 'bob', 'server received username bob');
    is($srv->{fingerprint}, $expected_rsa_fp, 'server extracted exact RSA SHA256 fingerprint');
    like($srv->{pubkey_type}, qr/^rsa-sha2-(?:256|512)$/, "server verified RSA SHA2 ($srv->{pubkey_type})");
    is($srv->{is_guest}, '0', 'RSA user is not guest');
    like($out, qr/WELCOME:bob:/, 'RSA client received server welcome banner');
}

done_testing();
