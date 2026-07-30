// Small, GPU-independent miner reliability policies.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstddef>
#include <cstdint>
#include <set>
#include <string>

namespace tari_miner {

enum class WalletValidationError {
    None,
    Empty,
    WhitespaceOrControl,
    TooLong,
    TariAddressCharset,
};

// Base58 lengths a Tari address can have, from the consensus source at
// base_layer/common_types/src/tari_address/mod.rs: a single address encodes to
// 45-48 characters, a dual address to 89-443 (the upper bound covers the
// payment-id field).
constexpr size_t TARI_SINGLE_ADDRESS_MIN_LENGTH = 45;
constexpr size_t TARI_SINGLE_ADDRESS_MAX_LENGTH = 48;
constexpr size_t TARI_DUAL_ADDRESS_MIN_LENGTH = 89;
constexpr size_t TARI_DUAL_ADDRESS_MAX_LENGTH = 443;
constexpr size_t MAX_WALLET_LENGTH = TARI_DUAL_ADDRESS_MAX_LENGTH;

// Bitcoin base58: the digits and letters, minus 0 O I l. Those four are exactly
// the characters a mistyped or OCR-read address tends to gain.
inline bool is_base58_char(unsigned char c) {
    if (c >= '1' && c <= '9') return true;
    if (c >= 'a' && c <= 'z') return c != 'l';
    if (c >= 'A' && c <= 'Z') return c != 'I' && c != 'O';
    return false;
}

inline bool has_tari_address_length(size_t length) {
    return (length >= TARI_SINGLE_ADDRESS_MIN_LENGTH &&
            length <= TARI_SINGLE_ADDRESS_MAX_LENGTH) ||
           (length >= TARI_DUAL_ADDRESS_MIN_LENGTH &&
            length <= TARI_DUAL_ADDRESS_MAX_LENGTH);
}

inline bool is_ascii_alnum(unsigned char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
           (c >= 'A' && c <= 'Z');
}

inline bool is_hex_string(const std::string &text) {
    for (unsigned char c : text) {
        bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                   (c >= 'A' && c <= 'F');
        if (!hex) return false;
    }
    return true;
}

// This field is not always a Tari address: pools exist that expect a username,
// which is why --login-separator exists. So the charset rule is applied only to
// strings already shaped like an address - the length of one, and nothing but
// ASCII letters and digits. Anything else is passed through, and it is the pool
// that decides whether the login is good.
inline WalletValidationError validate_wallet(const std::string &wallet) {
    if (wallet.empty()) return WalletValidationError::Empty;

    for (unsigned char c : wallet) {
        if (c <= 0x20 || c == 0x7f)
            return WalletValidationError::WhitespaceOrControl;
    }
    if (wallet.size() > MAX_WALLET_LENGTH)
        return WalletValidationError::TooLong;

    if (!has_tari_address_length(wallet.size()))
        return WalletValidationError::None;
    for (unsigned char c : wallet) {
        if (!is_ascii_alnum(c)) return WalletValidationError::None;
    }
    // An all-hex login of the same length is a login, not a mistyped address:
    // the only non-base58 character it can hold is '0'.
    if (is_hex_string(wallet)) return WalletValidationError::None;

    for (unsigned char c : wallet) {
        if (!is_base58_char(c))
            return WalletValidationError::TariAddressCharset;
    }
    return WalletValidationError::None;
}

enum class PoolResponseKind {
    Other,
    LoginError,
    ShareAccepted,
    ShareRejected,
    OtherError,
};

constexpr uint64_t LOGIN_REQUEST_ID = 1;
constexpr uint64_t FIRST_SUBMIT_REQUEST_ID = 4;

// A pool that never answers a submit would otherwise grow the pending set for
// as long as the miner runs. Beyond this many outstanding submits the oldest
// is forgotten; it can then only be classified as an unmatched response.
constexpr size_t MAX_PENDING_SUBMITS = 256;

class PoolResponseTracker {
public:
    uint64_t begin_submit() {
        uint64_t id = next_submit_id_++;
        pending_submits_.insert(id);
        while (pending_submits_.size() > MAX_PENDING_SUBMITS)
            pending_submits_.erase(pending_submits_.begin());
        return id;
    }

    void cancel_submit(uint64_t id) {
        pending_submits_.erase(id);
    }

    PoolResponseKind classify(
        bool has_id,
        uint64_t id,
        bool has_error,
        bool has_result,
        bool result_true,
        bool result_false,
        bool login_pending,
        bool result_status_ok = false
    ) {
        if ((has_error || result_false) && login_pending &&
            ((!has_id) || id == LOGIN_REQUEST_ID))
            return PoolResponseKind::LoginError;

        auto pending = has_id ? pending_submits_.find(id) : pending_submits_.end();
        if (pending != pending_submits_.end()) {
            if (!has_error && !has_result)
                return PoolResponseKind::Other;
            pending_submits_.erase(pending);
            if (has_error || result_false) {
                return PoolResponseKind::ShareRejected;
            }
            if (result_true || result_status_ok) {
                return PoolResponseKind::ShareAccepted;
            }
            return PoolResponseKind::Other;
        }

        if (has_error) return PoolResponseKind::OtherError;
        return PoolResponseKind::Other;
    }

    size_t pending_submits() const {
        return pending_submits_.size();
    }

private:
    uint64_t next_submit_id_ = FIRST_SUBMIT_REQUEST_ID;
    // Ordered so the oldest outstanding submit is the one dropped at the cap.
    std::set<uint64_t> pending_submits_;
};

constexpr unsigned MAX_LOGIN_FAILURES = 3;
constexpr int LOGIN_FAILURE_EXIT_CODE = 4;
constexpr unsigned LOGIN_RETRY_SECONDS = 5;

class LoginFailurePolicy {
public:
    bool record_failure() {
        consecutive_failures_++;
        return consecutive_failures_ >= MAX_LOGIN_FAILURES;
    }

    void record_success() {
        consecutive_failures_ = 0;
    }

    unsigned consecutive_failures() const {
        return consecutive_failures_;
    }

private:
    unsigned consecutive_failures_ = 0;
};

// A pool that accepts the connection but never sends a job produces no error to
// count, so the login policy above never fires. Bound that case separately:
// back off between attempts, then exit so a supervisor can react.
constexpr unsigned MAX_SILENT_CYCLES = 10;
constexpr int POOL_SILENT_EXIT_CODE = 6;
constexpr unsigned FIRST_SILENT_BACKOFF_SECONDS = 5;
constexpr unsigned MAX_SILENT_BACKOFF_SECONDS = 60;

class PoolSilencePolicy {
public:
    // Returns true when the miner should stop retrying.
    bool record_silence() {
        consecutive_silences_++;
        return consecutive_silences_ >= MAX_SILENT_CYCLES;
    }

    void record_job() {
        consecutive_silences_ = 0;
    }

    unsigned consecutive_silences() const {
        return consecutive_silences_;
    }

    // Doubling backoff, capped, so a pool outage is not hammered.
    unsigned backoff_seconds() const {
        unsigned seconds = FIRST_SILENT_BACKOFF_SECONDS;
        for (unsigned i = 1; i < consecutive_silences_; ++i) {
            if (seconds >= MAX_SILENT_BACKOFF_SECONDS)
                return MAX_SILENT_BACKOFF_SECONDS;
            seconds *= 2;
        }
        return seconds < MAX_SILENT_BACKOFF_SECONDS
            ? seconds
            : MAX_SILENT_BACKOFF_SECONDS;
    }

private:
    unsigned consecutive_silences_ = 0;
};

constexpr unsigned MAX_CONSECUTIVE_ZERO_YIELDS = 3;
constexpr int SOLVER_FAILURE_EXIT_CODE = 5;

enum class SolverFailure {
    None,
    Cuda,
    ZeroYield,
};

class SolverWatchdog {
public:
    bool observe(uint32_t surviving_edges, bool cuda_ok) {
        if (failure_ != SolverFailure::None) return false;
        if (!cuda_ok) {
            failure_ = SolverFailure::Cuda;
            return false;
        }
        if (surviving_edges == 0) {
            consecutive_zero_yields_++;
            if (consecutive_zero_yields_ >= MAX_CONSECUTIVE_ZERO_YIELDS) {
                failure_ = SolverFailure::ZeroYield;
                return false;
            }
        } else {
            consecutive_zero_yields_ = 0;
        }
        return true;
    }

    unsigned consecutive_zero_yields() const {
        return consecutive_zero_yields_;
    }

    SolverFailure failure() const {
        return failure_;
    }

private:
    unsigned consecutive_zero_yields_ = 0;
    SolverFailure failure_ = SolverFailure::None;
};

} // namespace tari_miner
