package Shop::SSH::Crypto;

use strict;
use warnings;

our $VERSION = '0.01';

require XSLoader;
XSLoader::load('Shop::SSH::Crypto', $VERSION);

use Exporter 'import';
our @EXPORT_OK = qw(
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

1;
