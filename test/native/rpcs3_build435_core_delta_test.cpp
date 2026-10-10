// Executes the Build 435 Core policies on the host: the measured per-process
// memory envelope (rpcs3/ios/IOSMemoryPressurePolicy.h) and the deferred SPU
// compilation decisions (rpcs3/Emu/Cell/SPUDeferredCompilePolicy.h). This is
// pure policy evidence; it proves neither iPhone memory behaviour nor frame
// rate. The wiring of both policies is checked by the Python runner.
#include "rpcs3/Emu/Cell/SPUDeferredCompilePolicy.h"
#include "rpcs3/ios/IOSMemoryPressurePolicy.h"

#include <cassert>
#include <cstdint>
#include <cstdio>

using namespace rpcs3::ios;
using namespace rpcs3::spu;
using pressure = process_memory_pressure;
using decision = deferred_dispatch;

namespace
{
constexpr std::uint64_t mib = process_memory_mib;
constexpr std::uint64_t gib = 1024 * mib;
// Build 352 trace on the iPhone 16 Pro Max: 5 140 MiB footprint with 1 536 MiB
// of headroom left, i.e. a 6 676 MiB allowance.
constexpr std::uint64_t measured_limit = 6676 * mib;
}

int main()
{
	// --- Allowance estimate: high-water mark of footprint + headroom, bounded by RAM.
	static_assert(estimate_process_memory_limit(5140 * mib, 1536 * mib, 0, 8 * gib) == measured_limit);
	static_assert(estimate_process_memory_limit(0, 1536 * mib, measured_limit, 8 * gib) == measured_limit);
	static_assert(estimate_process_memory_limit(5140 * mib, 0, measured_limit, 8 * gib) == measured_limit);
	static_assert(estimate_process_memory_limit(6 * gib, 3 * gib, 0, 8 * gib) == 8 * gib);
	static_assert(estimate_process_memory_limit(2 * gib, 1 * gib, measured_limit, 8 * gib) == measured_limit);
	static_assert(estimate_process_memory_limit(~0ull, 1, 0, 0) == ~0ull);

	// --- Relative moderate stage: one quarter of the allowance, floored at the
	// severe exit, capped at the Build 352 constant; severe and fatal absolute.
	static_assert(high_footprint_moderate_enter(measured_limit) == 1669 * mib);
	static_assert(high_footprint_moderate_exit(measured_limit) == 1925 * mib);
	static_assert(high_footprint_moderate_enter(0) == high_footprint_headroom_moderate_enter);
	static_assert(high_footprint_moderate_enter(4 * gib) == process_headroom_severe_exit);
	static_assert(high_footprint_moderate_enter(12 * gib) == high_footprint_headroom_moderate_enter);
	static_assert(high_footprint_moderate_enter(1) > process_headroom_severe_enter);
	static_assert(high_footprint_moderate_exit(1) > process_headroom_severe_exit);

	static_assert(get_process_memory_pressure(1670 * mib, pressure::low, true, measured_limit) == pressure::low);
	static_assert(get_process_memory_pressure(1669 * mib, pressure::low, true, measured_limit) == pressure::moderate);
	static_assert(get_process_memory_pressure(1900 * mib, pressure::moderate, true, measured_limit) == pressure::moderate);
	static_assert(get_process_memory_pressure(1926 * mib, pressure::moderate, true, measured_limit) == pressure::low);
	static_assert(get_process_memory_pressure(1024 * mib, pressure::low, true, measured_limit) == pressure::severe);
	static_assert(get_process_memory_pressure(512 * mib, pressure::low, true, measured_limit) == pressure::fatal);
	// Unknown allowance keeps the Build 352 behaviour; the default profile is untouched.
	static_assert(get_process_memory_pressure(2000 * mib, pressure::low, true, 0) == pressure::moderate);
	static_assert(get_process_memory_pressure(2000 * mib, pressure::low, false, measured_limit) == pressure::low);
	static_assert(get_process_memory_pressure(1536 * mib, pressure::low, false, measured_limit) == pressure::moderate);

	// --- Footprint walk with the measured allowance: the Build 352 stage began
	// at 4 116 MiB of footprint; Build 435 begins at 5 007 MiB.
	{
		pressure state = pressure::low;
		std::uint64_t first_moderate = 0;
		for (std::uint64_t footprint = 3 * gib; footprint < measured_limit; footprint += 16 * mib)
		{
			state = get_process_memory_pressure(measured_limit - footprint, state, true, measured_limit);
			if (state == pressure::moderate && !first_moderate) first_moderate = footprint;
		}
		assert(first_moderate == 5008 * mib);
		assert(get_process_memory_pressure(measured_limit - 4116 * mib, pressure::low, true, 0) == pressure::moderate);
		assert(get_process_memory_pressure(measured_limit - 4116 * mib, pressure::low, true, measured_limit) == pressure::low);
	}

	// --- Adaptive cooldown: bases 1.5 s / 3 s, doubled while passes free nothing
	// lasting, capped at 24 s, back to the base after an effective pass.
	static_assert(next_moderate_reclaim_delay_ms(0, true, true) == 1500);
	static_assert(next_moderate_reclaim_delay_ms(0, false, true) == 3000);
	static_assert(next_moderate_reclaim_delay_ms(1500, true, false) == 3000);
	static_assert(next_moderate_reclaim_delay_ms(3000, false, false) == 6000);
	static_assert(next_moderate_reclaim_delay_ms(24000, false, false) == 24000);
	static_assert(next_moderate_reclaim_delay_ms(24000, true, true) == 1500);
	static_assert(moderate_reclaim_was_effective(1600 * mib, 1728 * mib));
	static_assert(!moderate_reclaim_was_effective(1600 * mib, 1727 * mib));
	static_assert(!moderate_reclaim_was_effective(1600 * mib, 1200 * mib));
	{
		// The Build 412 cycle: every pass "relieves" (frees textures) but the
		// title reloads them, so the headroom never rises.
		std::uint64_t delay = 0, total_ms = 0, passes = 0;
		const std::uint64_t headroom = 1500 * mib;
		for (std::uint64_t elapsed = 0; elapsed < 90'000; elapsed += delay ? delay : 0, ++passes)
		{
			const bool effective = !delay || moderate_reclaim_was_effective(headroom, headroom);
			delay = next_moderate_reclaim_delay_ms(delay, true, effective);
			total_ms += delay;
			if (!delay) break;
		}
		assert(passes == 7); // 1.5 s, 3, 6, 12, 24, 24, 24 s: seven passes in 90 s instead of about 45
		assert(total_ms == 94500);
	}

	// --- Deferred SPU compilation decisions.
	static_assert(classify_dispatch(true, true, compile_state_compiling, false, false) == decision::run_compiled);
	static_assert(classify_dispatch(false, false, compile_state_unclaimed, false, false) == decision::compile_inline);
	static_assert(classify_dispatch(true, false, compile_state_unclaimed, false, true) == decision::compile_inline);
	static_assert(classify_dispatch(true, false, compile_state_unclaimed, false, false) == decision::enqueue_and_interpret);
	static_assert(classify_dispatch(true, false, compile_state_unclaimed, true, false) == decision::interpret_pending);
	static_assert(classify_dispatch(true, false, compile_state_compiling, false, false) == decision::interpret_pending);
	static_assert(classify_dispatch(true, false, compile_state_failed, true, false) == decision::interpret_failed);
	static_assert(classify_dispatch(true, false, compile_state_complete, true, false) == decision::compile_inline);
	static_assert(!interpreter_should_exit(compile_state_compiling, true, 1 << 20));
	static_assert(!interpreter_should_exit(compile_state_failed, true, 1 << 20));
	static_assert(interpreter_should_exit(compile_state_complete, true, 0));
	static_assert(!interpreter_should_exit(compile_state_complete, false, interpreter_handoff_quantum_branches - 1));
	static_assert(interpreter_should_exit(compile_state_complete, false, interpreter_handoff_quantum_branches));
	static_assert(deferred_worker_count(6) == 2 && deferred_worker_count(8) == 3 && deferred_worker_count(2) == 1 && deferred_worker_count(0) == 1);
	static_assert(prefer_request(5, 9, 4, 1) && !prefer_request(4, 1, 5, 9) && prefer_request(4, 1, 4, 2) && !prefer_request(4, 2, 4, 1));
	static_assert(deferred_queue_limit == 256 && deferred_compile_enabled);
	{
		// Hottest first, oldest among equals: a queue of four requests.
		struct request { std::uint64_t hits, sequence; } queue[] = {{1, 1}, {7, 2}, {7, 3}, {3, 4}};
		std::size_t best = 0;
		for (std::size_t i = 1; i < 4; i++)
			if (prefer_request(queue[i].hits, queue[i].sequence, queue[best].hits, queue[best].sequence)) best = i;
		assert(best == 1);
	}

	std::printf("PASS Build435 Core policies: measured allowance, relative moderate stage, adaptive cooldown, deferred SPU dispatch and hand-off\n");
	return 0;
}
