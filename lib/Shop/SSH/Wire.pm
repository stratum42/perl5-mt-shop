package Shop::SSH::Wire;

use strict;
use warnings;
use MIME::Base64 qw(encode_base64 decode_base64);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Shop::SSH::Crypto qw(sha256 random_bytes ed25519_keypair);

use Exporter 'import';

# RFC 4253 / 4252 / 4254 SSHv2 message types
use constant {
    SSH_MSG_DISCONNECT                => 1,
    SSH_MSG_IGNORE                    => 2,
    SSH_MSG_UNIMPLEMENTED             => 3,
    SSH_MSG_DEBUG                     => 4,
    SSH_MSG_SERVICE_REQUEST           => 5,
    SSH_MSG_SERVICE_ACCEPT            => 6,
    SSH_MSG_EXT_INFO                  => 7,
    SSH_MSG_KEXINIT                   => 20,
    SSH_MSG_NEWKEYS                   => 21,
    SSH_MSG_KEX_ECDH_INIT             => 30,
    SSH_MSG_KEX_ECDH_REPLY            => 31,
    SSH_MSG_KEX_HYBRID_INIT           => 30,
    SSH_MSG_KEX_HYBRID_REPLY          => 31,
    SSH_MSG_USERAUTH_REQUEST          => 50,
    SSH_MSG_USERAUTH_FAILURE          => 51,
    SSH_MSG_USERAUTH_SUCCESS          => 52,
    SSH_MSG_USERAUTH_BANNER           => 53,
    SSH_MSG_USERAUTH_PK_OK            => 60,
    SSH_MSG_GLOBAL_REQUEST            => 80,
    SSH_MSG_REQUEST_SUCCESS           => 81,
    SSH_MSG_REQUEST_FAILURE           => 82,
    SSH_MSG_CHANNEL_OPEN              => 90,
    SSH_MSG_CHANNEL_OPEN_CONFIRMATION => 91,
    SSH_MSG_CHANNEL_OPEN_FAILURE      => 92,
    SSH_MSG_CHANNEL_WINDOW_ADJUST     => 93,
    SSH_MSG_CHANNEL_DATA              => 94,
    SSH_MSG_CHANNEL_EXTENDED_DATA     => 95,
    SSH_MSG_CHANNEL_EOF               => 96,
    SSH_MSG_CHANNEL_CLOSE             => 97,
    SSH_MSG_CHANNEL_REQUEST           => 98,
    SSH_MSG_CHANNEL_SUCCESS           => 99,
    SSH_MSG_CHANNEL_FAILURE           => 100,

    # Disconnect reason codes
    SSH_DISCONNECT_HOST_NOT_ALLOWED_TO_CONNECT => 1,
    SSH_DISCONNECT_PROTOCOL_ERROR              => 2,
    SSH_DISCONNECT_KEY_EXCHANGE_FAILED         => 3,
    SSH_DISCONNECT_MAC_ERROR                   => 5,
    SSH_DISCONNECT_COMPRESSION_ERROR           => 6,
    SSH_DISCONNECT_SERVICE_NOT_AVAILABLE       => 7,
    SSH_DISCONNECT_PROTOCOL_VERSION_NOT_SUPPORTED => 8,
    SSH_DISCONNECT_BY_APPLICATION              => 11,
    SSH_DISCONNECT_NO_MORE_AUTH_METHODS_AVAILABLE => 14,
};

my @MSG_CONSTANTS = qw(
    SSH_MSG_DISCONNECT
    SSH_MSG_IGNORE
    SSH_MSG_UNIMPLEMENTED
    SSH_MSG_DEBUG
    SSH_MSG_SERVICE_REQUEST
    SSH_MSG_SERVICE_ACCEPT
    SSH_MSG_EXT_INFO
    SSH_MSG_KEXINIT
    SSH_MSG_NEWKEYS
    SSH_MSG_KEX_ECDH_INIT
    SSH_MSG_KEX_ECDH_REPLY
    SSH_MSG_KEX_HYBRID_INIT
    SSH_MSG_KEX_HYBRID_REPLY
    SSH_MSG_USERAUTH_REQUEST
    SSH_MSG_USERAUTH_FAILURE
    SSH_MSG_USERAUTH_SUCCESS
    SSH_MSG_USERAUTH_BANNER
    SSH_MSG_USERAUTH_PK_OK
    SSH_MSG_GLOBAL_REQUEST
    SSH_MSG_REQUEST_SUCCESS
    SSH_MSG_REQUEST_FAILURE
    SSH_MSG_CHANNEL_OPEN
    SSH_MSG_CHANNEL_OPEN_CONFIRMATION
    SSH_MSG_CHANNEL_OPEN_FAILURE
    SSH_MSG_CHANNEL_WINDOW_ADJUST
    SSH_MSG_CHANNEL_DATA
    SSH_MSG_CHANNEL_EXTENDED_DATA
    SSH_MSG_CHANNEL_EOF
    SSH_MSG_CHANNEL_CLOSE
    SSH_MSG_CHANNEL_REQUEST
    SSH_MSG_CHANNEL_SUCCESS
    SSH_MSG_CHANNEL_FAILURE
    SSH_DISCONNECT_HOST_NOT_ALLOWED_TO_CONNECT
    SSH_DISCONNECT_PROTOCOL_ERROR
    SSH_DISCONNECT_KEY_EXCHANGE_FAILED
    SSH_DISCONNECT_MAC_ERROR
    SSH_DISCONNECT_COMPRESSION_ERROR
    SSH_DISCONNECT_SERVICE_NOT_AVAILABLE
    SSH_DISCONNECT_PROTOCOL_VERSION_NOT_SUPPORTED
    SSH_DISCONNECT_BY_APPLICATION
    SSH_DISCONNECT_NO_MORE_AUTH_METHODS_AVAILABLE
);

my @WIRE_FUNCS = qw(
    pack_byte
    pack_bool
    pack_u32
    pack_string
    pack_namelist
    pack_mpint
    unpack_byte
    unpack_bool
    unpack_u32
    unpack_string
    unpack_namelist
    unpack_mpint
    pubkey_fingerprint
    ed25519_pubkey_blob
    parse_ed25519_pubkey_blob
    parse_rsa_pubkey_blob
    parse_ecdsa_p256_pubkey_blob
    load_openssh_ed25519_key
    save_openssh_ed25519_key
    load_or_generate_hostkey
);

our @EXPORT_OK = (@MSG_CONSTANTS, @WIRE_FUNCS);
our %EXPORT_TAGS = (
    msg  => \@MSG_CONSTANTS,
    wire => \@WIRE_FUNCS,
    all  => \@EXPORT_OK,
);

sub pack_byte {
    my $v = defined $_[0] ? $_[0] : 0;
    return pack('C', $v & 0xff);
}

sub pack_bool {
    return $_[0] ? "\x01" : "\x00";
}

sub pack_u32 {
    my $v = defined $_[0] ? $_[0] : 0;
    return pack('N', $v);
}

sub pack_string {
    my $s = defined $_[0] ? $_[0] : '';
    return pack('N/a*', $s);
}

sub pack_namelist {
    return pack_string(join(',', @_));
}

sub pack_mpint {
    my ($bytes) = @_;
    return pack('N', 0) if !defined($bytes) || length($bytes) == 0;
    # Strip leading zero bytes
    $bytes =~ s/\A\x00+//;
    return pack('N', 0) if length($bytes) == 0;
    # Prepend 0x00 if MSB is set (so value stays positive in two's complement)
    if (ord(substr($bytes, 0, 1)) & 0x80) {
        $bytes = "\x00" . $bytes;
    }
    return pack('N/a*', $bytes);
}

sub unpack_byte {
    my ($buf, $off_ref) = @_;
    die "SSH::Wire: truncated byte"
        if !defined($buf) || !defined($off_ref) || !defined($$off_ref)
        || $$off_ref < 0 || $$off_ref + 1 > length($buf);
    my $v = ord(substr($buf, $$off_ref, 1));
    $$off_ref += 1;
    return $v;
}

sub unpack_bool {
    return unpack_byte(@_) ? 1 : 0;
}

sub unpack_u32 {
    my ($buf, $off_ref) = @_;
    die "SSH::Wire: truncated u32"
        if !defined($buf) || !defined($off_ref) || !defined($$off_ref)
        || $$off_ref < 0 || $$off_ref + 4 > length($buf);
    my $v = unpack('N', substr($buf, $$off_ref, 4));
    $$off_ref += 4;
    return $v;
}

sub unpack_string {
    my ($buf, $off_ref) = @_;
    my $len = unpack_u32($buf, $off_ref);
    die "SSH::Wire: truncated string (need $len)"
        if $len > length($buf) - $$off_ref;
    my $s = substr($buf, $$off_ref, $len);
    $$off_ref += $len;
    return $s;
}

sub unpack_namelist {
    my ($buf, $off_ref) = @_;
    my $s = unpack_string($buf, $off_ref);
    return [] if $s eq '';
    return [ split /,/, $s ];
}

sub unpack_mpint {
    my ($buf, $off_ref) = @_;
    my $s = unpack_string($buf, $off_ref);
    $s =~ s/\A\x00+//;
    return $s;
}

sub pubkey_fingerprint {
    my ($blob) = @_;
    die "SSH::Wire: pubkey_fingerprint requires defined blob" unless defined $blob;
    my $b64 = encode_base64(sha256($blob), '');
    $b64 =~ s/=+\z//;
    return "SHA256:$b64";
}

sub ed25519_pubkey_blob {
    my ($pk32) = @_;
    die "ed25519_pubkey_blob: expected 32-byte public key" unless defined($pk32) && length($pk32) == 32;
    return pack_string('ssh-ed25519') . pack_string($pk32);
}

sub parse_ed25519_pubkey_blob {
    my ($blob) = @_;
    return undef unless defined $blob;
    my $off = 0;
    my $type = eval { unpack_string($blob, \$off) };
    return undef if $@ || !defined($type) || $type ne 'ssh-ed25519';
    my $pk = eval { unpack_string($blob, \$off) };
    return undef if $@ || !defined($pk) || length($pk) != 32;
    return $pk;
}

sub parse_rsa_pubkey_blob {
    my ($blob) = @_;
    return () unless defined $blob;
    my $off = 0;
    my $type = eval { unpack_string($blob, \$off) };
    return () if $@ || !defined($type) || $type ne 'ssh-rsa';
    my $e = eval { unpack_mpint($blob, \$off) };
    return () if $@ || !defined($e) || length($e) == 0 || length($e) > 64;
    my $n = eval { unpack_mpint($blob, \$off) };
    return () if $@ || !defined($n) || length($n) == 0 || length($n) > 1024;
    return ($e, $n);
}

sub parse_ecdsa_p256_pubkey_blob {
    my ($blob) = @_;
    return undef unless defined $blob;
    my $off = 0;
    my $type = eval { unpack_string($blob, \$off) };
    return undef if $@ || !defined($type) || $type ne 'ecdsa-sha2-nistp256';
    my $curve = eval { unpack_string($blob, \$off) };
    return undef if $@ || !defined($curve) || $curve ne 'nistp256';
    my $q = eval { unpack_string($blob, \$off) };
    return undef if $@ || !defined($q) || length($q) != 65 || ord(substr($q, 0, 1)) != 0x04;
    return $q;
}

sub load_openssh_ed25519_key {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot open hostkey $path: $!";
    local $/;
    my $pem = <$fh>;
    close $fh;

    $pem =~ m{-----BEGIN OPENSSH PRIVATE KEY-----\s*(.*?)\s*-----END OPENSSH PRIVATE KEY-----}s
        or die "Invalid OpenSSH private key PEM in $path";
    my $b64 = $1;
    $b64 =~ s/\s+//g;
    my $raw = decode_base64($b64);

    my $magic = "openssh-key-v1\0";
    die "Bad openssh-key-v1 magic in $path" unless substr($raw, 0, length($magic)) eq $magic;

    my $off = length($magic);
    my $cipher = unpack_string($raw, \$off);
    my $kdf    = unpack_string($raw, \$off);
    my $kdfopt = unpack_string($raw, \$off);
    die "Encrypted OpenSSH hostkeys are not supported ($cipher/$kdf)"
        unless $cipher eq 'none' && $kdf eq 'none';

    my $nkeys = unpack_u32($raw, \$off);
    die "Expected 1 key in $path, found $nkeys" unless $nkeys >= 1;

    my $pub_blob = unpack_string($raw, \$off);
    my $priv_sec = unpack_string($raw, \$off);

    my $poff = 0;
    my $chk1 = unpack_u32($priv_sec, \$poff);
    my $chk2 = unpack_u32($priv_sec, \$poff);
    die "OpenSSH private key checkint mismatch in $path" unless $chk1 == $chk2;

    my $ktype = unpack_string($priv_sec, \$poff);
    die "Unsupported hostkey type '$ktype' (expected ssh-ed25519)" unless $ktype eq 'ssh-ed25519';

    my $pk32 = unpack_string($priv_sec, \$poff);
    my $sk64 = unpack_string($priv_sec, \$poff);
    die "Invalid ed25519 key sizes in $path" unless length($pk32) == 32 && length($sk64) == 64;

    my $blob = ed25519_pubkey_blob($pk32);
    return {
        type        => 'ssh-ed25519',
        sk          => $sk64,
        pk          => $pk32,
        pubkey_blob => $blob,
        fingerprint => pubkey_fingerprint($blob),
    };
}

sub save_openssh_ed25519_key {
    my ($path, $sk64, $pk32, $comment) = @_;
    $comment //= 'perl5-mt-shop';

    my $pub_blob = ed25519_pubkey_blob($pk32);
    my $checkint = unpack('N', random_bytes(4));

    my $priv = pack_u32($checkint)
             . pack_u32($checkint)
             . pack_string('ssh-ed25519')
             . pack_string($pk32)
             . pack_string($sk64)
             . pack_string($comment);

    my $pad_len = (8 - (length($priv) % 8)) % 8;
    for my $i (1 .. $pad_len) {
        $priv .= pack('C', $i);
    }

    my $raw = "openssh-key-v1\0"
            . pack_string('none')
            . pack_string('none')
            . pack_string('')
            . pack_u32(1)
            . pack_string($pub_blob)
            . pack_string($priv);

    my $b64 = encode_base64($raw, '');
    $b64 =~ s/(.{1,70})/$1\n/g;
    my $pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n${b64}-----END OPENSSH PRIVATE KEY-----\n";

    my $dir = dirname($path);
    make_path($dir) if defined($dir) && $dir ne '' && !-d $dir;

    open my $fh, '>:raw', $path or die "Cannot write hostkey $path: $!";
    print $fh $pem;
    close $fh;
    chmod 0600, $path;
    return 1;
}

sub load_or_generate_hostkey {
    my ($path) = @_;
    if (defined($path) && -f $path) {
        return load_openssh_ed25519_key($path);
    }
    my ($sk64, $pk32) = ed25519_keypair();
    save_openssh_ed25519_key($path, $sk64, $pk32) if defined($path) && $path ne '';
    my $blob = ed25519_pubkey_blob($pk32);
    return {
        type        => 'ssh-ed25519',
        sk          => $sk64,
        pk          => $pk32,
        pubkey_blob => $blob,
        fingerprint => pubkey_fingerprint($blob),
    };
}

1;
