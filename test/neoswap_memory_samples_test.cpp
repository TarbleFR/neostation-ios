#include "NeoSwapMemorySamples.h"
#include <cassert>
#include <limits>
#include <cstdio>
using namespace neostation::diagnostics;
int main() {
    MemorySamples samples;
    assert(samples.poll(0, false) == MemoryEvent::sample);
    assert(samples.poll(1999, false) == MemoryEvent::none);
    assert(samples.poll(2000, false) == MemoryEvent::sample);
    assert(samples.poll(2250, true) == MemoryEvent::session_start);
    assert(samples.active() && samples.session() == 1 && samples.valid_samples() == 0);
    samples.observe(true, 1024, 768);
    assert(samples.valid_samples() == 1 && samples.footprint_peak() == 1024 && !samples.delta_valid());
    assert(samples.poll(3249, true) == MemoryEvent::none);
    assert(samples.poll(3250, true) == MemoryEvent::sample);
    samples.observe(true, 2048, 1536);
    assert(samples.footprint_delta() == 1024 && samples.delta_valid());
    assert(samples.elapsed_ms() == 1000 && samples.footprint_peak() == 2048 && samples.resident_peak() == 1536);
    // Coalesce a burst on the existing timer; retain transitions even if the
    // latest pressure returned to normal before the next polling tick.
    samples.pressure_event(2);
    samples.pressure_event(4);
    samples.pressure_event(1);
    samples.pressure_event(1);
    assert(samples.poll(3500, true) == MemoryEvent::pressure);
    assert(samples.pressure_events() == 4 && samples.pressure_changes() == 3 && samples.pressure_level() == 1);
    assert(samples.poll(3750, true) == MemoryEvent::none);
    samples.observe(false, 0, 0);
    assert(!samples.delta_valid() && samples.valid_samples() == 2 && samples.footprint_peak() == 2048);
    samples.observe(true, 512, 400);
    assert(!samples.delta_valid()); // failed task_info breaks delta continuity
    samples.observe(true, 256, 200);
    assert(samples.delta_valid() && samples.footprint_delta() == -256);
    assert(samples.poll(4000, false) == MemoryEvent::session_end);
    samples.observe(true, 128, 100);
    const auto count = samples.valid_samples();
    assert(!samples.active() && samples.elapsed_ms() == 1750 && samples.footprint_peak() == 2048);
    assert(samples.poll(6000, false) == MemoryEvent::sample);
    samples.observe(true, 999999, 888888);
    assert(samples.valid_samples() == count && samples.elapsed_ms() == 1750 && samples.footprint_peak() == 2048);
    assert(samples.poll(6250, true) == MemoryEvent::session_start);
    assert(samples.session() == 2 && samples.valid_samples() == 0 && samples.footprint_peak() == 0);
    samples.observe(true, 0, 0);
    samples.observe(true, std::numeric_limits<std::uint64_t>::max(), 1);
    assert(samples.footprint_delta() == std::numeric_limits<std::int64_t>::max());
    samples.observe(true, 0, 0);
    assert(samples.footprint_delta() == std::numeric_limits<std::int64_t>::min());
    static_assert(MemorySamples::maximum_row_bytes <= MemorySamples::maximum_file_bytes);
    std::puts("PASS memory samples: active/idle cadence, session reset/end, pressure bursts, real-measurement validity, bounded peaks and signed deltas");
}
