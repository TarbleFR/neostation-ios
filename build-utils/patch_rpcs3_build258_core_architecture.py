#!/usr/bin/env python3
"""Apply Build 258's core-only scheduler and low-overhead profiler changes."""

from __future__ import annotations

import sys
from pathlib import Path


MARKER = "NEOSTATION_BUILD258_CORE_ARCHITECTURE_V1"


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{description}: expected one source anchor, found {count}")
    return text.replace(old, new, 1)


def patch_performance_header(source: Path) -> None:
    path = source / "rpcs3/ios/RPCS3IOSPerformance.h"
    text = path.read_text()
    if MARKER in text:
        return

    anchor = """void record_presented_frame(u32 rsx_load) noexcept;
"""
    replacement = f"""void record_presented_frame(u32 rsx_load) noexcept;

// {MARKER}: native-core events used by the out-of-band profiler. Timestamps
// are counter ticks so hot paths avoid division and allocation.
void record_pipeline_job_queued(u32 pending_jobs) noexcept;
void record_pipeline_job_completed(u64 queue_wait_ticks, u64 compile_ticks) noexcept;
void record_gpu_fence_wait(u64 wait_ticks, bool timed_out) noexcept;
void record_range_lock_wait(u64 wait_ticks) noexcept;
"""
    path.write_text(replace_once(text, anchor, replacement, "performance hooks"))


def patch_pipeline_compiler(source: Path) -> None:
    header = source / "rpcs3/Emu/RSX/VK/VKPipelineCompiler.h"
    text = header.read_text()
    if MARKER not in text:
        text = replace_once(
            text,
            '#include "util/fnv_hash.hpp"\n',
            '#include "util/fnv_hash.hpp"\n#include "util/tsc.hpp"\n',
            "pipeline timer include",
        )
        text = replace_once(
            text,
            """\t\tvoid operator()();

\tprivate:
""",
            f"""\t\tvoid operator()();

\t\t// {MARKER}: queued plus in-flight work. The dispatcher uses this
\t\t// instead of blind round-robin assignment, avoiding head-of-line
\t\t// blocking behind an unusually expensive pipeline.
\t\tu32 pending_jobs() const noexcept
\t\t{{
\t\t\treturn m_pending_jobs.load();
\t\t}}

\tprivate:
""",
            "pipeline pending accessor",
        )
        text = replace_once(
            text,
            """\t\t\top_flags flags;

\t\t\tpipe_compiler_job(
""",
            """\t\t\top_flags flags;
\t\t\tu64 queued_tsc = utils::get_tsc();

\t\t\tpipe_compiler_job(
""",
            "pipeline enqueue timestamp",
        )
        text = replace_once(
            text,
            """\t\tconst vk::render_device* m_device = nullptr;
\t\tlf_queue<pipe_compiler_job> m_work_queue;
""",
            """\t\tconst vk::render_device* m_device = nullptr;
\t\tlf_queue<pipe_compiler_job> m_work_queue;
\t\tatomic_t<u32> m_pending_jobs{0};
""",
            "pipeline pending counter",
        )
        header.write_text(text)

    impl = source / "rpcs3/Emu/RSX/VK/VKPipelineCompiler.cpp"
    text = impl.read_text()
    if MARKER in text:
        return

    text = replace_once(
        text,
        '#include "Utilities/Thread.h"\n',
        f'''#include "Utilities/Thread.h"

#ifdef RPCS3_IOS
#include "ios/RPCS3IOSPerformance.h"
#endif

// {MARKER}
''',
        "pipeline profiler include",
    )

    old_operator = """\tvoid pipe_compiler::operator()()
\t{
\t\twhile (thread_ctrl::state() != thread_state::aborting)
\t\t{
\t\t\tfor (auto&& job : m_work_queue.pop_all())
\t\t\t{
\t\t\t\tif (!job.is_graphics_job)
\t\t\t\t{
\t\t\t\t\tauto compiled = int_compile_compute_pipe(job.compute_data, job.inputs, job.flags);
\t\t\t\t\tjob.callback_func(compiled);
\t\t\t\t\tcontinue;
\t\t\t\t}

\t\t\t\tif (job.create_info_func)
\t\t\t\t{
\t\t\t\t\tauto compiled = int_compile_graphics_pipe(job.create_info_func, job.inputs, {}, job.flags);
\t\t\t\t\tjob.callback_func(compiled);
\t\t\t\t\tcontinue;
\t\t\t\t}

\t\t\t\tauto compiled = int_compile_graphics_pipe(job.graphics_data, job.graphics_modules, job.inputs, {}, job.flags);
\t\t\t\tjob.callback_func(compiled);
\t\t\t}

\t\t\tthread_ctrl::wait_on(m_work_queue);
\t\t}
\t}
"""
    new_operator = """\tvoid pipe_compiler::operator()()
\t{
\t\twhile (thread_ctrl::state() != thread_state::aborting)
\t\t{
\t\t\tfor (auto&& job : m_work_queue.pop_all())
\t\t\t{
\t\t\t\tconst u64 compile_begin = utils::get_tsc();

\t\t\t\tif (!job.is_graphics_job)
\t\t\t\t{
\t\t\t\t\tauto compiled = int_compile_compute_pipe(job.compute_data, job.inputs, job.flags);
\t\t\t\t\tjob.callback_func(compiled);
\t\t\t\t}
\t\t\t\telse if (job.create_info_func)
\t\t\t\t{
\t\t\t\t\tauto compiled = int_compile_graphics_pipe(job.create_info_func, job.inputs, {}, job.flags);
\t\t\t\t\tjob.callback_func(compiled);
\t\t\t\t}
\t\t\t\telse
\t\t\t\t{
\t\t\t\t\tauto compiled = int_compile_graphics_pipe(job.graphics_data, job.graphics_modules, job.inputs, {}, job.flags);
\t\t\t\t\tjob.callback_func(compiled);
\t\t\t\t}

\t\t\t\tconst u64 compile_end = utils::get_tsc();
\t\t\t\tm_pending_jobs--;
#ifdef RPCS3_IOS
\t\t\t\trpcs3::ios::record_pipeline_job_completed(
\t\t\t\t\tcompile_begin >= job.queued_tsc ? compile_begin - job.queued_tsc : 0,
\t\t\t\t\tcompile_end >= compile_begin ? compile_end - compile_begin : 0);
#endif
\t\t\t}

\t\t\tthread_ctrl::wait_on(m_work_queue);
\t\t}
\t}
"""
    text = replace_once(text, old_operator, new_operator, "pipeline worker loop")

    push_anchor = "\t\tm_work_queue.push("
    if text.count(push_anchor) != 3:
        raise SystemExit(
            f"pipeline enqueue sites: expected three anchors, found {text.count(push_anchor)}"
        )
    push_replacement = """\t\tconst u32 pending = ++m_pending_jobs;
#ifdef RPCS3_IOS
\t\trpcs3::ios::record_pipeline_job_queued(pending);
#endif
\t\tm_work_queue.push("""
    text = text.replace(push_anchor, push_replacement)

    old_dispatch = """\tpipe_compiler* get_pipe_compiler()
\t{
\t\tensure(g_pipe_compilers);
\t\tint thread_index = g_compiler_index++;

\t\treturn g_pipe_compilers.get()->begin() + (thread_index % g_num_pipe_compilers);
\t}
"""
    new_dispatch = """\tpipe_compiler* get_pipe_compiler()
\t{
\t\tensure(g_pipe_compilers);
\t\tensure(g_num_pipe_compilers > 0);

\t\tauto* const first = g_pipe_compilers.get()->begin();
\t\tconst u32 start = static_cast<u32>(g_compiler_index++) % g_num_pipe_compilers;
\t\tpipe_compiler* best = first + start;
\t\tu32 best_load = best->pending_jobs();

\t\t// Rotate the scan origin for fair ties, but always assign behind the
\t\t// smallest queued + in-flight load. A long driver compile can no longer
\t\t// trap later jobs in the same round-robin shard while another worker idles.
\t\tfor (u32 offset = 1; offset < static_cast<u32>(g_num_pipe_compilers) && best_load; ++offset)
\t\t{
\t\t\tpipe_compiler* const candidate = first + ((start + offset) % g_num_pipe_compilers);
\t\t\tconst u32 load = candidate->pending_jobs();
\t\t\tif (load < best_load)
\t\t\t{
\t\t\t\tbest = candidate;
\t\t\t\tbest_load = load;
\t\t\t}
\t\t}

\t\treturn best;
\t}
"""
    impl.write_text(replace_once(text, old_dispatch, new_dispatch, "pipeline dispatcher"))


def patch_gpu_fence_wait(source: Path) -> None:
    path = source / "rpcs3/Emu/RSX/VK/vkutils/sync.cpp"
    text = path.read_text()
    if MARKER in text:
        return
    text = replace_once(
        text,
        '#include "Emu/Cell/timers.hpp"\n',
        f'''#include "Emu/Cell/timers.hpp"

#ifdef RPCS3_IOS
#include "ios/RPCS3IOSPerformance.h"
#endif

// {MARKER}
''',
        "fence profiler include",
    )
    old = """\tVkResult wait_for_fence(fence* pFence, u64 timeout)
\t{
\t\tpFence->wait_flush();

\t\tif (timeout)
\t\t{
\t\t\treturn vkWaitForFences(*g_render_device, 1, &pFence->handle, VK_FALSE, timeout * 1000ull);
\t\t}
\t\telse
\t\t{
\t\t\twhile (auto status = vkGetFenceStatus(*g_render_device, pFence->handle))
\t\t\t{
\t\t\t\tswitch (status)
\t\t\t\t{
\t\t\t\tcase VK_NOT_READY:
\t\t\t\t\tutils::pause();
\t\t\t\t\tcontinue;
\t\t\t\tdefault:
\t\t\t\t\tdie_with_error(status);
\t\t\t\t\treturn status;
\t\t\t\t}
\t\t\t}

\t\t\treturn VK_SUCCESS;
\t\t}
\t}
"""
    new = """\tVkResult wait_for_fence(fence* pFence, u64 timeout)
\t{
\t\tpFence->wait_flush();
#ifdef RPCS3_IOS
\t\tconst u64 wait_begin = utils::get_tsc();
#endif
\t\tVkResult result = VK_SUCCESS;

\t\tif (timeout)
\t\t{
\t\t\tresult = vkWaitForFences(*g_render_device, 1, &pFence->handle, VK_FALSE, timeout * 1000ull);
\t\t}
\t\telse
\t\t{
\t\t\twhile (auto status = vkGetFenceStatus(*g_render_device, pFence->handle))
\t\t\t{
\t\t\t\tif (status == VK_NOT_READY)
\t\t\t\t{
\t\t\t\t\tutils::pause();
\t\t\t\t\tcontinue;
\t\t\t\t}

\t\t\t\tdie_with_error(status);
\t\t\t\tresult = status;
\t\t\t\tbreak;
\t\t\t}
\t\t}

#ifdef RPCS3_IOS
\t\tconst u64 wait_end = utils::get_tsc();
\t\trpcs3::ios::record_gpu_fence_wait(
\t\t\twait_end >= wait_begin ? wait_end - wait_begin : 0,
\t\t\tresult == VK_TIMEOUT);
#endif
\t\treturn result;
\t}
"""
    path.write_text(replace_once(text, old, new, "GPU fence wait"))


def patch_range_lock_wait(source: Path) -> None:
    path = source / "rpcs3/Emu/Memory/vm.cpp"
    text = path.read_text()
    if MARKER in text:
        return
    text = replace_once(
        text,
        '#include "ios/IOSReservationLockPolicy.h"\n',
        f'''#include "ios/IOSReservationLockPolicy.h"
#include "ios/RPCS3IOSPerformance.h"
// {MARKER}
''',
        "range profiler include",
    )
    old = """\t\t\t\telse if (const u64 bits = get_range_lock_bits(true))
\t\t\t\t{
\t\t\t\t\tget_range_lock_bits(true).wait(bits, atomic_wait_timeout{50'000});
\t\t\t\t}
"""
    new = """\t\t\t\telse if (const u64 bits = get_range_lock_bits(true))
\t\t\t\t{
#ifdef RPCS3_IOS
\t\t\t\t\tconst u64 wait_begin = utils::get_tsc();
#endif
\t\t\t\t\tget_range_lock_bits(true).wait(bits, atomic_wait_timeout{50'000});
#ifdef RPCS3_IOS
\t\t\t\t\tconst u64 wait_end = utils::get_tsc();
\t\t\t\t\trpcs3::ios::record_range_lock_wait(wait_end >= wait_begin ? wait_end - wait_begin : 0);
#endif
\t\t\t\t}
"""
    path.write_text(replace_once(text, old, new, "range lock timing"))


def patch_performance_impl(source: Path) -> None:
    path = source / "rpcs3/ios/RPCS3IOSPerformance.cpp"
    text = path.read_text()
    if MARKER in text:
        return

    include_anchor = """#include "util/cpu_stats.hpp"
#include "util/sysinfo.hpp"
"""
    include_replacement = f"""#include "util/cpu_stats.hpp"
#include "util/logs.hpp"
#include "util/sysinfo.hpp"
#include "util/tsc.hpp"

// {MARKER}
"""
    text = replace_once(text, include_anchor, include_replacement, "profiler utility includes")
    text = replace_once(
        text,
        """#include <algorithm>
#include <atomic>
#include <chrono>
#include <mutex>
""",
        """#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string_view>
#include <thread>
#include <vector>
""",
        "profiler standard includes",
    )
    text = replace_once(
        text,
        """#ifdef __APPLE__
#include <mach/mach.h>
#endif
""",
        """#ifdef __APPLE__
#include <mach/mach.h>
#endif
""",
        "profiler Apple includes",
    )
    text = replace_once(
        text,
        """namespace
{
using sample_clock = std::chrono::steady_clock;
""",
        """LOG_CHANNEL(ios_core_profiler, "iOS Core Profiler");

namespace
{
using sample_clock = std::chrono::steady_clock;
constexpr usz frame_ring_size = 2048;
constexpr auto thread_sample_period = std::chrono::milliseconds(500);
constexpr auto report_period = std::chrono::seconds(5);

enum class core_group : u8
{
\tppu,
\tspu,
\trsx,
\tjit,
\tother,
\tcount
};

constexpr usz core_group_count = static_cast<usz>(core_group::count);

struct thread_usage_sample
{
\tstd::array<double, core_group_count> cores{};
\tstd::array<u32, core_group_count> threads{};
};

core_group classify_thread(std::string_view name)
{
\tif (name.starts_with("PPUW.") || name.starts_with("PPU Exec") ||
\t\tname.starts_with("PPU Symbol") || name.starts_with("SPUW.") ||
\t\tname.starts_with("SPU Worker") || name.starts_with("SPU LLVM") ||
\t\tname.starts_with("RSX.W"))
\t{
\t\treturn core_group::jit;
\t}
\tif (name.starts_with("PPU["))
\t{
\t\treturn core_group::ppu;
\t}
\tif (name.starts_with("SPU") || name.starts_with("RawSPU"))
\t{
\t\treturn core_group::spu;
\t}
\tif (name.starts_with("RSX"))
\t{
\t\treturn core_group::rsx;
\t}
\treturn core_group::other;
}

thread_usage_sample sample_core_threads()
{
\tthread_usage_sample result;
#ifdef __APPLE__
\tthread_act_array_t threads = nullptr;
\tmach_msg_type_number_t thread_count = 0;
\tif (task_threads(mach_task_self(), &threads, &thread_count) != KERN_SUCCESS)
\t{
\t\treturn result;
\t}

\tfor (mach_msg_type_number_t index = 0; index < thread_count; ++index)
\t{
\t\tthread_extended_info_data_t info{};
\t\tmach_msg_type_number_t count = THREAD_EXTENDED_INFO_COUNT;
\t\tif (thread_info(threads[index], THREAD_EXTENDED_INFO,
\t\t\treinterpret_cast<thread_info_t>(&info), &count) != KERN_SUCCESS)
\t\t{
\t\t\tmach_port_deallocate(mach_task_self(), threads[index]);
\t\t\tcontinue;
\t\t}

\t\tconst usz group = static_cast<usz>(classify_thread(info.pth_name));
\t\tresult.threads[group]++;
\t\tif (!(info.pth_flags & TH_FLAGS_IDLE))
\t\t{
\t\t\tresult.cores[group] += static_cast<double>(info.pth_cpu_usage) / TH_USAGE_SCALE;
\t\t}
\t\tmach_port_deallocate(mach_task_self(), threads[index]);
\t}

\tvm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(threads),
\t\tstatic_cast<vm_size_t>(thread_count) * sizeof(thread_t));
#endif
\treturn result;
}
""",
        "profiler namespace prelude",
    )

    class_start = text.index("class performance_registry final")
    class_end_marker = "\nperformance_registry g_performance_registry;\n"
    class_end = text.index(class_end_marker, class_start)
    new_class = r'''class performance_registry final
{
public:
	~performance_registry()
	{
		{
			std::lock_guard lock(m_profile_mutex);
			m_stop_sampler = true;
		}
		m_profile_cv.notify_all();
		if (m_profile_thread.joinable())
		{
			m_profile_thread.join();
		}
	}

	void reset()
	{
		{
			std::lock_guard lock(m_sample_mutex);
			m_presented_frames.store(0, std::memory_order_release);
			m_last_present_tsc.store(0, std::memory_order_relaxed);
			for (auto& interval : m_frame_intervals)
			{
				interval.store(0, std::memory_order_relaxed);
			}
			m_rsx_load = 0;
			m_has_rsx_load = false;
			m_has_fps_baseline = false;
			m_last_frame_count = 0;
			m_last_sample_time = {};
			static_cast<void>(m_cpu_stats.get_usage());
		}

		std::lock_guard profile_lock(m_profile_mutex);
		m_profile_frame_baseline = 0;
		m_usage_samples = 0;
		m_usage_core_sum.fill(0.0);
		m_usage_thread_sum.fill(0);
		m_profile_window_start = sample_clock::now();
		m_next_report = m_profile_window_start + report_period;
		m_pipeline_queued = 0;
		m_pipeline_completed = 0;
		m_pipeline_queue_ticks = 0;
		m_pipeline_compile_ticks = 0;
		m_pipeline_peak_pending = 0;
		m_gpu_fence_waits = 0;
		m_gpu_fence_wait_ticks = 0;
		m_gpu_fence_timeouts = 0;
		m_range_lock_waits = 0;
		m_range_lock_wait_ticks = 0;
		if (!m_profile_thread.joinable())
		{
			m_profile_thread = std::thread([this] { sampler_main(); });
		}
	}

	void record_presented_frame(u32 rsx_load) noexcept
	{
		m_rsx_load.store(std::min(rsx_load, 100u), std::memory_order_relaxed);
		m_has_rsx_load.store(true, std::memory_order_release);

		const u64 now = utils::get_tsc();
		const u64 previous = m_last_present_tsc.exchange(now, std::memory_order_relaxed);
		const u64 frame_index = m_presented_frames.load(std::memory_order_relaxed);
		if (previous && now > previous)
		{
			m_frame_intervals[frame_index % frame_ring_size].store(now - previous, std::memory_order_relaxed);
		}
		m_presented_frames.store(frame_index + 1, std::memory_order_release);
	}

	void record_pipeline_job_queued(u32 pending_jobs) noexcept
	{
		m_pipeline_queued.fetch_add(1, std::memory_order_relaxed);
		u32 peak = m_pipeline_peak_pending.load(std::memory_order_relaxed);
		while (peak < pending_jobs && !m_pipeline_peak_pending.compare_exchange_weak(
			peak, pending_jobs, std::memory_order_relaxed))
		{
		}
	}

	void record_pipeline_job_completed(u64 queue_wait_ticks, u64 compile_ticks) noexcept
	{
		m_pipeline_completed.fetch_add(1, std::memory_order_relaxed);
		m_pipeline_queue_ticks.fetch_add(queue_wait_ticks, std::memory_order_relaxed);
		m_pipeline_compile_ticks.fetch_add(compile_ticks, std::memory_order_relaxed);
	}

	void record_gpu_fence_wait(u64 wait_ticks, bool timed_out) noexcept
	{
		m_gpu_fence_waits.fetch_add(1, std::memory_order_relaxed);
		m_gpu_fence_wait_ticks.fetch_add(wait_ticks, std::memory_order_relaxed);
		if (timed_out)
		{
			m_gpu_fence_timeouts.fetch_add(1, std::memory_order_relaxed);
		}
	}

	void record_range_lock_wait(u64 wait_ticks) noexcept
	{
		m_range_lock_waits.fetch_add(1, std::memory_order_relaxed);
		m_range_lock_wait_ticks.fetch_add(wait_ticks, std::memory_order_relaxed);
	}

	rpcs3_ios_status snapshot(rpcs3_ios_performance_metrics* metrics)
	{
		if (!metrics || metrics->struct_size < sizeof(rpcs3_ios_performance_metrics))
		{
			return RPCS3_IOS_INVALID_ARGUMENT;
		}

		const u64 memory_used = process_memory_footprint();
		const u64 memory_total = utils::get_total_memory();

		std::lock_guard lock(m_sample_mutex);
		const auto now = sample_clock::now();
		const u64 frame_count = m_presented_frames.load(std::memory_order_acquire);
		const bool presented_since_last_sample = !m_has_fps_baseline || frame_count > m_last_frame_count;
		rpcs3_ios_performance_metrics result{};
		result.struct_size = sizeof(result);
		result.cpu_usage_percent = std::clamp(m_cpu_stats.get_usage(), 0.0, 100.0);
		result.valid_fields |= RPCS3_IOS_PERFORMANCE_CPU_VALID;

		if (m_has_fps_baseline)
		{
			const double elapsed = std::chrono::duration<double>(now - m_last_sample_time).count();
			if (elapsed > 0.0 && elapsed <= 2.0 && frame_count >= m_last_frame_count)
			{
				result.frames_per_second = static_cast<double>(frame_count - m_last_frame_count) / elapsed;
				result.valid_fields |= RPCS3_IOS_PERFORMANCE_FPS_VALID;
			}
		}

		m_has_fps_baseline = true;
		m_last_frame_count = frame_count;
		m_last_sample_time = now;

		if (m_has_rsx_load.load(std::memory_order_acquire))
		{
			result.gpu_usage_percent = presented_since_last_sample
				? m_rsx_load.load(std::memory_order_relaxed)
				: 0.0;
			result.valid_fields |= RPCS3_IOS_PERFORMANCE_GPU_VALID;
		}

		if (memory_used && memory_total)
		{
			result.memory_used_bytes = memory_used;
			result.memory_total_bytes = memory_total;
			result.valid_fields |= RPCS3_IOS_PERFORMANCE_MEMORY_VALID;
		}

		*metrics = result;
		return RPCS3_IOS_OK;
	}

private:
	void sampler_main()
	{
		for (;;)
		{
			{
				std::unique_lock lock(m_profile_mutex);
				if (m_profile_cv.wait_for(lock, thread_sample_period, [this] { return m_stop_sampler; }))
				{
					return;
				}
			}

			const u64 frames = m_presented_frames.load(std::memory_order_acquire);
			if (!frames)
			{
				continue;
			}

			const thread_usage_sample usage = sample_core_threads();
			bool report = false;
			{
				std::lock_guard lock(m_profile_mutex);
				for (usz group = 0; group < core_group_count; ++group)
				{
					m_usage_core_sum[group] += usage.cores[group];
					m_usage_thread_sum[group] += usage.threads[group];
				}
				m_usage_samples++;
				report = sample_clock::now() >= m_next_report;
			}

			if (report)
			{
				report_profile_window();
			}
		}
	}

	void report_profile_window()
	{
		const auto now = sample_clock::now();
		const u64 current_frames = m_presented_frames.load(std::memory_order_acquire);
		const u64 frequency = utils::get_tsc_freq();
		std::array<double, core_group_count> average_cores{};
		std::array<double, core_group_count> average_threads{};
		double elapsed_ms = 0.0;
		u64 frame_baseline = 0;

		{
			std::lock_guard lock(m_profile_mutex);
			frame_baseline = m_profile_frame_baseline;
			elapsed_ms = std::chrono::duration<double, std::milli>(now - m_profile_window_start).count();
			if (m_usage_samples)
			{
				for (usz group = 0; group < core_group_count; ++group)
				{
					average_cores[group] = m_usage_core_sum[group] / m_usage_samples;
					average_threads[group] = static_cast<double>(m_usage_thread_sum[group]) / m_usage_samples;
				}
			}
			m_profile_frame_baseline = current_frames;
			m_usage_samples = 0;
			m_usage_core_sum.fill(0.0);
			m_usage_thread_sum.fill(0);
			m_profile_window_start = now;
			m_next_report = now + report_period;
		}

		if (current_frames <= frame_baseline || !frequency)
		{
			return;
		}

		const u64 first = std::max<u64>(1, std::max(frame_baseline, current_frames > frame_ring_size
			? current_frames - frame_ring_size : 1));
		std::vector<u64> intervals;
		intervals.reserve(static_cast<usz>(current_frames - first));
		for (u64 frame = first; frame < current_frames; ++frame)
		{
			if (const u64 ticks = m_frame_intervals[frame % frame_ring_size].load(std::memory_order_relaxed))
			{
				intervals.push_back(ticks);
			}
		}
		if (intervals.empty())
		{
			return;
		}

		u64 interval_sum = 0;
		for (const u64 ticks : intervals)
		{
			interval_sum += ticks;
		}
		std::sort(intervals.begin(), intervals.end());
		const auto percentile_ms = [&](double percentile)
		{
			const usz index = std::min(intervals.size() - 1,
				static_cast<usz>(std::ceil(intervals.size() * percentile)) - 1);
			return static_cast<double>(intervals[index]) * 1000.0 / frequency;
		};
		const usz slow_count = std::max<usz>(1, (intervals.size() + 99) / 100);
		u64 slow_sum = 0;
		for (usz index = intervals.size() - slow_count; index < intervals.size(); ++index)
		{
			slow_sum += intervals[index];
		}

		const double average_fps = static_cast<double>(frequency) * intervals.size() / interval_sum;
		const double low_1_fps = static_cast<double>(frequency) * slow_count / slow_sum;
		const double frametime_ms = static_cast<double>(interval_sum) * 1000.0 / frequency / intervals.size();
		const double frame_count = static_cast<double>(current_frames - frame_baseline);
		const auto group_ms_per_frame = [&](core_group group)
		{
			return average_cores[static_cast<usz>(group)] * elapsed_ms / frame_count;
		};
		const auto ticks_to_ms_per_frame = [&](u64 ticks)
		{
			return static_cast<double>(ticks) * 1000.0 / frequency / frame_count;
		};

		const u64 pipeline_jobs = m_pipeline_completed.exchange(0, std::memory_order_relaxed);
		const u64 pipeline_queue_ticks = m_pipeline_queue_ticks.exchange(0, std::memory_order_relaxed);
		const u64 pipeline_compile_ticks = m_pipeline_compile_ticks.exchange(0, std::memory_order_relaxed);
		const u32 pipeline_peak = m_pipeline_peak_pending.exchange(0, std::memory_order_relaxed);
		static_cast<void>(m_pipeline_queued.exchange(0, std::memory_order_relaxed));
		const u64 fence_stalls = m_gpu_fence_waits.exchange(0, std::memory_order_relaxed);
		const u64 fence_ticks = m_gpu_fence_wait_ticks.exchange(0, std::memory_order_relaxed);
		const u64 fence_timeouts = m_gpu_fence_timeouts.exchange(0, std::memory_order_relaxed);
		const u64 range_stalls = m_range_lock_waits.exchange(0, std::memory_order_relaxed);
		const u64 range_ticks = m_range_lock_wait_ticks.exchange(0, std::memory_order_relaxed);
		const u64 memory_mib = process_memory_footprint() >> 20;
#ifdef RPCS3_IOS
		const u64 headroom_mib = os_proc_available_memory() >> 20;
#else
		const u64 headroom_mib = 0;
#endif

		ios_core_profiler.notice(
			"COREPROF frames=%llu avg_fps=%.3f low1_fps=%.3f frametime_ms=%.3f p95_ms=%.3f p99_ms=%.3f "
			"ppu_ms=%.3f spu_ms=%.3f rsx_ms=%.3f jit_ms=%.3f gpu_time_ms=-1 "
			"gpu_fence_wait_ms=%.3f gpu_fence_stalls=%llu gpu_fence_timeouts=%llu "
			"range_wait_ms=%.3f range_stalls=%llu pipeline_jobs=%llu pipeline_queue_ms=%.3f "
			"pipeline_compile_ms=%.3f pipeline_peak=%u ppu_threads=%.2f spu_threads=%.2f "
			"rsx_threads=%.2f jit_threads=%.2f memory_mib=%llu headroom_mib=%llu",
			current_frames - frame_baseline, average_fps, low_1_fps, frametime_ms,
			percentile_ms(0.95), percentile_ms(0.99),
			group_ms_per_frame(core_group::ppu), group_ms_per_frame(core_group::spu),
			group_ms_per_frame(core_group::rsx), group_ms_per_frame(core_group::jit),
			ticks_to_ms_per_frame(fence_ticks), fence_stalls, fence_timeouts,
			ticks_to_ms_per_frame(range_ticks), range_stalls, pipeline_jobs,
			pipeline_jobs ? static_cast<double>(pipeline_queue_ticks) * 1000.0 / frequency / pipeline_jobs : 0.0,
			pipeline_jobs ? static_cast<double>(pipeline_compile_ticks) * 1000.0 / frequency / pipeline_jobs : 0.0,
			pipeline_peak, average_threads[static_cast<usz>(core_group::ppu)],
			average_threads[static_cast<usz>(core_group::spu)],
			average_threads[static_cast<usz>(core_group::rsx)],
			average_threads[static_cast<usz>(core_group::jit)], memory_mib, headroom_mib);
	}

	std::atomic<u64> m_presented_frames{0};
	std::atomic<u64> m_last_present_tsc{0};
	std::array<std::atomic<u64>, frame_ring_size> m_frame_intervals{};
	std::atomic<u32> m_rsx_load{0};
	std::atomic_bool m_has_rsx_load{false};
	std::mutex m_sample_mutex;
	utils::cpu_stats m_cpu_stats;
	bool m_has_fps_baseline = false;
	u64 m_last_frame_count = 0;
	sample_clock::time_point m_last_sample_time{};

	std::mutex m_profile_mutex;
	std::condition_variable m_profile_cv;
	std::thread m_profile_thread;
	bool m_stop_sampler = false;
	u64 m_profile_frame_baseline = 0;
	u64 m_usage_samples = 0;
	std::array<double, core_group_count> m_usage_core_sum{};
	std::array<u64, core_group_count> m_usage_thread_sum{};
	sample_clock::time_point m_profile_window_start{};
	sample_clock::time_point m_next_report{};

	std::atomic<u64> m_pipeline_queued{0};
	std::atomic<u64> m_pipeline_completed{0};
	std::atomic<u64> m_pipeline_queue_ticks{0};
	std::atomic<u64> m_pipeline_compile_ticks{0};
	std::atomic<u32> m_pipeline_peak_pending{0};
	std::atomic<u64> m_gpu_fence_waits{0};
	std::atomic<u64> m_gpu_fence_wait_ticks{0};
	std::atomic<u64> m_gpu_fence_timeouts{0};
	std::atomic<u64> m_range_lock_waits{0};
	std::atomic<u64> m_range_lock_wait_ticks{0};
};
'''
    text = text[:class_start] + new_class + text[class_end:]

    function_anchor = """void record_presented_frame(u32 rsx_load) noexcept
{
\tg_performance_registry.record_presented_frame(rsx_load);
}
"""
    function_replacement = """void record_presented_frame(u32 rsx_load) noexcept
{
\tg_performance_registry.record_presented_frame(rsx_load);
}

void record_pipeline_job_queued(u32 pending_jobs) noexcept
{
\tg_performance_registry.record_pipeline_job_queued(pending_jobs);
}

void record_pipeline_job_completed(u64 queue_wait_ticks, u64 compile_ticks) noexcept
{
\tg_performance_registry.record_pipeline_job_completed(queue_wait_ticks, compile_ticks);
}

void record_gpu_fence_wait(u64 wait_ticks, bool timed_out) noexcept
{
\tg_performance_registry.record_gpu_fence_wait(wait_ticks, timed_out);
}

void record_range_lock_wait(u64 wait_ticks) noexcept
{
\tg_performance_registry.record_range_lock_wait(wait_ticks);
}
"""
    path.write_text(replace_once(text, function_anchor, function_replacement, "profiler event forwarding"))


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_rpcs3_build258_core_architecture.py <rpcs3-source-root>")
    source = Path(sys.argv[1]).resolve()
    patch_performance_header(source)
    patch_pipeline_compiler(source)
    patch_gpu_fence_wait(source)
    patch_range_lock_wait(source)
    patch_performance_impl(source)
    print("RPCS3 Build 258 core architecture patch: OK")


if __name__ == "__main__":
    main()
