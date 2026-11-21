#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib",
        "$FindBin::Bin/../xs/Shop-SSH-Crypto/blib/lib",
        "$FindBin::Bin/../xs/Shop-SSH-Crypto/blib/arch";
use Test::More;
use MT;
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
    chacha20_poly1305_openssh_encrypt
    chacha20_poly1305_openssh_decrypt_len
    chacha20_poly1305_openssh_decrypt_body
    aes256_gcm_openssh_encrypt
    aes256_gcm_openssh_decrypt
);

# 1. Verify Tier-1 thread-safe XS metadata
ok(MT::XS::is_threadsafe(\&Shop::SSH::Crypto::sha256), 'sha256 is marked Tier-1 threadsafe');
ok(!MT::XS::is_remote(\&Shop::SSH::Crypto::sha256), 'sha256 runs in-process (not remote compartment)');
ok(MT::XS::is_threadsafe(\&Shop::SSH::Crypto::chacha20_poly1305_openssh_encrypt), 'chacha20_poly1305_openssh_encrypt is threadsafe');
ok(MT::XS::is_threadsafe(\&Shop::SSH::Crypto::Zlib::deflate), 'Zlib::deflate is threadsafe');

# 2. random_bytes
my $r1 = random_bytes(32);
my $r2 = random_bytes(32);
is(length($r1), 32, 'random_bytes(32) length');
isnt($r1, $r2, 'two random_bytes(32) calls differ');
is(length(random_bytes(0)), 0, 'random_bytes(0) returns empty string');

# 3. sha256 (NIST vector for "abc")
my $h_abc = unpack('H*', sha256("abc"));
is($h_abc, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'sha256("abc") matches NIST vector');

# 4. x25519 key agreement
my ($a_sk, $a_pk) = x25519_keypair();
my ($b_sk, $b_pk) = x25519_keypair();
is(length($a_sk), 32, 'x25519 sk is 32 bytes');
is(length($a_pk), 32, 'x25519 pk is 32 bytes');
my $sh_ab = x25519_shared($a_sk, $b_pk);
my $sh_ba = x25519_shared($b_sk, $a_pk);
is(length($sh_ab), 32, 'x25519 shared secret is 32 bytes');
is($sh_ab, $sh_ba, 'x25519 DH shared secrets match');
ok(!defined(x25519_shared($a_sk, "\0" x 32)), 'x25519 rejects all-zero low-order point');

# 5. ed25519 sign & verify
my ($ed_sk, $ed_pk) = ed25519_keypair();
is(length($ed_sk), 64, 'ed25519 sk is 64 bytes');
is(length($ed_pk), 32, 'ed25519 pk is 32 bytes');
my $msg = "SSHv2 exchange hash test payload";
my $sig = ed25519_sign($msg, $ed_sk);
is(length($sig), 64, 'ed25519 sig is 64 bytes');
is(ed25519_verify($msg, $sig, $ed_pk), 1, 'ed25519_verify accepts valid sig');
is(ed25519_verify($msg . "x", $sig, $ed_pk), 0, 'ed25519_verify rejects modified message');
my $bad_sig = $sig;
substr($bad_sig, 0, 1) ^= "\x01";
is(ed25519_verify($msg, $bad_sig, $ed_pk), 0, 'ed25519_verify rejects tampered sig');

# ed25519_seed_keypair determinism
my $seed = random_bytes(32);
my ($s_sk1, $s_pk1) = ed25519_seed_keypair($seed);
my ($s_sk2, $s_pk2) = ed25519_seed_keypair($seed);
is($s_sk1, $s_sk2, 'ed25519_seed_keypair deterministic sk');
is($s_pk1, $s_pk2, 'ed25519_seed_keypair deterministic pk');

# 6. rsa_sha2_verify (test with real OpenSSL generated key & signatures)
{
    require File::Temp;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my $key_pem = "$dir/rsa.pem";
    my $msg_file = "$dir/msg.bin";
    my $sig256_file = "$dir/sig256.bin";
    my $sig512_file = "$dir/sig512.bin";

    open my $mfh, '>:raw', $msg_file or die $!;
    print $mfh $msg;
    close $mfh;

    my $rc = system("openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out '$key_pem' 2>/dev/null");
    SKIP: {
        skip "openssl CLI unavailable", 4 if $rc != 0;
        system("openssl dgst -sha256 -sign '$key_pem' -out '$sig256_file' '$msg_file' 2>/dev/null") == 0 or die "openssl sign256 failed";
        system("openssl dgst -sha512 -sign '$key_pem' -out '$sig512_file' '$msg_file' 2>/dev/null") == 0 or die "openssl sign512 failed";

        my $txt = `openssl pkey -in '$key_pem' -pubout -text -noout 2>/dev/null`;
        my ($mod_hex) = $txt =~ /Modulus:\s*([0-9a-fA-F:\s]+?)\s*Exponent:/s;
        $mod_hex =~ s/[^0-9a-fA-F]//g;
        $mod_hex =~ s/^00//;
        my $n_bin = pack('H*', $mod_hex);
        my ($exp_dec) = $txt =~ /Exponent:\s*(\d+)/;
        my $e_hex = sprintf('%x', $exp_dec);
        $e_hex = "0$e_hex" if length($e_hex) % 2;
        my $e_bin = pack('H*', $e_hex);

        open my $s256, '<:raw', $sig256_file or die $!;
        local $/;
        my $sig256 = <$s256>;
        close $s256;

        open my $s512, '<:raw', $sig512_file or die $!;
        my $sig512 = <$s512>;
        close $s512;

        is(rsa_sha2_verify($msg, $sig256, $n_bin, $e_bin, 256), 1, 'rsa_sha2_verify(256) accepts valid OpenSSL sig');
        is(rsa_sha2_verify($msg . "!", $sig256, $n_bin, $e_bin, 256), 0, 'rsa_sha2_verify(256) rejects modified msg');
        is(rsa_sha2_verify($msg, $sig512, $n_bin, $e_bin, 512), 1, 'rsa_sha2_verify(512) accepts valid OpenSSL sig');
        is(rsa_sha2_verify($msg, $sig256, $n_bin, $e_bin, 512), 0, 'rsa_sha2_verify(512) rejects sha256 sig');
    }
}

# 7. chacha20-poly1305@openssh.com encrypt / decrypt / tamper
{
    my $k1 = random_bytes(32);
    my $k2 = random_bytes(32);
    my $payload = "\x04" . ("hello ssh world!" x 8) . "\x00\x00\x00\x00";
    my $seq = 42;

    my $pkt = chacha20_poly1305_openssh_encrypt($k1, $k2, $seq, $payload);
    is(length($pkt), 4 + length($payload) + 16, 'chacha20-poly1305 wire length is 4 + payload + 16');

    my $enc4 = substr($pkt, 0, 4);
    my $enc_body = substr($pkt, 4, length($payload));
    my $tag16 = substr($pkt, 4 + length($payload), 16);

    my $dec_len = chacha20_poly1305_openssh_decrypt_len($k2, $seq, $enc4);
    is($dec_len, length($payload), 'decrypt_len recovers exact payload length');

    my $dec = chacha20_poly1305_openssh_decrypt_body($k1, $seq, $enc4, $enc_body, $tag16);
    is($dec, $payload, 'decrypt_body recovers exact payload');

    # Wrong sequence number fails MAC
    ok(!defined(chacha20_poly1305_openssh_decrypt_body($k1, $seq + 1, $enc4, $enc_body, $tag16)), 'wrong seq fails Poly1305 tag');

    # Tampered enc4 fails MAC
    my $bad_enc4 = $enc4;
    substr($bad_enc4, 0, 1) ^= "\x80";
    ok(!defined(chacha20_poly1305_openssh_decrypt_body($k1, $seq, $bad_enc4, $enc_body, $tag16)), 'tampered enc4 fails Poly1305 tag');

    # Tampered body fails MAC
    my $bad_body = $enc_body;
    substr($bad_body, 5, 1) ^= "\x01";
    ok(!defined(chacha20_poly1305_openssh_decrypt_body($k1, $seq, $enc4, $bad_body, $tag16)), 'tampered body fails Poly1305 tag');
}

# 8. Streaming zlib@openssh.com roundtrip & egress reduction
{
    my $z_tx = Shop::SSH::Crypto::Zlib->new(5);
    my $z_rx = Shop::SSH::Crypto::Zlib->new(5);

    my $ansi_frame = ("\e[38;5;46m| SKU-001 | Coffee Beans | \$18.50 | IN STOCK (42) |\e[0m\r\n" x 25);
    my $raw_total = 0;
    my $comp_total = 0;

    for my $i (1 .. 10) {
        my $chunk = $ansi_frame . "\e[24;1HStatus tick #$i\e[K";
        my $c = $z_tx->deflate($chunk);
        my $d = $z_rx->inflate($c);
        is($d, $chunk, "zlib streaming roundtrip packet #$i");
        $raw_total += length($chunk);
        $comp_total += length($c);
    }

    my $savings = 100.0 * (1.0 - $comp_total / $raw_total);
    cmp_ok($savings, '>', 80.0, sprintf('zlib streaming egress reduction %.1f%% > 80%% (%d -> %d bytes)', $savings, $raw_total, $comp_total));
}

# 8b. hmac_sha256 & const_time_eq (RFC 4231 test vector #1)
{
    my $key = "\x0b" x 20;
    my $data = "Hi There";
    my $mac = unpack('H*', hmac_sha256($key, $data));
    is($mac, 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7', 'hmac_sha256 matches RFC 4231 vector #1');

    is(const_time_eq("secret-token", "secret-token"), 1, 'const_time_eq returns 1 for equal strings');
    is(const_time_eq("secret-token", "secret-tokeN"), 0, 'const_time_eq returns 0 for differing strings');
    is(const_time_eq("short", "longer"), 0, 'const_time_eq returns 0 for differing lengths');
    is(const_time_eq("", ""), 1, 'const_time_eq returns 1 for empty strings');
    ok(MT::XS::is_threadsafe(\&Shop::SSH::Crypto::hmac_sha256), 'hmac_sha256 is Tier-1 threadsafe');
    ok(MT::XS::is_threadsafe(\&Shop::SSH::Crypto::const_time_eq), 'const_time_eq is Tier-1 threadsafe');
}

# 8c. aes256-gcm@openssh.com encrypt / decrypt / tamper
{
    my $key = random_bytes(32);
    my $iv  = random_bytes(12);
    my $payload = "\x04" . ("hello aes-256-gcm!!" x 3) . ("\x00" x 6);
    # Pad to multiple of 16 bytes
    $payload .= "\x00" x ((16 - (length($payload) % 16)) % 16);
    my $aad4 = pack('N', length($payload));
    my $seq  = 7;

    my $wire = aes256_gcm_openssh_encrypt($key, $iv, $seq, $aad4, $payload);
    is(length($wire), 4 + length($payload) + 16, 'aes256-gcm wire length is 4 + payload + 16');
    is(substr($wire, 0, 4), $aad4, 'aes256-gcm preserves plaintext 4-byte length AAD');

    my $enc_body = substr($wire, 4, length($payload));
    my $tag16    = substr($wire, 4 + length($payload), 16);

    my $dec = aes256_gcm_openssh_decrypt($key, $iv, $seq, $aad4, $enc_body, $tag16);
    is($dec, $payload, 'aes256-gcm decrypt recovers exact payload');

    # Wrong sequence counter fails GCM tag
    ok(!defined(aes256_gcm_openssh_decrypt($key, $iv, $seq + 1, $aad4, $enc_body, $tag16)), 'aes256-gcm rejects wrong seq');

    # Tampered AAD fails GCM tag
    my $bad_aad = $aad4;
    substr($bad_aad, 3, 1) ^= "\x01";
    ok(!defined(aes256_gcm_openssh_decrypt($key, $iv, $seq, $bad_aad, $enc_body, $tag16)), 'aes256-gcm rejects tampered AAD');

    # Tampered tag fails GCM tag
    my $bad_tag = $tag16;
    substr($bad_tag, 0, 1) ^= "\x80";
    ok(!defined(aes256_gcm_openssh_decrypt($key, $iv, $seq, $aad4, $enc_body, $bad_tag)), 'aes256-gcm rejects tampered tag');

    ok(MT::XS::is_threadsafe(\&Shop::SSH::Crypto::aes256_gcm_openssh_encrypt), 'aes256_gcm_openssh_encrypt is Tier-1 threadsafe');
    ok(MT::XS::is_threadsafe(\&Shop::SSH::Crypto::mlkem768_encapsulate), 'mlkem768_encapsulate is Tier-1 threadsafe');
    ok(MT::XS::is_threadsafe(\&Shop::SSH::Crypto::ecdsa_p256_verify), 'ecdsa_p256_verify is Tier-1 threadsafe');
}

# 9. Multi-worker MT::Worker concurrency test (Tier-1 in-process dispatch!)
sub worker_crypto_bench {
    my ($wid) = @_;
    require Shop::SSH::Crypto;
    return "NOT_SAFE" unless MT::XS::is_threadsafe(\&Shop::SSH::Crypto::chacha20_poly1305_openssh_encrypt);
    return "IS_REMOTE" if MT::XS::is_remote(\&Shop::SSH::Crypto::chacha20_poly1305_openssh_encrypt);

    my $z_tx = Shop::SSH::Crypto::Zlib->new(5);
    my $z_rx = Shop::SSH::Crypto::Zlib->new(5);
    my ($sk, $pk) = Shop::SSH::Crypto::ed25519_keypair();
    my $k1 = Shop::SSH::Crypto::random_bytes(32);
    my $k2 = Shop::SSH::Crypto::random_bytes(32);

    for my $i (1 .. 50) {
        my $m = "worker-$wid-iter-$i-" . ("ANSI_DATA" x 20);
        my $sig = Shop::SSH::Crypto::ed25519_sign($m, $sk);
        return "SIG_FAIL" unless Shop::SSH::Crypto::ed25519_verify($m, $sig, $pk);

        my $comp = $z_tx->deflate($m);
        my $pkt  = Shop::SSH::Crypto::chacha20_poly1305_openssh_encrypt($k1, $k2, $i, $comp);
        my $e4   = substr($pkt, 0, 4);
        my $len  = Shop::SSH::Crypto::chacha20_poly1305_openssh_decrypt_len($k2, $i, $e4);
        return "LEN_FAIL" unless $len == length($comp);
        my $dec  = Shop::SSH::Crypto::chacha20_poly1305_openssh_decrypt_body(
            $k1, $i, $e4, substr($pkt, 4, $len), substr($pkt, 4 + $len, 16)
        );
        return "DEC_FAIL" unless defined $dec && $dec eq $comp;
        my $orig = $z_rx->inflate($dec);
        return "ZLIB_FAIL" unless $orig eq $m;
    }
    return "OK:$wid";
}

MT::Image::freeze();
my @wids = map { MT::Worker::spawn('main::worker_crypto_bench', $_) } 1 .. 8;
my @results = map { MT::Worker::join($_) } @wids;
is_deeply(\@results, [map { "OK:$_" } 1 .. 8], '8 concurrent MT::Worker threads execute Tier-1 XS crypto+zlib in-process');

done_testing();
