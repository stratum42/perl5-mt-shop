package Shop::SSH::Auth;

use strict;
use warnings;
use Time::HiRes qw(time);
use Shop::SSH::Crypto qw(ed25519_verify rsa_sha2_verify ecdsa_p256_verify);
use Shop::SSH::Wire qw(:all);

my %SUPPORTED_PUBKEY_ALGS = (
    'ssh-ed25519'         => 1,
    'ecdsa-sha2-nistp256' => 1,
    'rsa-sha2-256'        => 1,
    'rsa-sha2-512'        => 1,
);

sub authenticate {
    my ($class_or_self, $transport, %opts) = @_;
    my $allow_guest      = exists($opts{allow_guest})      ? $opts{allow_guest}      : 1;
    my $prefer_publickey = exists($opts{prefer_publickey}) ? $opts{prefer_publickey} : 1;
    my $timeout          = $opts{timeout} // 30;
    my $max_attempts     = $opts{max_attempts} // 12;
    my $verify_key_cb    = $opts{verify_key_cb};

    my $deadline = time() + $timeout;

    # 1. Expect SSH_MSG_SERVICE_REQUEST("ssh-userauth")
    my $svc_pkt = $transport->recv_packet_blocking($deadline - time());
    die "SSH::Auth: EOF/timeout waiting for SERVICE_REQUEST" unless defined $svc_pkt;
    my $off = 0;
    my $mtype = unpack_byte($svc_pkt, \$off);
    die "SSH::Auth: expected SERVICE_REQUEST (5), got $mtype"
        unless $mtype == SSH_MSG_SERVICE_REQUEST;
    my $svc_name = unpack_string($svc_pkt, \$off);
    if ($svc_name ne 'ssh-userauth') {
        $transport->disconnect(SSH_DISCONNECT_SERVICE_NOT_AVAILABLE, "Unsupported service: $svc_name");
        die "SSH::Auth: unsupported service '$svc_name'";
    }
    $transport->send_packet(pack_byte(SSH_MSG_SERVICE_ACCEPT) . pack_string('ssh-userauth'))
        or die "SSH::Auth: failed to send SERVICE_ACCEPT";

    # 2. Process SSH_MSG_USERAUTH_REQUEST loop
    my $attempts  = 0;
    my $none_seen = 0;
    my @methods   = ('publickey');
    push @methods, 'keyboard-interactive' if $allow_guest;

    while ($attempts < $max_attempts) {
        my $rem = $deadline - time();
        die "SSH::Auth: authentication timeout" if $rem <= 0;

        my $pkt = $transport->recv_packet_blocking($rem);
        die "SSH::Auth: EOF during authentication" unless defined $pkt;

        $off = 0;
        $mtype = unpack_byte($pkt, \$off);
        if ($mtype != SSH_MSG_USERAUTH_REQUEST) {
            # Ignore unexpected non-auth packets during auth
            next;
        }

        $attempts++;
        my $username = unpack_string($pkt, \$off);
        my $service  = unpack_string($pkt, \$off);
        my $method   = unpack_string($pkt, \$off);

        if ($service ne 'ssh-connection') {
            $transport->send_packet(
                pack_byte(SSH_MSG_USERAUTH_FAILURE) . pack_namelist(@methods) . pack_bool(0)
            );
            next;
        }

        if ($method eq 'publickey') {
            my $has_sig  = unpack_bool($pkt, \$off);
            my $alg_name = unpack_string($pkt, \$off);
            my $pub_blob = unpack_string($pkt, \$off);

            unless ($SUPPORTED_PUBKEY_ALGS{$alg_name} && _valid_key_blob($alg_name, $pub_blob)) {
                $transport->send_packet(
                    pack_byte(SSH_MSG_USERAUTH_FAILURE) . pack_namelist(@methods) . pack_bool(0)
                );
                next;
            }

            my $fp = pubkey_fingerprint($pub_blob);
            if ($verify_key_cb && !$verify_key_cb->($username, $fp, $alg_name, $pub_blob)) {
                $transport->send_packet(
                    pack_byte(SSH_MSG_USERAUTH_FAILURE) . pack_namelist(@methods) . pack_bool(0)
                );
                next;
            }

            if (!$has_sig) {
                # RFC 4252 §7 publickey query: acknowledge key is acceptable
                $transport->send_packet(
                    pack_byte(SSH_MSG_USERAUTH_PK_OK)
                    . pack_string($alg_name)
                    . pack_string($pub_blob)
                );
                next;
            }

            my $sig_blob = unpack_string($pkt, \$off);
            my $signed_data = pack_string($transport->session_id)
                            . pack_byte(SSH_MSG_USERAUTH_REQUEST)
                            . pack_string($username)
                            . pack_string($service)
                            . pack_string('publickey')
                            . pack_bool(1)
                            . pack_string($alg_name)
                            . pack_string($pub_blob);

            if (_verify_signature($alg_name, $pub_blob, $signed_data, $sig_blob)) {
                # Send USERAUTH_SUCCESS uncompressed, then activate zlib@openssh.com!
                $transport->send_packet(pack_byte(SSH_MSG_USERAUTH_SUCCESS))
                    or die "SSH::Auth: failed to send USERAUTH_SUCCESS";
                $transport->enable_compression();
                return {
                    username    => $username,
                    fingerprint => $fp,
                    pubkey_type => $alg_name,
                    pubkey_blob => $pub_blob,
                    is_guest    => 0,
                };
            }

            $transport->send_packet(
                pack_byte(SSH_MSG_USERAUTH_FAILURE) . pack_namelist(@methods) . pack_bool(0)
            );
            next;
        }

        if ($method eq 'none') {
            $none_seen++;
            if ($allow_guest && (!$prefer_publickey || $none_seen > 1)) {
                $transport->send_packet(pack_byte(SSH_MSG_USERAUTH_SUCCESS))
                    or die "SSH::Auth: failed to send USERAUTH_SUCCESS";
                $transport->enable_compression();
                return {
                    username    => $username || 'guest',
                    fingerprint => '',
                    pubkey_type => 'none',
                    pubkey_blob => '',
                    is_guest    => 1,
                };
            }
            $transport->send_packet(
                pack_byte(SSH_MSG_USERAUTH_FAILURE) . pack_namelist(@methods) . pack_bool(0)
            );
            next;
        }

        if ($method eq 'keyboard-interactive' && $allow_guest) {
            # Accept guest fallback when client has no publickey
            $transport->send_packet(pack_byte(SSH_MSG_USERAUTH_SUCCESS))
                or die "SSH::Auth: failed to send USERAUTH_SUCCESS";
            $transport->enable_compression();
            return {
                username    => $username || 'guest',
                fingerprint => '',
                pubkey_type => 'none',
                pubkey_blob => '',
                is_guest    => 1,
            };
        }

        $transport->send_packet(
            pack_byte(SSH_MSG_USERAUTH_FAILURE) . pack_namelist(@methods) . pack_bool(0)
        );
    }

    $transport->disconnect(SSH_DISCONNECT_NO_MORE_AUTH_METHODS_AVAILABLE, 'Too many auth failures');
    die "SSH::Auth: too many authentication attempts";
}

sub _valid_key_blob {
    my ($alg_name, $blob) = @_;
    if ($alg_name eq 'ssh-ed25519') {
        return defined(parse_ed25519_pubkey_blob($blob)) ? 1 : 0;
    }
    if ($alg_name eq 'ecdsa-sha2-nistp256') {
        return defined(parse_ecdsa_p256_pubkey_blob($blob)) ? 1 : 0;
    }
    if ($alg_name eq 'rsa-sha2-256' || $alg_name eq 'rsa-sha2-512') {
        my ($e, $n) = parse_rsa_pubkey_blob($blob);
        return (defined($e) && defined($n)) ? 1 : 0;
    }
    return 0;
}

sub _verify_signature {
    my ($alg_name, $pub_blob, $signed_data, $sig_blob) = @_;
    my $off = 0;
    my $sig_alg = eval { unpack_string($sig_blob, \$off) };
    return 0 if $@ || !defined($sig_alg) || $sig_alg ne $alg_name;
    my $sig_raw = eval { unpack_string($sig_blob, \$off) };
    return 0 if $@ || !defined($sig_raw);

    if ($alg_name eq 'ssh-ed25519') {
        my $pk32 = parse_ed25519_pubkey_blob($pub_blob);
        return 0 unless defined $pk32;
        return ed25519_verify($signed_data, $sig_raw, $pk32);
    }

    if ($alg_name eq 'ecdsa-sha2-nistp256') {
        my $q = parse_ecdsa_p256_pubkey_blob($pub_blob);
        return 0 unless defined $q;
        my $soff = 0;
        my $r = eval { unpack_mpint($sig_raw, \$soff) };
        return 0 if $@ || !defined($r) || length($r) == 0;
        my $s = eval { unpack_mpint($sig_raw, \$soff) };
        return 0 if $@ || !defined($s) || length($s) == 0;
        return ecdsa_p256_verify($signed_data, $r, $s, $q);
    }

    if ($alg_name eq 'rsa-sha2-256' || $alg_name eq 'rsa-sha2-512') {
        my ($e, $n) = parse_rsa_pubkey_blob($pub_blob);
        return 0 unless defined($e) && defined($n);
        my $bits = ($alg_name eq 'rsa-sha2-256') ? 256 : 512;
        return rsa_sha2_verify($signed_data, $sig_raw, $n, $e, $bits);
    }

    return 0;
}

1;
