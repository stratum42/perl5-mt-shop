/*
 * Coverage-guided AFL++ persistent-mode fuzzing harness for Shop::SSH::Crypto.
 *
 * Mirrors the C logic of xs/Shop-SSH-Crypto/Crypto.xs across all 8 attack
 * surfaces (selected via buf[0] % 8):
 *   0: mlkem768_encapsulate
 *   1: x25519_shared
 *   2: ed25519_verify
 *   3: rsa_sha2_verify
 *   4: ecdsa_p256_verify
 *   5: chacha20_poly1305_openssh_decrypt (+ roundtrip)
 *   6: aes256_gcm_openssh_decrypt (+ roundtrip)
 *   7: Zlib::inflate (256 KiB zip-bomb cap + trailing/stalled guards)
 *
 * Build with afl-clang-fast for persistent-mode fuzzing, or with
 * -fsanitize=address,undefined to replay a discovered corpus on argv.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sodium.h>
#include <zlib.h>

#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/ecdsa.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/param_build.h>

#define SHOP_ZLIB_DEFAULT_LIMIT (262144)
#define SHOP_ZLIB_MAX_INFLATE   (16 * 1024 * 1024)
#define SHOP_MAX_CRYPTO_BUF     (16 * 1024 * 1024)
#define SHOP_MAX_RSA_MOD_BYTES  1024
#define SHOP_MAX_RSA_EXP_BYTES  64

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

/* 0: mlkem768_encapsulate */
static void
fuzz_mlkem768_encapsulate(const unsigned char *ek, size_t ek_len)
{
    if (ek_len != 1184) {
        return;
    }

    EVP_PKEY *pkey = EVP_PKEY_new_raw_public_key_ex(NULL, "ML-KEM-768", NULL, ek, ek_len);
    if (!pkey) {
        ERR_clear_error();
        return;
    }

    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_from_pkey(NULL, pkey, NULL);
    if (!ctx) {
        EVP_PKEY_free(pkey);
        ERR_clear_error();
        return;
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
        ERR_clear_error();
        return;
    }

    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    sodium_memzero(ss, sizeof(ss));
}

/* 1: x25519_shared */
static void
fuzz_x25519_shared(const unsigned char *data, size_t len)
{
    if (len < crypto_scalarmult_curve25519_SCALARBYTES + crypto_scalarmult_curve25519_BYTES) {
        return;
    }
    const unsigned char *priv = data;
    const unsigned char *pub  = data + crypto_scalarmult_curve25519_SCALARBYTES;
    unsigned char shared[crypto_scalarmult_curve25519_BYTES];
    if (crypto_scalarmult_curve25519(shared, priv, pub) != 0) {
        sodium_memzero(shared, sizeof(shared));
        return;
    }
    sodium_memzero(shared, sizeof(shared));
}

/* 2: ed25519_verify */
static void
fuzz_ed25519_verify(const unsigned char *data, size_t len)
{
    if (len < crypto_sign_ed25519_PUBLICKEYBYTES + crypto_sign_ed25519_BYTES) {
        return;
    }
    const unsigned char *pk  = data;
    const unsigned char *sig = data + crypto_sign_ed25519_PUBLICKEYBYTES;
    const unsigned char *msg = sig + crypto_sign_ed25519_BYTES;
    size_t msg_len = len - (crypto_sign_ed25519_PUBLICKEYBYTES + crypto_sign_ed25519_BYTES);

    volatile int rc = (crypto_sign_ed25519_verify_detached(sig, msg, (unsigned long long)msg_len, pk) == 0) ? 1 : 0;
    (void)rc;
}

/* 3: rsa_sha2_verify */
static void
fuzz_rsa_sha2_verify(const unsigned char *data, size_t len)
{
    if (len < 6) {
        return;
    }
    const EVP_MD *md = (data[0] & 1) ? EVP_sha512() : EVP_sha256();
    size_t n_len   = ((size_t)data[1] << 8) | (size_t)data[2];
    size_t e_len   = (size_t)data[3];
    size_t sig_len = ((size_t)data[4] << 8) | (size_t)data[5];

    if (n_len == 0 || n_len > SHOP_MAX_RSA_MOD_BYTES ||
        e_len == 0 || e_len > SHOP_MAX_RSA_EXP_BYTES ||
        sig_len == 0 || sig_len > SHOP_MAX_RSA_MOD_BYTES) {
        return;
    }

    size_t rem = len - 6;
    if (n_len + e_len + sig_len > rem) {
        return;
    }

    const unsigned char *n_b = data + 6;
    const unsigned char *e_b = n_b + n_len;
    const unsigned char *sig = e_b + e_len;
    const unsigned char *msg = sig + sig_len;
    size_t msg_len = rem - n_len - e_len - sig_len;

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
    (void)EVP_DigestVerify(mctx, sig, sig_len, msg, msg_len);

cleanup:
    if (mctx)   EVP_MD_CTX_free(mctx);
    if (pkey)   EVP_PKEY_free(pkey);
    if (pctx)   EVP_PKEY_CTX_free(pctx);
    if (params) OSSL_PARAM_free(params);
    if (bld)    OSSL_PARAM_BLD_free(bld);
    if (bn_n)   BN_free(bn_n);
    if (bn_e)   BN_free(bn_e);
    ERR_clear_error();
}

/* 4: ecdsa_p256_verify */
static void
fuzz_ecdsa_p256_verify(const unsigned char *data, size_t len)
{
    if (len < 3) {
        return;
    }
    size_t q_len = (size_t)data[0];
    size_t r_len = (size_t)data[1];
    size_t s_len = (size_t)data[2];

    if (q_len + r_len + s_len > len - 3) {
        return;
    }

    const unsigned char *q_b = data + 3;
    const unsigned char *r_b = q_b + q_len;
    const unsigned char *s_b = r_b + r_len;
    const unsigned char *msg = s_b + s_len;
    size_t msg_len = (len - 3) - q_len - r_len - s_len;

    if (q_len != 65 || q_b[0] != 0x04 || r_len == 0 || r_len > 33 || s_len == 0 || s_len > 33) {
        return;
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
    bn_r = NULL;
    bn_s = NULL;

    der_len = i2d_ECDSA_SIG(esig, &der_sig);
    if (der_len <= 0 || !der_sig) goto ecdsa_cleanup;

    bld = OSSL_PARAM_BLD_new();
    if (!bld) goto ecdsa_cleanup;
    if (!OSSL_PARAM_BLD_push_utf8_string(bld, OSSL_PKEY_PARAM_GROUP_NAME, "prime256v1", 0)) goto ecdsa_cleanup;
    if (!OSSL_PARAM_BLD_push_octet_string(bld, OSSL_PKEY_PARAM_PUB_KEY, q_b, q_len)) goto ecdsa_cleanup;

    params = OSSL_PARAM_BLD_to_param(bld);
    if (!params) goto ecdsa_cleanup;

    pctx = EVP_PKEY_CTX_new_from_name(NULL, "EC", NULL);
    if (!pctx) goto ecdsa_cleanup;
    if (EVP_PKEY_fromdata_init(pctx) <= 0) goto ecdsa_cleanup;
    if (EVP_PKEY_fromdata(pctx, &pkey, EVP_PKEY_PUBLIC_KEY, params) <= 0) goto ecdsa_cleanup;

    mctx = EVP_MD_CTX_new();
    if (!mctx) goto ecdsa_cleanup;
    if (EVP_DigestVerifyInit(mctx, NULL, EVP_sha256(), NULL, pkey) <= 0) goto ecdsa_cleanup;
    (void)EVP_DigestVerify(mctx, der_sig, (size_t)der_len, msg, msg_len);

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
    ERR_clear_error();
}

static int
chacha20_decrypt_body(const unsigned char k1[32], uint64_t seq,
                      const unsigned char enc4[4],
                      const unsigned char *enc_payload, size_t plen,
                      const unsigned char tag16[16],
                      unsigned char *out)
{
    unsigned char nonce[8];
    encode_be64(nonce, seq);

    unsigned char poly_key[32];
    crypto_stream_chacha20(poly_key, sizeof(poly_key), nonce, k1);

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
        return 0;
    }

    if (plen > 0) {
        crypto_stream_chacha20_xor_ic(out, enc_payload, (unsigned long long)plen, nonce, 1, k1);
    }
    return 1;
}

/* 5: chacha20_poly1305_openssh_decrypt (+ roundtrip) */
static void
fuzz_chacha20_poly1305(const unsigned char *data, size_t len)
{
    if (len < 1) {
        return;
    }
    unsigned char mode = data[0] & 1;
    data++;
    len--;

    if (mode == 0) {
        /* Raw adversarial decrypt_len + decrypt_body */
        if (len < 32 + 32 + 8 + 4 + 16) {
            return;
        }
        const unsigned char *k1    = data;
        const unsigned char *k2    = data + 32;
        uint64_t seq               = decode_be64(data + 64);
        const unsigned char *enc4  = data + 72;
        const unsigned char *tag16 = data + 76;
        const unsigned char *enc_p = data + 92;
        size_t plen                = len - 92;
        if (plen > SHOP_MAX_CRYPTO_BUF) {
            return;
        }

        unsigned char nonce[8];
        encode_be64(nonce, seq);
        unsigned char len_be[4];
        crypto_stream_chacha20_xor_ic(len_be, enc4, 4, nonce, 0, k2);
        volatile uint32_t dec_len = decode_be32(len_be);
        (void)dec_len;

        unsigned char *out = (unsigned char *)malloc(plen > 0 ? plen : 1);
        if (!out) return;
        (void)chacha20_decrypt_body(k1, seq, enc4, enc_p, plen, tag16, out);
        free(out);
    } else {
        /* Encrypt -> decrypt_len -> decrypt_body roundtrip */
        if (len < 32 + 32 + 8) {
            return;
        }
        const unsigned char *k1      = data;
        const unsigned char *k2      = data + 32;
        uint64_t seq                 = decode_be64(data + 64);
        const unsigned char *payload = data + 72;
        size_t plen                  = len - 72;
        if (plen > SHOP_MAX_CRYPTO_BUF) {
            return;
        }

        unsigned char nonce[8];
        encode_be64(nonce, seq);

        size_t total = 4 + plen + 16;
        unsigned char *wire = (unsigned char *)malloc(total);
        unsigned char *dec  = (unsigned char *)malloc(plen > 0 ? plen : 1);
        if (!wire || !dec) {
            free(wire);
            free(dec);
            return;
        }

        unsigned char len_be[4];
        encode_be32(len_be, (uint32_t)plen);
        crypto_stream_chacha20_xor_ic(wire, len_be, 4, nonce, 0, k2);

        unsigned char poly_key[32];
        crypto_stream_chacha20(poly_key, sizeof(poly_key), nonce, k1);
        if (plen > 0) {
            crypto_stream_chacha20_xor_ic(wire + 4, payload, (unsigned long long)plen, nonce, 1, k1);
        }
        crypto_onetimeauth_poly1305_state st;
        crypto_onetimeauth_poly1305_init(&st, poly_key);
        crypto_onetimeauth_poly1305_update(&st, wire, (unsigned long long)(4 + plen));
        crypto_onetimeauth_poly1305_final(&st, wire + 4 + plen);
        sodium_memzero(poly_key, sizeof(poly_key));

        unsigned char dec_len_be[4];
        crypto_stream_chacha20_xor_ic(dec_len_be, wire, 4, nonce, 0, k2);
        if (decode_be32(dec_len_be) != (uint32_t)plen) {
            abort();
        }

        int ok = chacha20_decrypt_body(k1, seq, wire, wire + 4, plen, wire + 4 + plen, dec);
        if (!ok || (plen > 0 && memcmp(dec, payload, plen) != 0)) {
            abort();
        }

        free(wire);
        free(dec);
    }
}

static int
aes256_gcm_decrypt_one(const unsigned char key[32], const unsigned char iv12[12],
                       uint64_t seq, const unsigned char aad4[4],
                       const unsigned char *enc_payload, size_t plen,
                       const unsigned char tag16[16], unsigned char *out)
{
    unsigned char nonce[12];
    memcpy(nonce, iv12, 4);
    uint64_t ctr = decode_be64(iv12 + 4) + seq;
    encode_be64(nonce + 4, ctr);

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return 0;

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
        ERR_clear_error();
        if (plen > 0) sodium_memzero(out, plen);
        return 0;
    }
    return 1;
}

/* 6: aes256_gcm_openssh_decrypt (+ roundtrip) */
static void
fuzz_aes256_gcm(const unsigned char *data, size_t len)
{
    if (len < 1) {
        return;
    }
    unsigned char mode = data[0] & 1;
    data++;
    len--;

    if (mode == 0) {
        /* Raw adversarial decrypt */
        if (len < 32 + 12 + 8 + 4 + 16) {
            return;
        }
        const unsigned char *key   = data;
        const unsigned char *iv12  = data + 32;
        uint64_t seq               = decode_be64(data + 44);
        const unsigned char *aad4  = data + 52;
        const unsigned char *tag16 = data + 56;
        const unsigned char *enc_p = data + 72;
        size_t plen                = len - 72;
        if (plen > SHOP_MAX_CRYPTO_BUF) {
            return;
        }

        unsigned char *out = (unsigned char *)malloc(plen > 0 ? plen : 1);
        if (!out) return;
        (void)aes256_gcm_decrypt_one(key, iv12, seq, aad4, enc_p, plen, tag16, out);
        free(out);
    } else {
        /* Encrypt -> decrypt roundtrip */
        if (len < 32 + 12 + 8 + 4) {
            return;
        }
        const unsigned char *key     = data;
        const unsigned char *iv12    = data + 32;
        uint64_t seq                 = decode_be64(data + 44);
        const unsigned char *aad4    = data + 52;
        const unsigned char *payload = data + 56;
        size_t plen                  = len - 56;
        if (plen > SHOP_MAX_CRYPTO_BUF) {
            return;
        }

        unsigned char nonce[12];
        memcpy(nonce, iv12, 4);
        uint64_t ctr = decode_be64(iv12 + 4) + seq;
        encode_be64(nonce + 4, ctr);

        size_t total = 4 + plen + 16;
        unsigned char *wire = (unsigned char *)malloc(total);
        unsigned char *dec  = (unsigned char *)malloc(plen > 0 ? plen : 1);
        if (!wire || !dec) {
            free(wire);
            free(dec);
            return;
        }
        memcpy(wire, aad4, 4);

        EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
        if (!ctx) {
            free(wire);
            free(dec);
            return;
        }
        int outlen = 0, finlen = 0, ok = 1;
        if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1 ||
            EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) != 1 ||
            EVP_EncryptInit_ex(ctx, NULL, NULL, key, nonce) != 1 ||
            EVP_EncryptUpdate(ctx, NULL, &outlen, aad4, 4) != 1) {
            ok = 0;
        }
        if (ok && plen > 0) {
            if (EVP_EncryptUpdate(ctx, wire + 4, &outlen, payload, (int)plen) != 1) {
                ok = 0;
            }
        }
        if (ok) {
            if (EVP_EncryptFinal_ex(ctx, wire + 4 + outlen, &finlen) != 1 ||
                EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, wire + 4 + plen) != 1) {
                ok = 0;
            }
        }
        EVP_CIPHER_CTX_free(ctx);

        if (!ok) {
            ERR_clear_error();
            free(wire);
            free(dec);
            abort();
        }

        int dec_ok = aes256_gcm_decrypt_one(key, iv12, seq, wire, wire + 4, plen, wire + 4 + plen, dec);
        if (!dec_ok || (plen > 0 && memcmp(dec, payload, plen) != 0)) {
            free(wire);
            free(dec);
            abort();
        }

        free(wire);
        free(dec);
    }
}

/* 7: Zlib::inflate (exact mirror of Crypto.xs inflate with 256 KiB cap) */
static void
fuzz_zlib_inflate(const unsigned char *in, size_t in_len)
{
    if (in_len == 0 || in_len > SHOP_ZLIB_MAX_INFLATE) {
        return;
    }

    size_t limit    = SHOP_ZLIB_DEFAULT_LIMIT;
    size_t hard_cap = limit + 1;

    z_stream inf;
    memset(&inf, 0, sizeof(inf));
    if (inflateInit(&inf) != Z_OK) {
        return;
    }

    inf.next_in  = (Bytef *)in;
    inf.avail_in = (uInt)in_len;

    size_t cap = in_len * 4;
    if (cap < 512) cap = 512;
    if (cap > hard_cap) cap = hard_cap;

    unsigned char *out = (unsigned char *)malloc(cap + 1);
    if (!out) {
        inflateEnd(&inf);
        return;
    }
    size_t produced = 0;

    for (;;) {
        if (produced == cap) {
            if (produced > limit) {
                /* SSH_ZIP_BOMB cap triggered */
                break;
            }
            cap *= 2;
            if (cap > hard_cap) cap = hard_cap;
            unsigned char *grown = (unsigned char *)realloc(out, cap + 1);
            if (!grown) {
                break;
            }
            out = grown;
        }
        inf.next_out  = (Bytef *)(out + produced);
        inf.avail_out = (uInt)(cap - produced);

        int rc = inflate(&inf, Z_SYNC_FLUSH);
        if (rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR) {
            break;
        }
        produced = cap - inf.avail_out;
        if (produced > limit) {
            /* SSH_ZIP_BOMB cap triggered */
            break;
        }
        if (rc == Z_STREAM_END) {
            /* Mirrors trailing-data check (inf.avail_in > 0) and clean end */
            break;
        }
        if (inf.avail_in == 0 && inf.avail_out > 0) {
            break;
        }
        if (rc == Z_BUF_ERROR && inf.avail_out > 0) {
            /* Mirrors stalled-stream check (inf.avail_in > 0) and clean end */
            break;
        }
    }

    out[produced] = '\0';
    free(out);
    inflateEnd(&inf);
}

static void
fuzz_one(const unsigned char *buf, size_t len)
{
    if (len < 2) {
        return;
    }
    unsigned char selector = buf[0] % 8;
    const unsigned char *payload = buf + 1;
    size_t payload_len = len - 1;

    switch (selector) {
        case 0: fuzz_mlkem768_encapsulate(payload, payload_len); break;
        case 1: fuzz_x25519_shared(payload, payload_len);        break;
        case 2: fuzz_ed25519_verify(payload, payload_len);       break;
        case 3: fuzz_rsa_sha2_verify(payload, payload_len);      break;
        case 4: fuzz_ecdsa_p256_verify(payload, payload_len);    break;
        case 5: fuzz_chacha20_poly1305(payload, payload_len);    break;
        case 6: fuzz_aes256_gcm(payload, payload_len);           break;
        case 7: fuzz_zlib_inflate(payload, payload_len);         break;
    }
}

static int
replay_file(const char *path)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        perror(path);
        return 1;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return 1;
    }
    long sz = ftell(fp);
    if (sz < 0 || sz > (long)(SHOP_MAX_CRYPTO_BUF + 1024)) {
        fclose(fp);
        return 1;
    }
    if (fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        return 1;
    }
    unsigned char *buf = (unsigned char *)malloc((size_t)(sz > 0 ? sz : 1));
    if (!buf) {
        fclose(fp);
        return 1;
    }
    size_t n = (sz > 0) ? fread(buf, 1, (size_t)sz, fp) : 0;
    fclose(fp);

    fuzz_one(buf, n);
    free(buf);
    return 0;
}

#ifdef __AFL_FUZZ_TESTCASE_LEN
__AFL_FUZZ_INIT();
#endif

int
main(int argc, char **argv)
{
    if (sodium_init() < 0) {
        fprintf(stderr, "sodium_init() failed\n");
        return 1;
    }

    if (argc > 1) {
        int errors = 0;
        for (int i = 1; i < argc; i++) {
            errors += replay_file(argv[i]);
        }
        return errors ? 1 : 0;
    }

#ifdef __AFL_FUZZ_TESTCASE_LEN
    __AFL_INIT();
    unsigned char *buf = __AFL_FUZZ_TESTCASE_BUF;
    while (__AFL_LOOP(10000)) {
        size_t len = (size_t)__AFL_FUZZ_TESTCASE_LEN;
        fuzz_one(buf, len);
    }
#else
    /* Fallback stdin mode for non-AFL builds */
    size_t cap = 65536;
    size_t len = 0;
    unsigned char *buf = (unsigned char *)malloc(cap);
    if (!buf) return 1;
    for (;;) {
        if (len == cap) {
            if (cap >= SHOP_MAX_CRYPTO_BUF) break;
            cap *= 2;
            unsigned char *grown = (unsigned char *)realloc(buf, cap);
            if (!grown) {
                free(buf);
                return 1;
            }
            buf = grown;
        }
        ssize_t r = read(STDIN_FILENO, buf + len, cap - len);
        if (r <= 0) break;
        len += (size_t)r;
    }
    fuzz_one(buf, len);
    free(buf);
#endif
    return 0;
}
