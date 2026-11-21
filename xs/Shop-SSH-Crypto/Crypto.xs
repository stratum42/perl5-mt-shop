#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stdint.h>
#include <string.h>
#include <sodium.h>
#include <zlib.h>

#include <openssl/bn.h>
#include <openssl/ecdsa.h>
#include <openssl/evp.h>
#include <openssl/param_build.h>
#include <openssl/core_names.h>

static void
encode_be64(unsigned char out[8], uint64_t val)
{
    out[0] = (unsigned char)((val >> 56) & 0xff);
    out[1] = (unsigned char)((val >> 48) & 0xff);
    out[2] = (unsigned char)((val >> 40) & 0xff);
    out[3] = (unsigned char)((val >> 32) & 0xff);
    out[4] = (unsigned char)((val >> 24) & 0xff);
    out[5] = (unsigned char)((val >> 16) & 0xff);
    out[6] = (unsigned char)((val >>  8) & 0xff);
    out[7] = (unsigned char)(val & 0xff);
}

static uint64_t
decode_be64(const unsigned char in[8])
{
    return ((uint64_t)in[0] << 56)
         | ((uint64_t)in[1] << 48)
         | ((uint64_t)in[2] << 40)
         | ((uint64_t)in[3] << 32)
         | ((uint64_t)in[4] << 24)
         | ((uint64_t)in[5] << 16)
         | ((uint64_t)in[6] <<  8)
         | ((uint64_t)in[7]);
}

static void
encode_be32(unsigned char out[4], uint32_t val)
{
    out[0] = (unsigned char)((val >> 24) & 0xff);
    out[1] = (unsigned char)((val >> 16) & 0xff);
    out[2] = (unsigned char)((val >>  8) & 0xff);
    out[3] = (unsigned char)(val & 0xff);
}

static uint32_t
decode_be32(const unsigned char in[4])
{
    return ((uint32_t)in[0] << 24)
         | ((uint32_t)in[1] << 16)
         | ((uint32_t)in[2] <<  8)
         | ((uint32_t)in[3]);
}

typedef struct {
    z_stream def;
    z_stream inf;
    int      def_init;
    int      inf_init;
    int      level;
} shop_zlib_ctx_t;

#define SHOP_ZLIB_MAX_INFLATE (16 * 1024 * 1024)

static shop_zlib_ctx_t *
sv_to_zlib_ctx(pTHX_ SV *self)
{
    if (!sv_isobject(self) || !sv_derived_from(self, "Shop::SSH::Crypto::Zlib"))
        croak("Expected Shop::SSH::Crypto::Zlib object");
    IV ptr = SvIV((SV *)SvRV(self));
    if (!ptr)
        croak("Shop::SSH::Crypto::Zlib object already destroyed");
    return INT2PTR(shop_zlib_ctx_t *, ptr);
}

MODULE = Shop::SSH::Crypto    PACKAGE = Shop::SSH::Crypto

PROTOTYPES: DISABLE

BOOT:
{
    if (sodium_init() < 0) {
        croak("Shop::SSH::Crypto: sodium_init() failed");
    }
}

SV *
random_bytes(n)
    IV n
  CODE:
    if (n < 0 || n > (16 * 1024 * 1024))
        croak("random_bytes: invalid length %ld", (long)n);
    RETVAL = newSV((STRLEN)(n > 0 ? n : 1));
    SvPOK_on(RETVAL);
    if (n > 0) {
        randombytes_buf(SvPVX(RETVAL), (size_t)n);
    }
    SvCUR_set(RETVAL, (STRLEN)n);
    SvPVX(RETVAL)[n] = '\0';
  OUTPUT:
    RETVAL

void
x25519_keypair()
  PPCODE:
    unsigned char sk[crypto_scalarmult_curve25519_SCALARBYTES];
    unsigned char pk[crypto_scalarmult_curve25519_BYTES];
    randombytes_buf(sk, sizeof(sk));
    if (crypto_scalarmult_curve25519_base(pk, sk) != 0) {
        sodium_memzero(sk, sizeof(sk));
        croak("x25519_keypair: scalarmult_base failed");
    }
    EXTEND(SP, 2);
    PUSHs(sv_2mortal(newSVpvn((const char *)sk, sizeof(sk))));
    PUSHs(sv_2mortal(newSVpvn((const char *)pk, sizeof(pk))));
    sodium_memzero(sk, sizeof(sk));

SV *
x25519_shared(priv_sv, pub_sv)
    SV *priv_sv
    SV *pub_sv
  CODE:
    STRLEN priv_len, pub_len;
    const unsigned char *priv = (const unsigned char *)SvPVbyte(priv_sv, priv_len);
    const unsigned char *pub  = (const unsigned char *)SvPVbyte(pub_sv, pub_len);
    if (priv_len != crypto_scalarmult_curve25519_SCALARBYTES ||
        pub_len  != crypto_scalarmult_curve25519_BYTES) {
        croak("x25519_shared: expected 32-byte priv and 32-byte pub");
    }
    unsigned char shared[crypto_scalarmult_curve25519_BYTES];
    if (crypto_scalarmult_curve25519(shared, priv, pub) != 0) {
        sodium_memzero(shared, sizeof(shared));
        XSRETURN_UNDEF;
    }
    RETVAL = newSVpvn((const char *)shared, sizeof(shared));
    sodium_memzero(shared, sizeof(shared));
  OUTPUT:
    RETVAL

void
ed25519_keypair()
  PPCODE:
    unsigned char pk[crypto_sign_ed25519_PUBLICKEYBYTES];
    unsigned char sk[crypto_sign_ed25519_SECRETKEYBYTES];
    crypto_sign_ed25519_keypair(pk, sk);
    EXTEND(SP, 2);
    PUSHs(sv_2mortal(newSVpvn((const char *)sk, sizeof(sk))));
    PUSHs(sv_2mortal(newSVpvn((const char *)pk, sizeof(pk))));
    sodium_memzero(sk, sizeof(sk));

void
ed25519_seed_keypair(seed_sv)
    SV *seed_sv
  PPCODE:
    STRLEN seed_len;
    const unsigned char *seed = (const unsigned char *)SvPVbyte(seed_sv, seed_len);
    if (seed_len != crypto_sign_ed25519_SEEDBYTES)
        croak("ed25519_seed_keypair: expected 32-byte seed");
    unsigned char pk[crypto_sign_ed25519_PUBLICKEYBYTES];
    unsigned char sk[crypto_sign_ed25519_SECRETKEYBYTES];
    crypto_sign_ed25519_seed_keypair(pk, sk, seed);
    EXTEND(SP, 2);
    PUSHs(sv_2mortal(newSVpvn((const char *)sk, sizeof(sk))));
    PUSHs(sv_2mortal(newSVpvn((const char *)pk, sizeof(pk))));
    sodium_memzero(sk, sizeof(sk));

SV *
ed25519_sign(msg_sv, sk_sv)
    SV *msg_sv
    SV *sk_sv
  CODE:
    STRLEN msg_len, sk_len;
    const unsigned char *msg = (const unsigned char *)SvPVbyte(msg_sv, msg_len);
    const unsigned char *sk  = (const unsigned char *)SvPVbyte(sk_sv, sk_len);
    if (sk_len != crypto_sign_ed25519_SECRETKEYBYTES)
        croak("ed25519_sign: expected 64-byte secret key");
    unsigned char sig[crypto_sign_ed25519_BYTES];
    unsigned long long siglen = 0;
    crypto_sign_ed25519_detached(sig, &siglen, msg, (unsigned long long)msg_len, sk);
    RETVAL = newSVpvn((const char *)sig, (STRLEN)siglen);
  OUTPUT:
    RETVAL

IV
ed25519_verify(msg_sv, sig_sv, pk_sv)
    SV *msg_sv
    SV *sig_sv
    SV *pk_sv
  CODE:
    STRLEN msg_len, sig_len, pk_len;
    const unsigned char *msg = (const unsigned char *)SvPVbyte(msg_sv, msg_len);
    const unsigned char *sig = (const unsigned char *)SvPVbyte(sig_sv, sig_len);
    const unsigned char *pk  = (const unsigned char *)SvPVbyte(pk_sv, pk_len);
    if (sig_len != crypto_sign_ed25519_BYTES || pk_len != crypto_sign_ed25519_PUBLICKEYBYTES) {
        RETVAL = 0;
    } else {
        RETVAL = (crypto_sign_ed25519_verify_detached(sig, msg, (unsigned long long)msg_len, pk) == 0) ? 1 : 0;
    }
  OUTPUT:
    RETVAL

IV
rsa_sha2_verify(msg_sv, sig_sv, n_sv, e_sv, bits)
    SV *msg_sv
    SV *sig_sv
    SV *n_sv
    SV *e_sv
    IV bits
  CODE:
    STRLEN msg_len, sig_len, n_len, e_len;
    const unsigned char *msg = (const unsigned char *)SvPVbyte(msg_sv, msg_len);
    const unsigned char *sig = (const unsigned char *)SvPVbyte(sig_sv, sig_len);
    const unsigned char *n_b = (const unsigned char *)SvPVbyte(n_sv, n_len);
    const unsigned char *e_b = (const unsigned char *)SvPVbyte(e_sv, e_len);

    const EVP_MD *md = NULL;
    if (bits == 256) {
        md = EVP_sha256();
    } else if (bits == 512) {
        md = EVP_sha512();
    } else {
        croak("rsa_sha2_verify: bits must be 256 or 512");
    }

    RETVAL = 0;
    BIGNUM *bn_n = NULL;
    BIGNUM *bn_e = NULL;
    OSSL_PARAM_BLD *bld = NULL;
    OSSL_PARAM *params = NULL;
    EVP_PKEY_CTX *pctx = NULL;
    EVP_PKEY *pkey = NULL;
    EVP_MD_CTX *mctx = NULL;

    bn_n = BN_bin2bn(n_b, (int)n_len, NULL);
    bn_e = BN_bin2bn(e_b, (int)e_len, NULL);
    if (!bn_n || !bn_e) goto cleanup;

    bld = OSSL_PARAM_BLD_new();
    if (!bld) goto cleanup;
    if (!OSSL_PARAM_BLD_push_BN(bld, OSSL_PKEY_PARAM_RSA_N, bn_n)) goto cleanup;
    if (!OSSL_PARAM_BLD_push_BN(bld, OSSL_PKEY_PARAM_RSA_E, bn_e)) goto cleanup;

    params = OSSL_PARAM_BLD_to_param(bld);
    if (!params) goto cleanup;

    pctx = EVP_PKEY_CTX_new_from_name(NULL, "RSA", NULL);
    if (!pctx) goto cleanup;
    if (EVP_PKEY_fromdata_init(pctx) <= 0) goto cleanup;
    if (EVP_PKEY_fromdata(pctx, &pkey, EVP_PKEY_PUBLIC_KEY, params) <= 0) goto cleanup;

    mctx = EVP_MD_CTX_new();
    if (!mctx) goto cleanup;
    if (EVP_DigestVerifyInit(mctx, NULL, md, NULL, pkey) <= 0) goto cleanup;
    if (EVP_DigestVerify(mctx, sig, (size_t)sig_len, msg, (size_t)msg_len) == 1) {
        RETVAL = 1;
    }

  cleanup:
    if (mctx)   EVP_MD_CTX_free(mctx);
    if (pkey)   EVP_PKEY_free(pkey);
    if (pctx)   EVP_PKEY_CTX_free(pctx);
    if (params) OSSL_PARAM_free(params);
    if (bld)    OSSL_PARAM_BLD_free(bld);
    if (bn_n)   BN_free(bn_n);
    if (bn_e)   BN_free(bn_e);
  OUTPUT:
    RETVAL

SV *
sha256(data_sv)
    SV *data_sv
  CODE:
    STRLEN len;
    const unsigned char *data = (const unsigned char *)SvPVbyte(data_sv, len);
    unsigned char out[crypto_hash_sha256_BYTES];
    crypto_hash_sha256(out, data, (unsigned long long)len);
    RETVAL = newSVpvn((const char *)out, sizeof(out));
  OUTPUT:
    RETVAL

SV *
hmac_sha256(key_sv, data_sv)
    SV *key_sv
    SV *data_sv
  CODE:
    STRLEN key_len, data_len;
    const unsigned char *key  = (const unsigned char *)SvPVbyte(key_sv, key_len);
    const unsigned char *data = (const unsigned char *)SvPVbyte(data_sv, data_len);
    unsigned char out[crypto_auth_hmacsha256_BYTES];
    crypto_auth_hmacsha256_state st;
    crypto_auth_hmacsha256_init(&st, key, (size_t)key_len);
    if (data_len > 0) {
        crypto_auth_hmacsha256_update(&st, data, (unsigned long long)data_len);
    }
    crypto_auth_hmacsha256_final(&st, out);
    sodium_memzero(&st, sizeof(st));
    RETVAL = newSVpvn((const char *)out, sizeof(out));
    sodium_memzero(out, sizeof(out));
  OUTPUT:
    RETVAL

IV
const_time_eq(a_sv, b_sv)
    SV *a_sv
    SV *b_sv
  CODE:
    STRLEN a_len, b_len;
    const unsigned char *a = (const unsigned char *)SvPVbyte(a_sv, a_len);
    const unsigned char *b = (const unsigned char *)SvPVbyte(b_sv, b_len);
    if (a_len != b_len) {
        RETVAL = 0;
    } else if (a_len == 0) {
        RETVAL = 1;
    } else {
        RETVAL = (sodium_memcmp(a, b, (size_t)a_len) == 0) ? 1 : 0;
    }
  OUTPUT:
    RETVAL

void
mlkem768_encapsulate(ek_sv)
    SV *ek_sv
  PPCODE:
    STRLEN ek_len;
    const unsigned char *ek = (const unsigned char *)SvPVbyte(ek_sv, ek_len);
    if (ek_len != 1184) {
        croak("mlkem768_encapsulate: expected 1184-byte encapsulation key, got %lu", (unsigned long)ek_len);
    }

    EVP_PKEY *pkey = EVP_PKEY_new_raw_public_key_ex(NULL, "ML-KEM-768", NULL, ek, (size_t)ek_len);
    if (!pkey) {
        croak("mlkem768_encapsulate: EVP_PKEY_new_raw_public_key_ex(ML-KEM-768) failed");
    }

    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_from_pkey(NULL, pkey, NULL);
    if (!ctx) {
        EVP_PKEY_free(pkey);
        croak("mlkem768_encapsulate: EVP_PKEY_CTX_new_from_pkey failed");
    }

    unsigned char ct[1088];
    unsigned char ss[32];
    size_t ct_len = sizeof(ct);
    size_t ss_len = sizeof(ss);

    if (EVP_PKEY_encapsulate_init(ctx, NULL) <= 0 ||
        EVP_PKEY_encapsulate(ctx, ct, &ct_len, ss, &ss_len) <= 0 ||
        ct_len != 1088 || ss_len != 32) {
        sodium_memzero(ss, sizeof(ss));
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        croak("mlkem768_encapsulate: EVP_PKEY_encapsulate failed");
    }

    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(pkey);

    EXTEND(SP, 2);
    PUSHs(sv_2mortal(newSVpvn((const char *)ct, ct_len)));
    PUSHs(sv_2mortal(newSVpvn((const char *)ss, ss_len)));
    sodium_memzero(ss, sizeof(ss));

IV
ecdsa_p256_verify(msg_sv, r_sv, s_sv, q_sv)
    SV *msg_sv
    SV *r_sv
    SV *s_sv
    SV *q_sv
  CODE:
    STRLEN msg_len, r_len, s_len, q_len;
    const unsigned char *msg = (const unsigned char *)SvPVbyte(msg_sv, msg_len);
    const unsigned char *r_b = (const unsigned char *)SvPVbyte(r_sv, r_len);
    const unsigned char *s_b = (const unsigned char *)SvPVbyte(s_sv, s_len);
    const unsigned char *q_b = (const unsigned char *)SvPVbyte(q_sv, q_len);

    RETVAL = 0;
    if (q_len != 65 || q_b[0] != 0x04 || r_len == 0 || r_len > 33 || s_len == 0 || s_len > 33) {
        XSRETURN_IV(0);
    }

    BIGNUM *bn_r = NULL;
    BIGNUM *bn_s = NULL;
    ECDSA_SIG *esig = NULL;
    unsigned char *der_sig = NULL;
    int der_len = 0;
    OSSL_PARAM_BLD *bld = NULL;
    OSSL_PARAM *params = NULL;
    EVP_PKEY_CTX *pctx = NULL;
    EVP_PKEY *pkey = NULL;
    EVP_MD_CTX *mctx = NULL;

    bn_r = BN_bin2bn(r_b, (int)r_len, NULL);
    bn_s = BN_bin2bn(s_b, (int)s_len, NULL);
    if (!bn_r || !bn_s) goto ecdsa_cleanup;

    esig = ECDSA_SIG_new();
    if (!esig) goto ecdsa_cleanup;
    if (!ECDSA_SIG_set0(esig, bn_r, bn_s)) goto ecdsa_cleanup;
    /* Ownership of bn_r and bn_s transferred to esig */
    bn_r = NULL;
    bn_s = NULL;

    der_len = i2d_ECDSA_SIG(esig, &der_sig);
    if (der_len <= 0 || !der_sig) goto ecdsa_cleanup;

    bld = OSSL_PARAM_BLD_new();
    if (!bld) goto ecdsa_cleanup;
    if (!OSSL_PARAM_BLD_push_utf8_string(bld, OSSL_PKEY_PARAM_GROUP_NAME, "prime256v1", 0)) goto ecdsa_cleanup;
    if (!OSSL_PARAM_BLD_push_octet_string(bld, OSSL_PKEY_PARAM_PUB_KEY, q_b, (size_t)q_len)) goto ecdsa_cleanup;

    params = OSSL_PARAM_BLD_to_param(bld);
    if (!params) goto ecdsa_cleanup;

    pctx = EVP_PKEY_CTX_new_from_name(NULL, "EC", NULL);
    if (!pctx) goto ecdsa_cleanup;
    if (EVP_PKEY_fromdata_init(pctx) <= 0) goto ecdsa_cleanup;
    if (EVP_PKEY_fromdata(pctx, &pkey, EVP_PKEY_PUBLIC_KEY, params) <= 0) goto ecdsa_cleanup;

    mctx = EVP_MD_CTX_new();
    if (!mctx) goto ecdsa_cleanup;
    if (EVP_DigestVerifyInit(mctx, NULL, EVP_sha256(), NULL, pkey) <= 0) goto ecdsa_cleanup;
    if (EVP_DigestVerify(mctx, der_sig, (size_t)der_len, msg, (size_t)msg_len) == 1) {
        RETVAL = 1;
    }

  ecdsa_cleanup:
    if (mctx)    EVP_MD_CTX_free(mctx);
    if (pkey)    EVP_PKEY_free(pkey);
    if (pctx)    EVP_PKEY_CTX_free(pctx);
    if (params)  OSSL_PARAM_free(params);
    if (bld)     OSSL_PARAM_BLD_free(bld);
    if (der_sig) OPENSSL_free(der_sig);
    if (esig)    ECDSA_SIG_free(esig);
    if (bn_r)    BN_free(bn_r);
    if (bn_s)    BN_free(bn_s);
  OUTPUT:
    RETVAL

SV *
aes256_gcm_openssh_encrypt(key_sv, iv_sv, seq, aad_sv, payload_sv)
    SV *key_sv
    SV *iv_sv
    UV seq
    SV *aad_sv
    SV *payload_sv
  CODE:
    STRLEN key_len, iv_len, aad_len, plen;
    const unsigned char *key     = (const unsigned char *)SvPVbyte(key_sv, key_len);
    const unsigned char *iv12    = (const unsigned char *)SvPVbyte(iv_sv, iv_len);
    const unsigned char *aad4    = (const unsigned char *)SvPVbyte(aad_sv, aad_len);
    const unsigned char *payload = (const unsigned char *)SvPVbyte(payload_sv, plen);
    if (key_len != 32 || iv_len != 12 || aad_len != 4) {
        croak("aes256_gcm_openssh_encrypt: expected 32-byte key, 12-byte iv, 4-byte aad");
    }

    unsigned char nonce[12];
    memcpy(nonce, iv12, 4);
    uint64_t ctr = decode_be64(iv12 + 4) + (uint64_t)seq;
    encode_be64(nonce + 4, ctr);

    STRLEN total = 4 + plen + 16;
    RETVAL = newSV(total);
    SvPOK_on(RETVAL);
    unsigned char *out = (unsigned char *)SvPVX(RETVAL);
    memcpy(out, aad4, 4);

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        SvREFCNT_dec(RETVAL);
        croak("aes256_gcm_openssh_encrypt: EVP_CIPHER_CTX_new failed");
    }

    int outlen = 0, finlen = 0, ok = 1;
    if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) != 1 ||
        EVP_EncryptInit_ex(ctx, NULL, NULL, key, nonce) != 1 ||
        EVP_EncryptUpdate(ctx, NULL, &outlen, aad4, 4) != 1) {
        ok = 0;
    }
    if (ok && plen > 0) {
        if (EVP_EncryptUpdate(ctx, out + 4, &outlen, payload, (int)plen) != 1) {
            ok = 0;
        }
    }
    if (ok) {
        if (EVP_EncryptFinal_ex(ctx, out + 4 + outlen, &finlen) != 1 ||
            EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, out + 4 + plen) != 1) {
            ok = 0;
        }
    }
    EVP_CIPHER_CTX_free(ctx);

    if (!ok) {
        SvREFCNT_dec(RETVAL);
        croak("aes256_gcm_openssh_encrypt: OpenSSL GCM encrypt failed");
    }

    SvCUR_set(RETVAL, total);
    out[total] = '\0';
  OUTPUT:
    RETVAL

SV *
aes256_gcm_openssh_decrypt(key_sv, iv_sv, seq, aad_sv, enc_payload_sv, tag16_sv)
    SV *key_sv
    SV *iv_sv
    UV seq
    SV *aad_sv
    SV *enc_payload_sv
    SV *tag16_sv
  CODE:
    STRLEN key_len, iv_len, aad_len, plen, tag_len;
    const unsigned char *key         = (const unsigned char *)SvPVbyte(key_sv, key_len);
    const unsigned char *iv12        = (const unsigned char *)SvPVbyte(iv_sv, iv_len);
    const unsigned char *aad4        = (const unsigned char *)SvPVbyte(aad_sv, aad_len);
    const unsigned char *enc_payload = (const unsigned char *)SvPVbyte(enc_payload_sv, plen);
    const unsigned char *tag16       = (const unsigned char *)SvPVbyte(tag16_sv, tag_len);
    if (key_len != 32 || iv_len != 12 || aad_len != 4 || tag_len != 16) {
        croak("aes256_gcm_openssh_decrypt: expected 32-byte key, 12-byte iv, 4-byte aad, 16-byte tag");
    }

    unsigned char nonce[12];
    memcpy(nonce, iv12, 4);
    uint64_t ctr = decode_be64(iv12 + 4) + (uint64_t)seq;
    encode_be64(nonce + 4, ctr);

    RETVAL = newSV(plen > 0 ? plen : 1);
    SvPOK_on(RETVAL);
    unsigned char *out = (unsigned char *)SvPVX(RETVAL);

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        SvREFCNT_dec(RETVAL);
        croak("aes256_gcm_openssh_decrypt: EVP_CIPHER_CTX_new failed");
    }

    int outlen = 0, finlen = 0, ok = 1;
    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) != 1 ||
        EVP_DecryptInit_ex(ctx, NULL, NULL, key, nonce) != 1 ||
        EVP_DecryptUpdate(ctx, NULL, &outlen, aad4, 4) != 1) {
        ok = 0;
    }
    if (ok && plen > 0) {
        if (EVP_DecryptUpdate(ctx, out, &outlen, enc_payload, (int)plen) != 1) {
            ok = 0;
        }
    }
    if (ok) {
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, (void *)tag16) != 1 ||
            EVP_DecryptFinal_ex(ctx, out + outlen, &finlen) <= 0) {
            ok = 0;
        }
    }
    EVP_CIPHER_CTX_free(ctx);

    if (!ok) {
        if (plen > 0) sodium_memzero(out, plen);
        SvREFCNT_dec(RETVAL);
        XSRETURN_UNDEF;
    }

    SvCUR_set(RETVAL, plen);
    out[plen] = '\0';
  OUTPUT:
    RETVAL

SV *
chacha20_poly1305_openssh_encrypt(k1_sv, k2_sv, seq, payload_sv)
    SV *k1_sv
    SV *k2_sv
    UV seq
    SV *payload_sv
  CODE:
    STRLEN k1_len, k2_len, plen;
    const unsigned char *k1 = (const unsigned char *)SvPVbyte(k1_sv, k1_len);
    const unsigned char *k2 = (const unsigned char *)SvPVbyte(k2_sv, k2_len);
    const unsigned char *payload = (const unsigned char *)SvPVbyte(payload_sv, plen);
    if (k1_len != 32 || k2_len != 32)
        croak("chacha20_poly1305_openssh_encrypt: k1 and k2 must be 32 bytes");

    unsigned char nonce[8];
    encode_be64(nonce, (uint64_t)seq);

    /* Output buffer: 4 (enc_len) + plen (enc_payload) + 16 (poly1305 tag) */
    STRLEN total = 4 + plen + 16;
    RETVAL = newSV(total);
    SvPOK_on(RETVAL);
    unsigned char *out = (unsigned char *)SvPVX(RETVAL);

    /* 1. Encrypt 4-byte big-endian length with k2, counter 0 */
    unsigned char len_be[4];
    encode_be32(len_be, (uint32_t)plen);
    crypto_stream_chacha20_xor_ic(out, len_be, 4, nonce, 0, k2);

    /* 2. Derive 32-byte Poly1305 key with k1, counter 0 */
    unsigned char poly_key[32];
    crypto_stream_chacha20(poly_key, sizeof(poly_key), nonce, k1);

    /* 3. Encrypt payload with k1, counter 1 */
    if (plen > 0) {
        crypto_stream_chacha20_xor_ic(out + 4, payload, (unsigned long long)plen, nonce, 1, k1);
    }

    /* 4. Compute Poly1305 tag over enc_len || enc_payload */
    crypto_onetimeauth_poly1305_state st;
    crypto_onetimeauth_poly1305_init(&st, poly_key);
    crypto_onetimeauth_poly1305_update(&st, out, (unsigned long long)(4 + plen));
    crypto_onetimeauth_poly1305_final(&st, out + 4 + plen);

    sodium_memzero(poly_key, sizeof(poly_key));

    SvCUR_set(RETVAL, total);
    out[total] = '\0';
  OUTPUT:
    RETVAL

UV
chacha20_poly1305_openssh_decrypt_len(k2_sv, seq, enc4_sv)
    SV *k2_sv
    UV seq
    SV *enc4_sv
  CODE:
    STRLEN k2_len, enc_len;
    const unsigned char *k2   = (const unsigned char *)SvPVbyte(k2_sv, k2_len);
    const unsigned char *enc4 = (const unsigned char *)SvPVbyte(enc4_sv, enc_len);
    if (k2_len != 32 || enc_len != 4)
        croak("chacha20_poly1305_openssh_decrypt_len: expected 32-byte k2 and 4-byte enc4");

    unsigned char nonce[8];
    encode_be64(nonce, (uint64_t)seq);

    unsigned char len_be[4];
    crypto_stream_chacha20_xor_ic(len_be, enc4, 4, nonce, 0, k2);
    RETVAL = (UV)decode_be32(len_be);
  OUTPUT:
    RETVAL

SV *
chacha20_poly1305_openssh_decrypt_body(k1_sv, seq, enc4_sv, enc_payload_sv, tag16_sv)
    SV *k1_sv
    UV seq
    SV *enc4_sv
    SV *enc_payload_sv
    SV *tag16_sv
  CODE:
    STRLEN k1_len, enc4_len, plen, tag_len;
    const unsigned char *k1          = (const unsigned char *)SvPVbyte(k1_sv, k1_len);
    const unsigned char *enc4        = (const unsigned char *)SvPVbyte(enc4_sv, enc4_len);
    const unsigned char *enc_payload = (const unsigned char *)SvPVbyte(enc_payload_sv, plen);
    const unsigned char *tag16       = (const unsigned char *)SvPVbyte(tag16_sv, tag_len);

    if (k1_len != 32 || enc4_len != 4 || tag_len != 16)
        croak("chacha20_poly1305_openssh_decrypt_body: invalid argument lengths");

    unsigned char nonce[8];
    encode_be64(nonce, (uint64_t)seq);

    /* 1. Derive Poly1305 key with k1, counter 0 */
    unsigned char poly_key[32];
    crypto_stream_chacha20(poly_key, sizeof(poly_key), nonce, k1);

    /* 2. Verify Poly1305 tag over enc4 || enc_payload */
    unsigned char expected_tag[16];
    crypto_onetimeauth_poly1305_state st;
    crypto_onetimeauth_poly1305_init(&st, poly_key);
    crypto_onetimeauth_poly1305_update(&st, enc4, 4);
    if (plen > 0) {
        crypto_onetimeauth_poly1305_update(&st, enc_payload, (unsigned long long)plen);
    }
    crypto_onetimeauth_poly1305_final(&st, expected_tag);
    sodium_memzero(poly_key, sizeof(poly_key));

    if (sodium_memcmp(expected_tag, tag16, 16) != 0) {
        XSRETURN_UNDEF;
    }

    /* 3. Decrypt payload with k1, counter 1 */
    RETVAL = newSV(plen > 0 ? plen : 1);
    SvPOK_on(RETVAL);
    unsigned char *out = (unsigned char *)SvPVX(RETVAL);
    if (plen > 0) {
        crypto_stream_chacha20_xor_ic(out, enc_payload, (unsigned long long)plen, nonce, 1, k1);
    }
    SvCUR_set(RETVAL, plen);
    out[plen] = '\0';
  OUTPUT:
    RETVAL

MODULE = Shop::SSH::Crypto    PACKAGE = Shop::SSH::Crypto::Zlib

PROTOTYPES: DISABLE

SV *
new(klass, level=5)
    const char *klass
    IV level
  CODE:
    if (level < 0 || level > 9)
        level = 5;
    shop_zlib_ctx_t *ctx;
    Newxz(ctx, 1, shop_zlib_ctx_t);
    ctx->level = (int)level;

    /* Low-memory deflate: windowBits=13 (8 KiB window) + memLevel=5 (~44 KiB vs ~256 KiB default).
     * 100% RFC 1950 & OpenSSH zlib@openssh.com compatible while reducing per-session RSS ~6x. */
    int rc = deflateInit2(&ctx->def, ctx->level, Z_DEFLATED, 13, 5, Z_DEFAULT_STRATEGY);
    if (rc != Z_OK) {
        Safefree(ctx);
        croak("Shop::SSH::Crypto::Zlib: deflateInit2 failed (%d)", rc);
    }
    ctx->def_init = 1;
    /* Lazy inflateInit: allocated on first inflate() call (saves ~40 KiB per idle session) */
    ctx->inf_init = 0;

    RETVAL = newSV(0);
    sv_setref_pv(RETVAL, klass, (void *)ctx);
  OUTPUT:
    RETVAL

SV *
deflate(self, data_sv)
    SV *self
    SV *data_sv
  CODE:
    shop_zlib_ctx_t *ctx = sv_to_zlib_ctx(aTHX_ self);
    STRLEN in_len;
    const unsigned char *in = (const unsigned char *)SvPVbyte(data_sv, in_len);

    ctx->def.next_in  = (Bytef *)in;
    ctx->def.avail_in = (uInt)in_len;

    STRLEN cap = in_len + 64;
    if (cap < 256) cap = 256;
    RETVAL = newSV(cap);
    SvPOK_on(RETVAL);
    STRLEN produced = 0;

    for (;;) {
        if (produced == cap) {
            cap *= 2;
            SvGROW(RETVAL, cap + 1);
        }
        ctx->def.next_out  = (Bytef *)(SvPVX(RETVAL) + produced);
        ctx->def.avail_out = (uInt)(cap - produced);

        int rc = deflate(&ctx->def, Z_SYNC_FLUSH);
        if (rc != Z_OK && rc != Z_BUF_ERROR) {
            SvREFCNT_dec(RETVAL);
            croak("Shop::SSH::Crypto::Zlib::deflate failed (%d)", rc);
        }
        produced = cap - ctx->def.avail_out;
        if (ctx->def.avail_out > 0 && ctx->def.avail_in == 0) {
            break;
        }
    }

    SvCUR_set(RETVAL, produced);
    SvPVX(RETVAL)[produced] = '\0';
  OUTPUT:
    RETVAL

SV *
inflate(self, data_sv, max_out=262144)
    SV *self
    SV *data_sv
    IV max_out
  CODE:
    shop_zlib_ctx_t *ctx = sv_to_zlib_ctx(aTHX_ self);
    STRLEN in_len;
    const unsigned char *in = (const unsigned char *)SvPVbyte(data_sv, in_len);

    if (max_out <= 0) max_out = 262144;
    if (max_out > SHOP_ZLIB_MAX_INFLATE) max_out = SHOP_ZLIB_MAX_INFLATE;
    STRLEN limit = (STRLEN)max_out;
    STRLEN hard_cap = limit + 1;

    if (in_len == 0) {
        RETVAL = newSVpvn("", 0);
    } else {
        if (!ctx->inf_init) {
            int irc = inflateInit(&ctx->inf);
            if (irc != Z_OK) {
                croak("Shop::SSH::Crypto::Zlib: lazy inflateInit failed (%d)", irc);
            }
            ctx->inf_init = 1;
        }
        ctx->inf.next_in  = (Bytef *)in;
        ctx->inf.avail_in = (uInt)in_len;

        STRLEN cap = in_len * 4;
        if (cap < 512) cap = 512;
        if (cap > hard_cap) cap = hard_cap;
        RETVAL = newSV(cap);
        SvPOK_on(RETVAL);
        STRLEN produced = 0;

        for (;;) {
            if (produced == cap) {
                if (produced > limit) {
                    SvREFCNT_dec(RETVAL);
                    croak("SSH_ZIP_BOMB: Zlib::inflate exceeded max_out (%lu bytes)", (unsigned long)limit);
                }
                cap *= 2;
                if (cap > hard_cap) cap = hard_cap;
                SvGROW(RETVAL, cap + 1);
            }
            ctx->inf.next_out  = (Bytef *)(SvPVX(RETVAL) + produced);
            ctx->inf.avail_out = (uInt)(cap - produced);

            int rc = inflate(&ctx->inf, Z_SYNC_FLUSH);
            if (rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR) {
                SvREFCNT_dec(RETVAL);
                croak("Shop::SSH::Crypto::Zlib::inflate failed (%d)", rc);
            }
            produced = cap - ctx->inf.avail_out;
            if (produced > limit) {
                SvREFCNT_dec(RETVAL);
                croak("SSH_ZIP_BOMB: Zlib::inflate exceeded max_out (%lu bytes)", (unsigned long)limit);
            }
            if (ctx->inf.avail_in == 0 && ctx->inf.avail_out > 0) {
                break;
            }
            if (rc == Z_BUF_ERROR && ctx->inf.avail_in == 0) {
                break;
            }
        }

        SvCUR_set(RETVAL, produced);
        SvPVX(RETVAL)[produced] = '\0';
    }
  OUTPUT:
    RETVAL

void
DESTROY(self)
    SV *self
  CODE:
    if (sv_isobject(self) && sv_derived_from(self, "Shop::SSH::Crypto::Zlib")) {
        IV ptr = SvIV((SV *)SvRV(self));
        if (ptr) {
            shop_zlib_ctx_t *ctx = INT2PTR(shop_zlib_ctx_t *, ptr);
            if (ctx->def_init) deflateEnd(&ctx->def);
            if (ctx->inf_init) inflateEnd(&ctx->inf);
            Safefree(ctx);
            sv_setiv((SV *)SvRV(self), 0);
        }
    }
