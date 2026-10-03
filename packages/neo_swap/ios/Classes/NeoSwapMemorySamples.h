// Bounded observation only: no allocator policy, automatic training or disk I/O.
#pragma once
#include <cstdint>
#include <limits>

namespace neostation::diagnostics {
enum class MemoryEvent { none, sample, session_start, session_end, pressure };

class MemorySamples {
public:
    static constexpr std::uint64_t active_interval_ms = 1000;
    static constexpr std::uint64_t idle_interval_ms = 2000;
    static constexpr std::uint64_t maximum_row_bytes = 64 * 1024;
    static constexpr std::uint64_t maximum_file_bytes = 2 * 1024 * 1024;

    void pressure_event(std::uint64_t level) noexcept {
        ++pressure_events_;
        if (level != pressure_level_) {
            pressure_pending_ = true;
            ++pressure_changes_;
            pressure_level_ = level;
        }
    }

    MemoryEvent poll(std::uint64_t now_ms, bool active) noexcept {
        const bool start = active && !active_;
        const bool end = !active && active_;
        ending_ = end;
        if (start) {
            ++session_;
            start_ms_ = now_ms;
            valid_samples_ = footprint_peak_ = resident_peak_ = 0;
            previous_valid_ = delta_valid_ = false;
        }
        active_ = active;
        if (active || end) elapsed_ms_ = now_ms >= start_ms_ ? now_ms - start_ms_ : 0;
        const auto interval = active ? active_interval_ms : idle_interval_ms;
        const bool due = !emitted_ || now_ms < last_emit_ms_ || now_ms - last_emit_ms_ >= interval;
        if (!start && !end && !pressure_pending_ && !due) return MemoryEvent::none;
        const auto event = start ? MemoryEvent::session_start : end ? MemoryEvent::session_end :
            pressure_pending_ ? MemoryEvent::pressure : MemoryEvent::sample;
        pressure_pending_ = false;
        emitted_ = true;
        last_emit_ms_ = now_ms;
        return event;
    }

    void observe(bool valid, std::uint64_t footprint, std::uint64_t resident) noexcept {
        delta_valid_ = valid && previous_valid_ && (active_ || ending_);
        if (delta_valid_) footprint_delta_ = difference(footprint, previous_footprint_);
        previous_valid_ = valid && (active_ || ending_);
        ending_ = false;
        if (!previous_valid_) return; // Unknown never becomes a fictitious zero RAM sample.
        previous_footprint_ = footprint;
        ++valid_samples_;
        if (footprint > footprint_peak_) footprint_peak_ = footprint;
        if (resident > resident_peak_) resident_peak_ = resident;
    }

    bool active() const noexcept { return active_; }
    std::uint64_t session() const noexcept { return session_; }
    std::uint64_t elapsed_ms() const noexcept { return elapsed_ms_; }
    std::uint64_t valid_samples() const noexcept { return valid_samples_; }
    std::uint64_t footprint_peak() const noexcept { return footprint_peak_; }
    std::uint64_t resident_peak() const noexcept { return resident_peak_; }
    bool delta_valid() const noexcept { return delta_valid_; }
    std::int64_t footprint_delta() const noexcept { return footprint_delta_; }
    std::uint64_t pressure_level() const noexcept { return pressure_level_; }
    std::uint64_t pressure_events() const noexcept { return pressure_events_; }
    std::uint64_t pressure_changes() const noexcept { return pressure_changes_; }

private:
    static std::int64_t difference(std::uint64_t value, std::uint64_t previous) noexcept {
        constexpr auto maximum = std::numeric_limits<std::int64_t>::max();
        const auto magnitude = value >= previous ? value - previous : previous - value;
        if (magnitude > static_cast<std::uint64_t>(maximum))
            return value >= previous ? maximum : std::numeric_limits<std::int64_t>::min();
        const auto signed_magnitude = static_cast<std::int64_t>(magnitude);
        return value >= previous ? signed_magnitude : -signed_magnitude;
    }
    bool active_ = false, ending_ = false, emitted_ = false;
    bool pressure_pending_ = false, previous_valid_ = false, delta_valid_ = false;
    std::uint64_t session_ = 0, start_ms_ = 0, elapsed_ms_ = 0, last_emit_ms_ = 0;
    std::uint64_t valid_samples_ = 0, footprint_peak_ = 0, resident_peak_ = 0, previous_footprint_ = 0;
    std::uint64_t pressure_level_ = 0, pressure_events_ = 0, pressure_changes_ = 0;
    std::int64_t footprint_delta_ = 0;
};
} // namespace neostation::diagnostics
