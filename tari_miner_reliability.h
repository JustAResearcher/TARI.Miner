// Small, GPU-independent miner reliability policies.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_set>

namespace tari_miner {

enum class WalletValidationError {
    None,
    WhitespaceOrControl,
};

inline WalletValidationError validate_wallet(const std::string &wallet) {
    for (unsigned char c : wallet) {
        if (c <= 0x20 || c == 0x7f)
            return WalletValidationError::WhitespaceOrControl;
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

class PoolResponseTracker {
public:
    uint64_t begin_submit() {
        uint64_t id = next_submit_id_++;
        pending_submits_.insert(id);
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
        bool login_pending
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
            if (result_true) {
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
    std::unordered_set<uint64_t> pending_submits_;
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
