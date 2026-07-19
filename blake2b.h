// blake2b.h - BLAKE2b (RFC 7693) reference implementation, header-only.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Used by the Tari C29 wrapper for two things:
//   1. SipHash key derivation:  keys = BLAKE2b-256( nonce_be8 || mining_hash )
//   2. C29 difficulty:          h    = BLAKE2b-256( packed_proof_153 )
//
// Tari uses `blake2::Blake2b::<U32>` = plain, unkeyed BLAKE2b with a 32-byte
// digest length baked into the parameter block (NOT a truncated BLAKE2b-512).
// This implementation matches that: pass outlen=32, key=NULL, keylen=0.
//
// All functions are `static` so the header can be included in multiple
// translation units without ODR clashes.
//
// Self-test vectors (see tari_c29_selftest.cpp):
//   BLAKE2b-256("")    = 0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8
//   BLAKE2b-256("abc") = bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319
#pragma once

#include <stdint.h>
#include <stddef.h>
#include <string.h>

typedef struct {
    uint8_t  b[128];   // input buffer
    uint64_t h[8];     // chained state
    uint64_t t[2];     // total number of bytes hashed
    size_t   c;        // pointer into b[]
    size_t   outlen;   // digest size
} blake2b_ctx;

static const uint64_t blake2b_iv[8] = {
    0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
    0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
    0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
    0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL
};

static const uint8_t blake2b_sigma[12][16] = {
    { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 },
    {14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 },
    {11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4 },
    { 7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8 },
    { 9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13 },
    { 2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9 },
    {12, 5, 1,15,14,13, 4,10, 0, 7, 6, 3, 9, 2, 8,11 },
    {13,11, 7,14,12, 1, 3, 9, 5, 0,15, 4, 8, 6, 2,10 },
    { 6,15,14, 9,11, 3, 0, 8,12, 2,13, 7, 1, 4,10, 5 },
    {10, 2, 8, 4, 7, 6, 1, 5,15,11, 9,14, 3,12,13, 0 },
    { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 },
    {14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 }
};

static inline uint64_t blake2b_rotr64(uint64_t x, unsigned n) {
    return (x >> n) | (x << (64 - n));
}

static inline uint64_t blake2b_load64(const uint8_t *p) {
    return ((uint64_t)p[0])        | ((uint64_t)p[1] << 8)  |
           ((uint64_t)p[2] << 16)  | ((uint64_t)p[3] << 24) |
           ((uint64_t)p[4] << 32)  | ((uint64_t)p[5] << 40) |
           ((uint64_t)p[6] << 48)  | ((uint64_t)p[7] << 56);
}

static void blake2b_compress(blake2b_ctx *ctx, int last) {
    uint64_t v[16], m[16];
    int i;
    for (i = 0; i < 8; i++) { v[i] = ctx->h[i]; v[i + 8] = blake2b_iv[i]; }
    v[12] ^= ctx->t[0];
    v[13] ^= ctx->t[1];
    if (last) v[14] = ~v[14];
    for (i = 0; i < 16; i++) m[i] = blake2b_load64(ctx->b + 8 * i);

#define B2B_G(a, b, c, d, x, y)                       \
    v[a] = v[a] + v[b] + x;                           \
    v[d] = blake2b_rotr64(v[d] ^ v[a], 32);           \
    v[c] = v[c] + v[d];                               \
    v[b] = blake2b_rotr64(v[b] ^ v[c], 24);           \
    v[a] = v[a] + v[b] + y;                           \
    v[d] = blake2b_rotr64(v[d] ^ v[a], 16);           \
    v[c] = v[c] + v[d];                               \
    v[b] = blake2b_rotr64(v[b] ^ v[c], 63);

    for (i = 0; i < 12; i++) {
        const uint8_t *s = blake2b_sigma[i];
        B2B_G(0, 4,  8, 12, m[s[0]],  m[s[1]]);
        B2B_G(1, 5,  9, 13, m[s[2]],  m[s[3]]);
        B2B_G(2, 6, 10, 14, m[s[4]],  m[s[5]]);
        B2B_G(3, 7, 11, 15, m[s[6]],  m[s[7]]);
        B2B_G(0, 5, 10, 15, m[s[8]],  m[s[9]]);
        B2B_G(1, 6, 11, 12, m[s[10]], m[s[11]]);
        B2B_G(2, 7,  8, 13, m[s[12]], m[s[13]]);
        B2B_G(3, 4,  9, 14, m[s[14]], m[s[15]]);
    }
#undef B2B_G

    for (i = 0; i < 8; i++) ctx->h[i] ^= v[i] ^ v[i + 8];
}

// keylen==0 for the Tari use cases; keyed mode supported for completeness.
static int blake2b_init(blake2b_ctx *ctx, size_t outlen,
                        const void *key, size_t keylen) {
    size_t i;
    if (outlen == 0 || outlen > 64 || keylen > 64) return -1;
    for (i = 0; i < 8; i++) ctx->h[i] = blake2b_iv[i];
    ctx->h[0] ^= 0x01010000ULL ^ ((uint64_t)keylen << 8) ^ (uint64_t)outlen;
    ctx->t[0] = 0; ctx->t[1] = 0; ctx->c = 0; ctx->outlen = outlen;
    for (i = 0; i < 128; i++) ctx->b[i] = 0;
    if (keylen > 0) {
        // first data block is the key, zero-padded to 128 bytes
        memcpy(ctx->b, key, keylen);
        ctx->c = 128;
    }
    return 0;
}

static void blake2b_update(blake2b_ctx *ctx, const void *in, size_t inlen) {
    const uint8_t *p = (const uint8_t *)in;
    size_t i;
    for (i = 0; i < inlen; i++) {
        if (ctx->c == 128) {                 // buffer full -> compress
            ctx->t[0] += 128;
            if (ctx->t[0] < 128) ctx->t[1]++;
            blake2b_compress(ctx, 0);
            ctx->c = 0;
        }
        ctx->b[ctx->c++] = p[i];
    }
}

static void blake2b_final(blake2b_ctx *ctx, void *out) {
    size_t i;
    ctx->t[0] += ctx->c;                     // mark last block length
    if (ctx->t[0] < ctx->c) ctx->t[1]++;
    while (ctx->c < 128) ctx->b[ctx->c++] = 0;  // zero-pad
    blake2b_compress(ctx, 1);                // final block flag
    for (i = 0; i < ctx->outlen; i++)        // little-endian output
        ((uint8_t *)out)[i] = (ctx->h[i >> 3] >> (8 * (i & 7))) & 0xFF;
}

// One-shot convenience. Returns 0 on success.
static int blake2b(void *out, size_t outlen,
                   const void *in, size_t inlen,
                   const void *key, size_t keylen) {
    blake2b_ctx ctx;
    if (blake2b_init(&ctx, outlen, key, keylen) < 0) return -1;
    blake2b_update(&ctx, in, inlen);
    blake2b_final(&ctx, out);
    return 0;
}
