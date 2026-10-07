// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#ifdef __cplusplus
#include <algorithm>
#include <cstdint>

namespace neostation::preparation {
constexpr std::uint64_t chunk_bytes = 16ULL * 1024 * 1024;
constexpr std::uint64_t readiness_deadline_ms = 1500;

// Background warming is incremental. A real contiguous consumer demand may
// request a larger object separately; it never turns startup into a GiB wait.
constexpr std::uint64_t next_chunk(std::uint64_t remaining, std::uint64_t budget,
                                 std::uint64_t page) noexcept {
    if (!page) return 0;
    const auto bytes = std::min({remaining, budget, chunk_bytes});
    return bytes - bytes % page;
}

enum class Mode { idle, warming, partial, donors, relay_only, ordinary };
constexpr const char* mode_name(Mode mode) noexcept {
    switch (mode) {
    case Mode::idle: return "idle";
    case Mode::warming: return "warming";
    case Mode::partial: return "donors-partial";
    case Mode::donors: return "donors-prepared";
    case Mode::relay_only: return "relay-only";
    case Mode::ordinary: return "ordinary";
    }
    return "ordinary";
}

struct Observation {
    bool pool_verified = false;
    std::uint32_t donor_count = 0;
    std::uint64_t prepared_bytes = 0;
    bool relay_ready = false; // verified backend, never merely a helper route
    bool refused = false;
};

// Used only on the existing serial maintenance queue. A timeout changes the
// diagnostic/fallback state, not ownership: late verified pages can still be
// adopted by this campaign, and session end must first drain every live loan.
class Lifecycle {
public:
    bool begin(std::uint64_t epoch, std::uint64_t now_ms) noexcept {
        if (active_ || !epoch || epoch <= epoch_) return false;
        active_ = true;
        epoch_ = epoch;
        started_ms_ = now_ms;
        first_prepared_ms_ = 0;
        first_ready_ms_ = 0;
        observed_prepared_ = false;
        observed_ready_ = false;
        timed_out_ = false;
        ++starts_;
        return true;
    }
    bool finish(std::uint64_t epoch, std::uint64_t live_blocks) noexcept {
        if (!active_ || epoch != epoch_ || live_blocks) return false;
        active_ = false;
        return true;
    }
    Mode observe(std::uint64_t epoch, std::uint64_t now_ms, const Observation& in) noexcept {
        if (!active_ || epoch != epoch_) return Mode::idle;
        const bool verified = in.pool_verified && in.donor_count && in.prepared_bytes;
        if (verified && !observed_prepared_) {
            first_prepared_ms_ = elapsed(now_ms);
            observed_prepared_ = true;
        }
        // A first partial preparation does not falsely satisfy the 16 MiB
        // seed. Keep the timeout outcome even if the campaign later recovers.
        if (!observed_ready_) {
            if (elapsed(now_ms) >= readiness_deadline_ms) timed_out_ = true;
            if (verified && in.prepared_bytes >= chunk_bytes) {
                observed_ready_ = true;
                first_ready_ms_ = elapsed(now_ms);
            }
        }
        if (verified) return in.prepared_bytes >= chunk_bytes ? Mode::donors : Mode::partial;
        if (!in.refused && !timed_out_) return Mode::warming;
        return in.relay_ready ? Mode::relay_only : Mode::ordinary;
    }
    std::uint64_t elapsed(std::uint64_t now_ms) const noexcept {
        return now_ms >= started_ms_ ? now_ms - started_ms_ : 0;
    }
    std::uint64_t starts() const noexcept { return starts_; }
    std::uint64_t epoch() const noexcept { return epoch_; }
    std::uint64_t first_prepared_ms() const noexcept { return first_prepared_ms_; }
    std::uint64_t first_ready_ms() const noexcept { return first_ready_ms_; }
    bool observed_prepared() const noexcept { return observed_prepared_; }
    bool observed_ready() const noexcept { return observed_ready_; }
    bool timed_out() const noexcept { return timed_out_; }
    bool active() const noexcept { return active_; }
private:
    bool active_ = false, observed_prepared_ = false, observed_ready_ = false, timed_out_ = false;
    std::uint64_t epoch_ = 0, started_ms_ = 0, first_prepared_ms_ = 0, first_ready_ms_ = 0, starts_ = 0;
};
} // namespace neostation::preparation
#endif
