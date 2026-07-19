// tari_c29.cpp - implementation of the Tari Cuckaroo29 PoW wrapper.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SipHash-2-4, the 64-edge sipblock construction, and the 42-cycle verifier
// are ported from the vendored tromp/cuckoo reference under third_party/cuckoo.
// Only the three Tari-specific layers (key derivation, proof packing,
// difficulty) are new. See tari_c29.h for the spec.

#include "tari_c29.h"
#include "blake2b.h"

#include <string.h>

// ----- exact copies of the reference Cuckaroo29 math (EDGEBITS=29) -----------
namespace {

typedef uint32_t u32;
typedef uint64_t u64;
typedef uint32_t word_t;                 // EDGEBITS 29 -> 32-bit word

static const u32 EDGEBITS        = TARI_C29_EDGEBITS;            // 29
static const u32 PROOFSIZE       = TARI_C29_PROOFSIZE;           // 42
static const u32 EDGE_BLOCK_SIZE = TARI_C29_EDGE_BLOCK;          // 64
static const u32 EDGE_BLOCK_MASK = EDGE_BLOCK_SIZE - 1;          // 63
static const word_t NEDGES       = (word_t)1 << EDGEBITS;
static const word_t EDGEMASK     = NEDGES - 1;                   // 2^29 - 1

// siphash_state<rotE=21> -- copied from siphash.hpp
struct siphash_state {
    u64 v0, v1, v2, v3;
    siphash_state(const tari_siphash_keys &k) { v0 = k.k0; v1 = k.k1; v2 = k.k2; v3 = k.k3; }
    static u64 rotl(u64 x, u64 b) { return (x << b) | (x >> (64 - b)); }
    u64 xor_lanes() const { return (v0 ^ v1) ^ (v2 ^ v3); }
    void sip_round() {
        v0 += v1; v2 += v3; v1 = rotl(v1, 13);
        v3 = rotl(v3, 16); v1 ^= v0; v3 ^= v2;
        v0 = rotl(v0, 32); v2 += v1; v0 += v3;
        v1 = rotl(v1, 17); v3 = rotl(v3, 21);   // rotE = 21 (original cuckaroo)
        v1 ^= v2; v3 ^= v0; v2 = rotl(v2, 32);
    }
    void hash24(const u64 nonce) {
        v3 ^= nonce;
        sip_round(); sip_round();
        v0 ^= nonce;
        v2 ^= 0xff;
        sip_round(); sip_round(); sip_round(); sip_round();
    }
};

// sipblock -- copied from cuckaroo.hpp. NOTE the rolling state: the same
// siphash_state is reused across the 64 hashes of a block (NOT reset per edge).
u64 sipblock(const tari_siphash_keys &keys, const word_t edge, u64 *buf) {
    siphash_state shs(keys);
    word_t edge0 = edge & ~EDGE_BLOCK_MASK;
    for (u32 i = 0; i < EDGE_BLOCK_SIZE; i++) {
        shs.hash24(edge0 + i);
        buf[i] = shs.xor_lanes();
    }
    const u64 last = buf[EDGE_BLOCK_MASK];
    for (u32 i = 0; i < EDGE_BLOCK_MASK; i++)
        buf[i] ^= last;
    return buf[edge & EDGE_BLOCK_MASK];
}

// verify -- copied from cuckaroo.hpp, returns reference POW_* code.
enum { POW_OK, POW_HEADER_LENGTH, POW_TOO_BIG, POW_TOO_SMALL,
       POW_NON_MATCHING, POW_BRANCH, POW_DEAD_END, POW_SHORT_CYCLE };

int ref_verify(const word_t edges[TARI_C29_PROOFSIZE], const tari_siphash_keys &keys) {
    word_t xor0 = 0, xor1 = 0;
    u64 sips[EDGE_BLOCK_SIZE];
    word_t uvs[2 * TARI_C29_PROOFSIZE];

    for (u32 n = 0; n < PROOFSIZE; n++) {
        if (edges[n] > EDGEMASK)        return POW_TOO_BIG;
        if (n && edges[n] <= edges[n - 1]) return POW_TOO_SMALL;
        u64 edge = sipblock(keys, edges[n], sips);
        xor0 ^= uvs[2 * n]     = edge & EDGEMASK;
        xor1 ^= uvs[2 * n + 1] = (edge >> 32) & EDGEMASK;
    }
    if (xor0 | xor1) return POW_NON_MATCHING;
    u32 n = 0, i = 0, j;
    do {
        for (u32 k = j = i; (k = (k + 2) % (2 * PROOFSIZE)) != i; ) {
            if (uvs[k] == uvs[i]) {
                if (j != i) return POW_BRANCH;
                j = k;
            }
        }
        if (j == i) return POW_DEAD_END;
        i = j ^ 1;
        n++;
    } while (i != 0);
    return n == PROOFSIZE ? POW_OK : POW_SHORT_CYCLE;
}

int map_verify_code(int ref) {
    switch (ref) {
        case POW_OK:           return TARI_C29_OK;
        case POW_TOO_BIG:      return TARI_C29_ERR_TOO_BIG;
        case POW_TOO_SMALL:    return TARI_C29_ERR_NOT_ASC;
        case POW_NON_MATCHING: return TARI_C29_ERR_ENDPOINTS;
        case POW_BRANCH:       return TARI_C29_ERR_BRANCH;
        case POW_DEAD_END:     return TARI_C29_ERR_DEAD_END;
        case POW_SHORT_CYCLE:  return TARI_C29_ERR_SHORT;
        default:               return TARI_C29_ERR_ENDPOINTS;
    }
}

// ----- minimal 256-bit math for difficulty = U256::MAX / scalar -------------
struct u256 { u64 w[4]; };   // w[0] = least significant limb

inline int u256_ge(const u256 &a, const u256 &b) {
    for (int i = 3; i >= 0; --i) { if (a.w[i] != b.w[i]) return a.w[i] > b.w[i]; }
    return 1;  // equal
}
inline void u256_shl1(u256 &a) {
    u64 carry = 0;
    for (int i = 0; i < 4; ++i) { u64 nc = a.w[i] >> 63; a.w[i] = (a.w[i] << 1) | carry; carry = nc; }
}
inline void u256_sub(u256 &a, const u256 &b) {  // a -= b (assumes a >= b)
    u64 borrow = 0;
    for (int i = 0; i < 4; ++i) {
        u64 ai = a.w[i], bi = b.w[i];
        u64 tmp = ai - bi;
        u64 borrow1 = (ai < bi) ? 1ULL : 0ULL;
        u64 res = tmp - borrow;
        u64 borrow2 = (tmp < borrow) ? 1ULL : 0ULL;
        a.w[i] = res;
        borrow = borrow1 | borrow2;
    }
}
inline void u256_setbit(u256 &a, int bit) { a.w[bit >> 6] |= (1ULL << (bit & 63)); }
inline int  u256_getbit(const u256 &a, int bit) { return (int)((a.w[bit >> 6] >> (bit & 63)) & 1); }

} // namespace

// ---------------------------------------------------------------------------
// (1) key derivation
// ---------------------------------------------------------------------------
extern "C" void tari_c29_derive_keys(uint64_t header_nonce,
                                     const uint8_t mining_hash[32],
                                     tari_siphash_keys *out_keys) {
    uint8_t preimage[40];
    // nonce.to_be_bytes() -- 8 bytes, big-endian
    for (int i = 0; i < 8; ++i)
        preimage[i] = (uint8_t)(header_nonce >> (56 - 8 * i));
    memcpy(preimage + 8, mining_hash, 32);

    uint8_t blob[32];
    blake2b(blob, 32, preimage, sizeof(preimage), NULL, 0);

    // four little-endian u64 lanes
    auto le64 = [](const uint8_t *p) -> uint64_t {
        uint64_t r = 0;
        for (int i = 0; i < 8; ++i) r |= (uint64_t)p[i] << (8 * i);
        return r;
    };
    out_keys->k0 = le64(blob + 0);
    out_keys->k1 = le64(blob + 8);
    out_keys->k2 = le64(blob + 16);
    out_keys->k3 = le64(blob + 24);
}

extern "C" void tari_c29_edge(const tari_siphash_keys *keys, uint32_t edge_index,
                              uint32_t *u, uint32_t *v) {
    uint64_t buf[TARI_C29_EDGE_BLOCK];
    uint64_t edge = sipblock(*keys, (word_t)edge_index, buf);
    *u = (uint32_t)(edge & EDGEMASK);
    *v = (uint32_t)((edge >> 32) & EDGEMASK);
}

// ---------------------------------------------------------------------------
// (2) proof packing -- LSB-first, 29 bits per nonce
// ---------------------------------------------------------------------------
extern "C" void tari_c29_pack(const uint32_t edge_nonces[TARI_C29_PROOFSIZE],
                              uint8_t packed[TARI_C29_PACKED_BYTES]) {
    memset(packed, 0, TARI_C29_PACKED_BYTES);
    size_t bit = 0;
    for (int n = 0; n < TARI_C29_PROOFSIZE; ++n) {
        uint32_t val = edge_nonces[n];
        for (int b = 0; b < TARI_C29_EDGEBITS; ++b) {
            if ((val >> b) & 1u) packed[bit >> 3] |= (uint8_t)(1u << (bit & 7));
            ++bit;
        }
    }
}

extern "C" void tari_c29_unpack(const uint8_t packed[TARI_C29_PACKED_BYTES],
                                uint32_t edge_nonces[TARI_C29_PROOFSIZE]) {
    size_t bit = 0;
    for (int n = 0; n < TARI_C29_PROOFSIZE; ++n) {
        uint32_t val = 0;
        for (int b = 0; b < TARI_C29_EDGEBITS; ++b) {
            if ((packed[bit >> 3] >> (bit & 7)) & 1u) val |= (1u << b);
            ++bit;
        }
        edge_nonces[n] = val;
    }
}

// ---------------------------------------------------------------------------
// (3) difficulty
// ---------------------------------------------------------------------------
extern "C" uint64_t tari_c29_difficulty_from_hash(const uint8_t hash[32]) {
    // scalar = U256::from_big_endian(hash): hash[0] is the most significant byte
    auto be64 = [](const uint8_t *p) -> uint64_t {
        uint64_t r = 0;
        for (int i = 0; i < 8; ++i) r = (r << 8) | p[i];
        return r;
    };
    u256 scalar;
    scalar.w[3] = be64(hash + 0);
    scalar.w[2] = be64(hash + 8);
    scalar.w[1] = be64(hash + 16);
    scalar.w[0] = be64(hash + 24);

    if (scalar.w[0] == 0 && scalar.w[1] == 0 && scalar.w[2] == 0 && scalar.w[3] == 0)
        return ~0ULL;   // hash == 0: treat as max difficulty (Rust would div-by-zero)

    // quotient = (2^256 - 1) / scalar via binary long division.
    u256 dividend; dividend.w[0] = dividend.w[1] = dividend.w[2] = dividend.w[3] = ~0ULL;
    u256 quotient = {0,0,0,0};
    u256 rem      = {0,0,0,0};
    for (int i = 255; i >= 0; --i) {
        u256_shl1(rem);
        if (u256_getbit(dividend, i)) rem.w[0] |= 1ULL;
        if (u256_ge(rem, scalar)) { u256_sub(rem, scalar); u256_setbit(quotient, i); }
    }
    // cap to u64::MAX (Tari: result.min(u64::MAX))
    if (quotient.w[1] | quotient.w[2] | quotient.w[3]) return ~0ULL;
    return quotient.w[0];
}

extern "C" uint64_t tari_c29_difficulty(const uint8_t packed[TARI_C29_PACKED_BYTES]) {
    uint8_t hash[32];
    blake2b(hash, 32, packed, TARI_C29_PACKED_BYTES, NULL, 0);
    return tari_c29_difficulty_from_hash(hash);
}

// ---------------------------------------------------------------------------
// verification helpers
// ---------------------------------------------------------------------------
extern "C" int tari_c29_verify(uint64_t header_nonce,
                               const uint8_t mining_hash[32],
                               const uint32_t edge_nonces[TARI_C29_PROOFSIZE]) {
    tari_siphash_keys keys;
    tari_c29_derive_keys(header_nonce, mining_hash, &keys);
    word_t edges[TARI_C29_PROOFSIZE];
    for (int i = 0; i < TARI_C29_PROOFSIZE; ++i) edges[i] = (word_t)edge_nonces[i];
    return map_verify_code(ref_verify(edges, keys));
}

extern "C" uint64_t tari_c29_check(uint64_t header_nonce,
                                   const uint8_t mining_hash[32],
                                   const uint32_t edge_nonces[TARI_C29_PROOFSIZE]) {
    if (tari_c29_verify(header_nonce, mining_hash, edge_nonces) != TARI_C29_OK)
        return 0;
    uint8_t packed[TARI_C29_PACKED_BYTES];
    tari_c29_pack(edge_nonces, packed);
    return tari_c29_difficulty(packed);
}
