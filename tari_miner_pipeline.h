#pragma once

#include <cstddef>

namespace tari_miner {

enum class DriverMode {
    Linux,
    WindowsWddm,
    WindowsTcc,
};

constexpr int MAX_PIPELINE = 5;
constexpr int AUTO_FALLBACK_PIPELINE = 2;
constexpr int WDDM_AUTO_CAP = 4;
constexpr size_t PIPELINE_MEMORY_RESERVE = 256ull << 20;

inline int clamp_pipeline_depth(int requested) {
    if (requested < 1) return 1;
    if (requested > MAX_PIPELINE) return MAX_PIPELINE;
    return requested;
}

inline int choose_pipeline_depth(
    bool explicit_set,
    int requested,
    DriverMode mode,
    size_t free_after_first_context,
    size_t bytes_per_context,
    bool memory_known = true
) {
    if (explicit_set)
        return clamp_pipeline_depth(requested);

    const int cap =
        mode == DriverMode::WindowsWddm ? WDDM_AUTO_CAP : MAX_PIPELINE;
    if (!memory_known || bytes_per_context == 0)
        return AUTO_FALLBACK_PIPELINE < cap ? AUTO_FALLBACK_PIPELINE : cap;

    size_t extra_contexts = 0;
    if (free_after_first_context > PIPELINE_MEMORY_RESERVE) {
        extra_contexts =
            (free_after_first_context - PIPELINE_MEMORY_RESERVE - 1) /
            bytes_per_context;
    }
    const size_t capped_extras =
        extra_contexts < (size_t)(cap - 1) ? extra_contexts : (size_t)(cap - 1);
    return 1 + (int)capped_extras;
}

} // namespace tari_miner
