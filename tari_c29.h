// tari_c29.h - Tari (XTM) Cuckaroo29 proof-of-work wrapper.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This is the *Tari-specific* layer that turns a generic, Grin-original
// Cuckaroo29 mean solver (tromp/cuckoo, vendored under third_party/cuckoo) into
// a Tari C29 miner. The trimming/cycle-finding
// solver itself is unmodified Cuckaroo29 -- only three things are Tari-specific:
//
//   (1) SipHash key derivation preimage:
//          keys = BLAKE2b-256( nonce.to_be_bytes()[8] || mining_hash[32] )
//          split into four little-endian u64 lanes (k0..k3).
//       (Grin instead hashes its serialized pre-PoW header. The graph
//        construction *after* key derivation is byte-identical.)
//
//   (2) Proof packing / envelope:
//          42 edge nonces, strictly ascending, each < 2^29, bit-packed
//          LSB-first at 29 bits each => 153 bytes. This is the pow_data that
//          rides behind PoW algorithm byte 3 (PowAlgorithm::Cuckaroo).
//
//   (3) Difficulty of a found cycle:
//          achieved = floor( U256::MAX / BLAKE2b-256(packed_proof)_be ),
//          capped to u64::MAX. A cycle is a valid block iff achieved >= target.
//
// The edge construction and 42-cycle verifier are ported from the canonical
// tromp/cuckoo reference, so they remain bit-exact with the solver.
//
// ASSUMPTION: little-endian host (Windows x64 / Linux x64). Stated explicitly
// because SipHash key lanes and BLAKE2b message words are little-endian.
//
// Verified against the Tari Rust consensus source semantics
// (base_layer/core/src/proof_of_work/cuckaroo_pow.rs, siphash.rs, difficulty.rs)
// and by accepted LuckyPool shares during development.
#pragma once

#include <stdint.h>
#include <stddef.h>

#define TARI_C29_EDGEBITS    29
#define TARI_C29_PROOFSIZE   42
#define TARI_C29_EDGE_BLOCK  64
#define TARI_C29_PACKED_BYTES 153   // ceil(42 * 29 / 8)

// verify() result codes (negative on failure, 0 on success)
#define TARI_C29_OK             0
#define TARI_C29_ERR_TOO_BIG   -1   // an edge nonce >= 2^29
#define TARI_C29_ERR_NOT_ASC   -2   // edge nonces not strictly ascending
#define TARI_C29_ERR_ENDPOINTS -3   // endpoints don't XOR to zero (not a cycle)
#define TARI_C29_ERR_BRANCH    -4   // node has degree > 2
#define TARI_C29_ERR_DEAD_END  -5   // walk dead-ends before closing
#define TARI_C29_ERR_SHORT     -6   // closes early: shorter than 42-cycle

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { uint64_t k0, k1, k2, k3; } tari_siphash_keys;

// (1) Derive the four SipHash key lanes for a given header nonce + mining_hash.
//     mining_hash is the 32-byte pre-PoW hash supplied by the pool/template.
void tari_c29_derive_keys(uint64_t header_nonce,
                          const uint8_t mining_hash[32],
                          tari_siphash_keys *out_keys);

// Cuckaroo29 edge endpoints (u,v) for one edge index, using the 64-edge
// sipblock construction. Useful to feed/validate a solver. Each endpoint is
// a 29-bit node value.
void tari_c29_edge(const tari_siphash_keys *keys, uint32_t edge_index,
                   uint32_t *u, uint32_t *v);

// (2) Pack / unpack the 42-nonce proof. `edge_nonces` are the cycle's edge
//     indices, ascending, each < 2^29. `packed` is exactly 153 bytes.
void tari_c29_pack(const uint32_t edge_nonces[TARI_C29_PROOFSIZE],
                   uint8_t packed[TARI_C29_PACKED_BYTES]);
void tari_c29_unpack(const uint8_t packed[TARI_C29_PACKED_BYTES],
                     uint32_t edge_nonces[TARI_C29_PROOFSIZE]);

// (3) Difficulty. `tari_c29_difficulty` packs nothing -- it hashes the already
//     packed 153-byte proof. `tari_c29_difficulty_from_hash` exposes the U256
//     division directly (hash is the 32-byte BLAKE2b digest, big-endian).
uint64_t tari_c29_difficulty(const uint8_t packed[TARI_C29_PACKED_BYTES]);
uint64_t tari_c29_difficulty_from_hash(const uint8_t hash[32]);

// Full 42-cycle verification: derive keys from (nonce, mining_hash), rebuild
// edges, and check the proof is a single 42-cycle. Returns TARI_C29_OK or a
// negative TARI_C29_ERR_* code. This mirrors Tari's verify_from_edges semantics.
int tari_c29_verify(uint64_t header_nonce,
                    const uint8_t mining_hash[32],
                    const uint32_t edge_nonces[TARI_C29_PROOFSIZE]);

// Convenience end-to-end check used by a solver before submitting a share:
// verifies the cycle AND returns its achieved difficulty (0 if the cycle is
// invalid). A share is a block iff the return value >= target.
uint64_t tari_c29_check(uint64_t header_nonce,
                        const uint8_t mining_hash[32],
                        const uint32_t edge_nonces[TARI_C29_PROOFSIZE]);

#ifdef __cplusplus
}
#endif
