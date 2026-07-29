// GPU-independent regressions for miner reliability policy.
// SPDX-License-Identifier: GPL-3.0-or-later

#include "../tari_miner_reliability.h"

#include <cstdio>
#include <string>

static int failures = 0;

static void check(bool condition, const char *name) {
    std::printf("  [%s] %s\n", condition ? "PASS" : "FAIL", name);
    if (!condition) failures++;
}

static void test_wallet_validation() {
    std::puts("Wallet validation:");
    const std::string standard_address(91, '1');
    check(tari_miner::validate_wallet(standard_address) ==
              tari_miner::WalletValidationError::None,
          "Base58 address is accepted");
    check(tari_miner::validate_wallet("custom-pool-login") ==
              tari_miner::WalletValidationError::None,
          "custom pool login format is accepted");
    check(tari_miner::validate_wallet("00aabbccddeeff") ==
              tari_miner::WalletValidationError::None,
          "hex address format is accepted");
    check(tari_miner::validate_wallet("\xf0\x9f\x90\xa2\xf0\x9f\x8c\x88") ==
              tari_miner::WalletValidationError::None,
          "UTF-8 emoji address bytes are accepted");

    std::string with_cr = standard_address + '\r';
    check(tari_miner::validate_wallet(with_cr) ==
              tari_miner::WalletValidationError::WhitespaceOrControl,
           "trailing carriage return is rejected");
    for (char invalid : std::string(" \t\n\v\f")) {
        std::string address = standard_address;
        address[10] = invalid;
        check(tari_miner::validate_wallet(address) ==
                  tari_miner::WalletValidationError::WhitespaceOrControl,
               "embedded whitespace is rejected");
    }
    for (unsigned char invalid : {0x01, 0x1f, 0x7f}) {
        std::string address = standard_address;
        address[10] = static_cast<char>(invalid);
        check(tari_miner::validate_wallet(address) ==
                  tari_miner::WalletValidationError::WhitespaceOrControl,
              "embedded control byte is rejected");
    }
}

static void test_pool_response_classification() {
    std::puts("Pool response classification:");
    using tari_miner::PoolResponseKind;
    tari_miner::PoolResponseTracker tracker;
    check(tracker.classify(true, 1, true, false, false, false, true) ==
              PoolResponseKind::LoginError,
          "login error is classified separately");
    check(tracker.classify(true, 1, false, true, false, true, true) ==
              PoolResponseKind::LoginError,
          "login result false is classified as a fatal rejection");
    check(tracker.classify(true, 1, false, true, true, false, true) ==
              PoolResponseKind::Other,
           "login success is not counted as an accepted share");
    check(tracker.classify(true, 1, true, false, false, false, false) ==
              PoolResponseKind::OtherError,
          "a late login-id error is not treated as a new login failure");

    uint64_t first = tracker.begin_submit();
    uint64_t second = tracker.begin_submit();
    check(first != second && tracker.pending_submits() == 2,
          "submit request IDs are unique and tracked");
    check(tracker.classify(true, second, true, false, false, false, false) ==
              PoolResponseKind::ShareRejected,
          "tracked submit error is a rejected share");
    check(tracker.classify(true, first, false, true, true, false, false) ==
              PoolResponseKind::ShareAccepted,
          "tracked submits can complete out of order");
    check(tracker.pending_submits() == 0,
          "terminal responses consume pending submit IDs");
    check(tracker.classify(true, first, false, true, true, false, false) ==
              PoolResponseKind::Other,
          "duplicate submit response is ignored");
    check(tracker.classify(true, 999, true, false, false, false, false) ==
              PoolResponseKind::OtherError,
          "unmatched error is not a rejected share");

    uint64_t third = tracker.begin_submit();
    check(tracker.classify(true, third, false, true, false, true, false) ==
              PoolResponseKind::ShareRejected,
          "tracked result false is a rejected share");
    uint64_t cancelled = tracker.begin_submit();
    tracker.cancel_submit(cancelled);
    check(tracker.classify(true, cancelled, false, true, true, false, false) ==
              PoolResponseKind::Other,
           "failed send cancels its pending submit");
    uint64_t incomplete = tracker.begin_submit();
    check(tracker.classify(true, incomplete, false, false, false, false, false) ==
              PoolResponseKind::Other &&
              tracker.pending_submits() == 1 &&
              tracker.classify(true, incomplete, false, true, true, false, false) ==
              PoolResponseKind::ShareAccepted &&
              tracker.pending_submits() == 0,
          "a nonterminal response cannot consume a pending submit");
    uint64_t other_result = tracker.begin_submit();
    check(tracker.classify(
              true, other_result, false, true, false, false, false) ==
              PoolResponseKind::Other &&
              tracker.pending_submits() == 0,
          "an explicit non-boolean result terminates without counting a share");
    check(tracker.classify(false, 0, true, false, false, false, true) ==
              PoolResponseKind::LoginError,
          "an id-less error before login completes is fatal");
    check(tracker.classify(false, 0, true, false, false, false, false) ==
              PoolResponseKind::OtherError,
          "an unrelated pool error is not counted as a share reject");
}

static void test_login_failure_policy() {
    std::puts("Login failure policy:");
    check(tari_miner::LOGIN_FAILURE_EXIT_CODE == 4,
          "fatal login rejection uses exit code 4");
    tari_miner::LoginFailurePolicy policy;
    check(!policy.record_failure() && policy.consecutive_failures() == 1,
          "first explicit login failure retries");
    check(!policy.record_failure() && policy.consecutive_failures() == 2,
          "second explicit login failure retries");
    policy.record_success();
    check(policy.consecutive_failures() == 0,
          "successful job resets login failures");
    check(!policy.record_failure() && !policy.record_failure() &&
              policy.record_failure(),
          "third consecutive login failure exits");
}

static void test_solver_watchdog() {
    std::puts("Solver watchdog:");
    check(tari_miner::SOLVER_FAILURE_EXIT_CODE == 5,
          "fatal solver failure uses exit code 5");
    tari_miner::SolverWatchdog watchdog;
    check(watchdog.observe(1000, true), "healthy trim is accepted");
    check(watchdog.observe(0, true) && watchdog.consecutive_zero_yields() == 1,
          "first zero-yield trim is tolerated");
    check(watchdog.observe(1000, true) && watchdog.consecutive_zero_yields() == 0,
          "healthy trim resets the zero-yield count");
    check(watchdog.observe(0, true), "first consecutive zero yield is tolerated");
    check(watchdog.observe(0, true), "second consecutive zero yield is tolerated");
    check(!watchdog.observe(0, true) &&
              watchdog.failure() == tari_miner::SolverFailure::ZeroYield,
          "third consecutive zero yield trips the watchdog");
    check(!watchdog.observe(1000, true),
          "watchdog failure remains sticky");

    tari_miner::SolverWatchdog cuda_watchdog;
    check(!cuda_watchdog.observe(0, false) &&
              cuda_watchdog.failure() == tari_miner::SolverFailure::Cuda,
          "CUDA failure takes priority and trips immediately");
    check(cuda_watchdog.consecutive_zero_yields() == 0,
          "CUDA failure is not counted as a zero yield");

    tari_miner::SolverWatchdog first_context;
    tari_miner::SolverWatchdog second_context;
    check(first_context.observe(0, true) &&
              first_context.observe(0, true) &&
              second_context.observe(1000, true),
          "solver contexts track health independently");
    check(!first_context.observe(0, true) &&
              second_context.observe(1000, true) &&
              second_context.failure() == tari_miner::SolverFailure::None,
          "one failed context does not poison another");
}

int main() {
    test_wallet_validation();
    test_pool_response_classification();
    test_login_failure_policy();
    test_solver_watchdog();
    std::printf("\n%s (%d failure%s)\n",
                failures == 0 ? "ALL PASSED" : "FAILED",
                failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
