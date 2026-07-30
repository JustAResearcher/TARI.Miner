#include <cstdio>

#include "../tari_miner_pipeline.h"

static int failures = 0;

static void expect_depth(
    const char *name,
    int expected,
    bool explicit_set,
    int requested,
    tari_miner::DriverMode mode,
    size_t free_bytes,
    size_t context_bytes,
    bool memory_known = true
) {
    const int actual = tari_miner::choose_pipeline_depth(
        explicit_set,
        requested,
        mode,
        free_bytes,
        context_bytes,
        memory_known
    );
    if (actual != expected) {
        std::fprintf(
            stderr, "FAIL %s: expected %d, got %d\n", name, expected, actual
        );
        failures++;
    }
}

int main() {
    const size_t gib = 1ull << 30;
    const size_t context = 6 * gib;
    const size_t reserve = tari_miner::PIPELINE_MEMORY_RESERVE;

    expect_depth(
        "Linux high memory", 5, false, 2, tari_miner::DriverMode::Linux,
        4 * context + reserve + 1, context
    );
    expect_depth(
        "Linux medium memory", 3, false, 2, tari_miner::DriverMode::Linux,
        2 * context + reserve + 1, context
    );
    expect_depth(
        "WDDM automatic cap", 4, false, 2, tari_miner::DriverMode::WindowsWddm,
        4 * context + reserve + 1, context
    );
    expect_depth(
        "TCC high memory", 5, false, 2, tari_miner::DriverMode::WindowsTcc,
        4 * context + reserve + 1, context
    );
    expect_depth(
        "explicit bypasses WDDM cap", 5, true, 5,
        tari_miner::DriverMode::WindowsWddm, 0, context
    );
    expect_depth(
        "explicit low clamp", 1, true, 0, tari_miner::DriverMode::Linux,
        0, context
    );
    expect_depth(
        "explicit high clamp", 5, true, 99, tari_miner::DriverMode::Linux,
        0, context
    );
    expect_depth(
        "strict one-context boundary", 1, false, 2,
        tari_miner::DriverMode::Linux, context + reserve, context
    );
    expect_depth(
        "room for second context", 2, false, 2,
        tari_miner::DriverMode::Linux, context + reserve + 1, context
    );
    expect_depth(
        "room for third context", 3, false, 2,
        tari_miner::DriverMode::Linux, 2 * context + reserve + 1, context
    );
    expect_depth(
        "memory query fallback", 2, false, 5, tari_miner::DriverMode::Linux,
        0, context, false
    );
    expect_depth(
        "zero context fallback", 2, false, 5, tari_miner::DriverMode::Linux,
        0, 0
    );

    if (failures) {
        std::fprintf(stderr, "%d pipeline selector test(s) failed\n", failures);
        return 1;
    }
    std::puts("pipeline selector tests passed");
    return 0;
}
