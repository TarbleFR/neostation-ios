#!/usr/bin/env python3
"""Harden the pinned RPCS3 iOS runtime using evidence from Build 258 logs.

The patch is deliberately applied after ``patch_rpcs3_build258_core_architecture``.
It keeps guest-visible synchronization semantics intact while reducing repeated
moderate-pressure cache churn, repairing persistent SPU metadata, making RSX
cache writes atomic, and extending the out-of-band profiler.
"""

from __future__ import annotations

import sys
from pathlib import Path


MARKER = "NEOSTATION_BUILD258_RUNTIME_RESILIENCE_V1"


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"{description}: expected one source anchor, found {count}"
        )
    return text.replace(old, new, 1)


def patch_performance_profiler(source: Path) -> None:
    header = source / "rpcs3/ios/RPCS3IOSPerformance.h"
    text = header.read_text()
    if MARKER not in text:
        anchor = "void record_range_lock_wait(u64 wait_ticks) noexcept;\n"
        addition = f"""void record_range_lock_wait(u64 wait_ticks) noexcept;

// {MARKER}: counters are atomic and allocation-free so cache/JIT/RSX hot paths
// can attribute stutter without writing one diagnostic line per event.
void record_memory_pressure_reclaim(u32 severity, bool attempted, bool relieved) noexcept;
void record_vram_allocation(bool allocated, u64 bytes) noexcept;
void record_rsx_semaphore_wait(u64 wait_microseconds, bool timed_out) noexcept;
void record_ppu_cache_lookup(bool hit) noexcept;
void record_spu_block_compiled(u32 guest_code_bytes, u64 compile_ticks) noexcept;
void record_spu_metadata_write() noexcept;
void record_spu_metadata_cache_load(u32 loaded, u32 rejected, u64 repaired_bytes) noexcept;
void record_spu_compile_diagnostic() noexcept;
void record_rsx_shader_cache_lookup(bool hit) noexcept;
"""
        header.write_text(
            replace_once(text, anchor, addition, "performance profiler API")
        )

    impl = source / "rpcs3/ios/RPCS3IOSPerformance.cpp"
    text = impl.read_text()
    if MARKER in text:
        return

    text = replace_once(
        text,
        "// NEOSTATION_BUILD258_CORE_ARCHITECTURE_V1\n",
        "// NEOSTATION_BUILD258_CORE_ARCHITECTURE_V1\n"
        f"// {MARKER}\n",
        "performance profiler marker",
    )

    reset_anchor = """\t\tm_range_lock_waits = 0;
\t\tm_range_lock_wait_ticks = 0;
"""
    reset_patch = """\t\tm_range_lock_waits = 0;
\t\tm_range_lock_wait_ticks = 0;
\t\tm_memory_reclaim_attempts = 0;
\t\tm_memory_reclaim_effective = 0;
\t\tm_memory_reclaim_deferred = 0;
\t\tm_memory_pressure_peak = 0;
\t\tm_vram_allocations = 0;
\t\tm_vram_frees = 0;
\t\tm_vram_allocation_bytes = 0;
\t\tm_rsx_semaphore_waits = 0;
\t\tm_rsx_semaphore_wait_us = 0;
\t\tm_rsx_semaphore_timeouts = 0;
\t\tm_ppu_cache_hits = 0;
\t\tm_ppu_cache_misses = 0;
\t\tm_spu_blocks_compiled = 0;
\t\tm_spu_compiled_bytes = 0;
\t\tm_spu_compile_ticks = 0;
\t\tm_spu_metadata_writes = 0;
\t\tm_spu_metadata_loaded = 0;
\t\tm_spu_metadata_rejected = 0;
\t\tm_spu_metadata_repaired_bytes = 0;
\t\tm_spu_compile_diagnostics = 0;
\t\tm_rsx_shader_cache_hits = 0;
\t\tm_rsx_shader_cache_misses = 0;
"""
    text = replace_once(text, reset_anchor, reset_patch, "profiler reset counters")

    method_anchor = """\tvoid record_range_lock_wait(u64 wait_ticks) noexcept
\t{
\t\tm_range_lock_waits.fetch_add(1, std::memory_order_relaxed);
\t\tm_range_lock_wait_ticks.fetch_add(wait_ticks, std::memory_order_relaxed);
\t}

\trpcs3_ios_status snapshot(rpcs3_ios_performance_metrics* metrics)
"""
    method_patch = """\tvoid record_range_lock_wait(u64 wait_ticks) noexcept
\t{
\t\tm_range_lock_waits.fetch_add(1, std::memory_order_relaxed);
\t\tm_range_lock_wait_ticks.fetch_add(wait_ticks, std::memory_order_relaxed);
\t}

\tvoid record_memory_pressure_reclaim(u32 severity, bool attempted, bool relieved) noexcept
\t{
\t\tif (attempted)
\t\t{
\t\t\tm_memory_reclaim_attempts.fetch_add(1, std::memory_order_relaxed);
\t\t\tif (relieved)
\t\t\t{
\t\t\t\tm_memory_reclaim_effective.fetch_add(1, std::memory_order_relaxed);
\t\t\t}
\t\t}
\t\telse
\t\t{
\t\t\tm_memory_reclaim_deferred.fetch_add(1, std::memory_order_relaxed);
\t\t}

\t\tu32 peak = m_memory_pressure_peak.load(std::memory_order_relaxed);
\t\twhile (peak < severity && !m_memory_pressure_peak.compare_exchange_weak(
\t\t\tpeak, severity, std::memory_order_relaxed))
\t\t{
\t\t}
\t}

\tvoid record_rsx_semaphore_wait(u64 wait_microseconds, bool timed_out) noexcept
\t{
\t\tm_rsx_semaphore_waits.fetch_add(1, std::memory_order_relaxed);
\t\tm_rsx_semaphore_wait_us.fetch_add(wait_microseconds, std::memory_order_relaxed);
\t\tif (timed_out)
\t\t{
\t\t\tm_rsx_semaphore_timeouts.fetch_add(1, std::memory_order_relaxed);
\t\t}
\t}

\tvoid record_vram_allocation(bool allocated, u64 bytes) noexcept
\t{
\t\t(allocated ? m_vram_allocations : m_vram_frees).fetch_add(1, std::memory_order_relaxed);
\t\tif (allocated)
\t\t{
\t\t\tm_vram_allocation_bytes.fetch_add(bytes, std::memory_order_relaxed);
\t\t}
\t}

\tvoid record_ppu_cache_lookup(bool hit) noexcept
\t{
\t\t(hit ? m_ppu_cache_hits : m_ppu_cache_misses).fetch_add(1, std::memory_order_relaxed);
\t}

\tvoid record_spu_block_compiled(u32 guest_code_bytes, u64 compile_ticks) noexcept
\t{
\t\tm_spu_blocks_compiled.fetch_add(1, std::memory_order_relaxed);
\t\tm_spu_compiled_bytes.fetch_add(guest_code_bytes, std::memory_order_relaxed);
\t\tm_spu_compile_ticks.fetch_add(compile_ticks, std::memory_order_relaxed);
\t}

\tvoid record_spu_metadata_write() noexcept
\t{
\t\tm_spu_metadata_writes.fetch_add(1, std::memory_order_relaxed);
\t}

\tvoid record_spu_metadata_cache_load(u32 loaded, u32 rejected, u64 repaired_bytes) noexcept
\t{
\t\tm_spu_metadata_loaded.fetch_add(loaded, std::memory_order_relaxed);
\t\tm_spu_metadata_rejected.fetch_add(rejected, std::memory_order_relaxed);
\t\tm_spu_metadata_repaired_bytes.fetch_add(repaired_bytes, std::memory_order_relaxed);
\t}

\tvoid record_spu_compile_diagnostic() noexcept
\t{
\t\tm_spu_compile_diagnostics.fetch_add(1, std::memory_order_relaxed);
\t}

\tvoid record_rsx_shader_cache_lookup(bool hit) noexcept
\t{
\t\t(hit ? m_rsx_shader_cache_hits : m_rsx_shader_cache_misses).fetch_add(1, std::memory_order_relaxed);
\t}

\trpcs3_ios_status snapshot(rpcs3_ios_performance_metrics* metrics)
"""
    text = replace_once(text, method_anchor, method_patch, "profiler event methods")

    log_anchor = """\t\tif (current_frames <= frame_baseline || !frequency)
\t\t{
\t\t\treturn;
\t\t}

\t\tconst u64 first = std::max<u64>(1, std::max(frame_baseline, current_frames > frame_ring_size
"""
    counter_block = """\t\tconst u64 memory_reclaims = m_memory_reclaim_attempts.exchange(0, std::memory_order_relaxed);
\t\tconst u64 memory_reclaim_effective = m_memory_reclaim_effective.exchange(0, std::memory_order_relaxed);
\t\tconst u64 memory_reclaim_deferred = m_memory_reclaim_deferred.exchange(0, std::memory_order_relaxed);
\t\tconst u32 memory_pressure_peak = m_memory_pressure_peak.exchange(0, std::memory_order_relaxed);
\t\tconst u64 vram_allocations = m_vram_allocations.exchange(0, std::memory_order_relaxed);
\t\tconst u64 vram_frees = m_vram_frees.exchange(0, std::memory_order_relaxed);
\t\tconst u64 vram_allocation_bytes = m_vram_allocation_bytes.exchange(0, std::memory_order_relaxed);
\t\tconst u64 semaphore_stalls = m_rsx_semaphore_waits.exchange(0, std::memory_order_relaxed);
\t\tconst u64 semaphore_wait_us = m_rsx_semaphore_wait_us.exchange(0, std::memory_order_relaxed);
\t\tconst u64 semaphore_timeouts = m_rsx_semaphore_timeouts.exchange(0, std::memory_order_relaxed);
\t\tconst u64 ppu_cache_hits = m_ppu_cache_hits.exchange(0, std::memory_order_relaxed);
\t\tconst u64 ppu_cache_misses = m_ppu_cache_misses.exchange(0, std::memory_order_relaxed);
\t\tconst u64 spu_compiles = m_spu_blocks_compiled.exchange(0, std::memory_order_relaxed);
\t\tconst u64 spu_compiled_bytes = m_spu_compiled_bytes.exchange(0, std::memory_order_relaxed);
\t\tconst u64 spu_compile_ticks = m_spu_compile_ticks.exchange(0, std::memory_order_relaxed);
\t\tconst u64 spu_metadata_writes = m_spu_metadata_writes.exchange(0, std::memory_order_relaxed);
\t\tconst u64 spu_metadata_loaded = m_spu_metadata_loaded.exchange(0, std::memory_order_relaxed);
\t\tconst u64 spu_metadata_rejected = m_spu_metadata_rejected.exchange(0, std::memory_order_relaxed);
\t\tconst u64 spu_metadata_repaired_bytes = m_spu_metadata_repaired_bytes.exchange(0, std::memory_order_relaxed);
\t\tconst u64 spu_diagnostics = m_spu_compile_diagnostics.exchange(0, std::memory_order_relaxed);
\t\tconst u64 shader_cache_hits = m_rsx_shader_cache_hits.exchange(0, std::memory_order_relaxed);
\t\tconst u64 shader_cache_misses = m_rsx_shader_cache_misses.exchange(0, std::memory_order_relaxed);

\t\tios_core_profiler.notice(
\t\t\t\"COREPROF_RESILIENCE memory_reclaims=%llu memory_reclaim_effective=%llu \"
\t\t\t\"memory_reclaim_deferred=%llu memory_pressure_peak=%u vram_allocations=%llu \"
\t\t\t\"vram_frees=%llu vram_allocation_mib=%.3f rsx_semaphore_wait_ms=%.3f \"
\t\t\t\"rsx_semaphore_stalls=%llu rsx_semaphore_timeouts=%llu ppu_cache_hits=%llu \"
\t\t\t\"ppu_cache_misses=%llu spu_compiles=%llu spu_compile_kib=%.3f spu_compile_ms=%.3f \"
\t\t\t\"spu_metadata_writes=%llu spu_metadata_loaded=%llu spu_metadata_rejected=%llu \"
\t\t\t\"spu_metadata_repaired_bytes=%llu spu_diagnostics=%llu shader_cache_hits=%llu \"
\t\t\t\"shader_cache_misses=%llu\",
\t\t\tmemory_reclaims, memory_reclaim_effective, memory_reclaim_deferred, memory_pressure_peak,
\t\t\tvram_allocations, vram_frees, static_cast<double>(vram_allocation_bytes) / 0x100000,
\t\t\tstatic_cast<double>(semaphore_wait_us) / 1000.0, semaphore_stalls, semaphore_timeouts,
\t\t\tppu_cache_hits, ppu_cache_misses, spu_compiles, static_cast<double>(spu_compiled_bytes) / 1024.0,
\t\t\tfrequency ? static_cast<double>(spu_compile_ticks) * 1000.0 / frequency : 0.0,
\t\t\tspu_metadata_writes, spu_metadata_loaded, spu_metadata_rejected, spu_metadata_repaired_bytes,
\t\t\tspu_diagnostics, shader_cache_hits, shader_cache_misses);

\t\tif (current_frames <= frame_baseline || !frequency)
\t\t{
\t\t\treturn;
\t\t}

\t\tconst u64 first = std::max<u64>(1, std::max(frame_baseline, current_frames > frame_ring_size
"""
    text = replace_once(
        text,
        log_anchor,
        counter_block,
        "frame-independent resilience profile snapshot",
    )

    member_anchor = """\tstd::atomic<u64> m_range_lock_waits{0};
\tstd::atomic<u64> m_range_lock_wait_ticks{0};
};
"""
    member_patch = """\tstd::atomic<u64> m_range_lock_waits{0};
\tstd::atomic<u64> m_range_lock_wait_ticks{0};
\tstd::atomic<u64> m_memory_reclaim_attempts{0};
\tstd::atomic<u64> m_memory_reclaim_effective{0};
\tstd::atomic<u64> m_memory_reclaim_deferred{0};
\tstd::atomic<u32> m_memory_pressure_peak{0};
\tstd::atomic<u64> m_vram_allocations{0};
\tstd::atomic<u64> m_vram_frees{0};
\tstd::atomic<u64> m_vram_allocation_bytes{0};
\tstd::atomic<u64> m_rsx_semaphore_waits{0};
\tstd::atomic<u64> m_rsx_semaphore_wait_us{0};
\tstd::atomic<u64> m_rsx_semaphore_timeouts{0};
\tstd::atomic<u64> m_ppu_cache_hits{0};
\tstd::atomic<u64> m_ppu_cache_misses{0};
\tstd::atomic<u64> m_spu_blocks_compiled{0};
\tstd::atomic<u64> m_spu_compiled_bytes{0};
\tstd::atomic<u64> m_spu_compile_ticks{0};
\tstd::atomic<u64> m_spu_metadata_writes{0};
\tstd::atomic<u64> m_spu_metadata_loaded{0};
\tstd::atomic<u64> m_spu_metadata_rejected{0};
\tstd::atomic<u64> m_spu_metadata_repaired_bytes{0};
\tstd::atomic<u64> m_spu_compile_diagnostics{0};
\tstd::atomic<u64> m_rsx_shader_cache_hits{0};
\tstd::atomic<u64> m_rsx_shader_cache_misses{0};
};
"""
    text = replace_once(text, member_anchor, member_patch, "profiler counter members")

    wrapper_anchor = """void record_range_lock_wait(u64 wait_ticks) noexcept
{
\tg_performance_registry.record_range_lock_wait(wait_ticks);
}

u64 available_process_memory_headroom() noexcept
"""
    wrapper_patch = """void record_range_lock_wait(u64 wait_ticks) noexcept
{
\tg_performance_registry.record_range_lock_wait(wait_ticks);
}

void record_memory_pressure_reclaim(u32 severity, bool attempted, bool relieved) noexcept
{
\tg_performance_registry.record_memory_pressure_reclaim(severity, attempted, relieved);
}

void record_vram_allocation(bool allocated, u64 bytes) noexcept
{
\tg_performance_registry.record_vram_allocation(allocated, bytes);
}

void record_rsx_semaphore_wait(u64 wait_microseconds, bool timed_out) noexcept
{
\tg_performance_registry.record_rsx_semaphore_wait(wait_microseconds, timed_out);
}

void record_ppu_cache_lookup(bool hit) noexcept
{
\tg_performance_registry.record_ppu_cache_lookup(hit);
}

void record_spu_block_compiled(u32 guest_code_bytes, u64 compile_ticks) noexcept
{
\tg_performance_registry.record_spu_block_compiled(guest_code_bytes, compile_ticks);
}

void record_spu_metadata_write() noexcept
{
\tg_performance_registry.record_spu_metadata_write();
}

void record_spu_metadata_cache_load(u32 loaded, u32 rejected, u64 repaired_bytes) noexcept
{
\tg_performance_registry.record_spu_metadata_cache_load(loaded, rejected, repaired_bytes);
}

void record_spu_compile_diagnostic() noexcept
{
\tg_performance_registry.record_spu_compile_diagnostic();
}

void record_rsx_shader_cache_lookup(bool hit) noexcept
{
\tg_performance_registry.record_rsx_shader_cache_lookup(hit);
}

u64 available_process_memory_headroom() noexcept
"""
    impl.write_text(
        replace_once(text, wrapper_anchor, wrapper_patch, "profiler API wrappers")
    )


def patch_memory_pressure(source: Path) -> None:
    path = source / "rpcs3/Emu/RSX/VK/VKResourceManager.cpp"
    text = path.read_text()
    if MARKER not in text:
        state_anchor = """\t\tstd::chrono::steady_clock::time_point next_report{};
\t} g_ios_process_memory_pressure;
"""
        state_patch = f"""\t\tstd::chrono::steady_clock::time_point next_report{{}};
\t\t// {MARKER}: expensive cache eviction is scheduled independently from the
\t\t// cheap per-frame severity sample. Escalation always bypasses the cooldown.
\t\tstd::chrono::steady_clock::time_point next_reclaim{{}};
\t\trsx::problem_severity last_reclaimed_severity = rsx::problem_severity::low;
\t}} g_ios_process_memory_pressure;
"""
        text = replace_once(text, state_anchor, state_patch, "memory pressure state")

        old_check = """\tvoid vmm_check_memory_usage()
\t{
\t\tif (const auto load_severity = vmm_determine_memory_load_severity();
\t\t\tload_severity >= rsx::problem_severity::moderate)
\t\t{
\t\t\tvmm_handle_memory_pressure(load_severity);
\t\t}
\t}
"""
        new_check = """\trsx::problem_severity vmm_check_memory_usage()
\t{
\t\tconst auto load_severity = vmm_determine_memory_load_severity();
\t\tif (load_severity < rsx::problem_severity::moderate)
\t\t{
#ifdef RPCS3_IOS
\t\t\tg_ios_process_memory_pressure.next_reclaim = {};
\t\t\tg_ios_process_memory_pressure.last_reclaimed_severity = rsx::problem_severity::low;
#endif
\t\t\treturn load_severity;
\t\t}

#ifdef RPCS3_IOS
\t\tconst auto now = std::chrono::steady_clock::now();
\t\tconst bool escalated = load_severity > g_ios_process_memory_pressure.last_reclaimed_severity;
\t\tif (!escalated && now < g_ios_process_memory_pressure.next_reclaim)
\t\t{
\t\t\trpcs3::ios::record_memory_pressure_reclaim(static_cast<u32>(load_severity), false, false);
\t\t\treturn load_severity;
\t\t}

\t\tconst bool relieved = vmm_handle_memory_pressure(load_severity);
\t\trpcs3::ios::record_memory_pressure_reclaim(static_cast<u32>(load_severity), true, relieved);
\t\tg_ios_process_memory_pressure.last_reclaimed_severity = load_severity;

\t\t// Moderate pressure in the diagnostic lasted for more than a minute. The
\t\t// old per-frame call repeatedly destroyed reusable textures and surfaces,
\t\t// immediately forcing them to be allocated and compiled again. Fatal
\t\t// pressure remains immediate; severe pressure stays responsive; a no-op
\t\t// moderate pass backs off because repeating it cannot release more memory.
\t\tif (load_severity >= rsx::problem_severity::fatal)
\t\t{
\t\t\tg_ios_process_memory_pressure.next_reclaim = now;
\t\t}
\t\telse if (load_severity >= rsx::problem_severity::severe)
\t\t{
\t\t\tg_ios_process_memory_pressure.next_reclaim = now + std::chrono::milliseconds(125);
\t\t}
\t\telse
\t\t{
\t\t\tg_ios_process_memory_pressure.next_reclaim = now +
\t\t\t\t(relieved ? std::chrono::milliseconds(750) : std::chrono::milliseconds(1500));
\t\t}
#else
\t\tvmm_handle_memory_pressure(load_severity);
#endif
\t\treturn load_severity;
\t}
"""
        text = replace_once(
            text,
            old_check,
            new_check,
            "memory pressure cadence",
        )
        text = replace_once(
            text,
            "\t\tg_vmm_stats.pool_usage[pool] += memory_size;\n",
            "\t\tg_vmm_stats.pool_usage[pool] += memory_size;\n"
            "#ifdef RPCS3_IOS\n"
            "\t\trpcs3::ios::record_vram_allocation(true, memory_size);\n"
            "#endif\n",
            "Vulkan allocation counter",
        )
        text = replace_once(
            text,
            "\t\t\tconst auto& info = found->second;\n"
            "\t\t\tg_vmm_stats.memory_usage[info.type_index] -= info.size;\n",
            "\t\t\tconst auto& info = found->second;\n"
            "#ifdef RPCS3_IOS\n"
            "\t\t\trpcs3::ios::record_vram_allocation(false, info.size);\n"
            "#endif\n"
            "\t\t\tg_vmm_stats.memory_usage[info.type_index] -= info.size;\n",
            "Vulkan free counter",
        )
        path.write_text(text)

    header = source / "rpcs3/Emu/RSX/VK/vkutils/memory.h"
    text = header.read_text()
    if "rsx::problem_severity vmm_check_memory_usage();" not in text:
        header.write_text(
            replace_once(
                text,
                "\tvoid vmm_check_memory_usage();\n",
                "\trsx::problem_severity vmm_check_memory_usage();\n",
                "memory pressure return type",
            )
        )

    present = source / "rpcs3/Emu/RSX/VK/VKPresent.cpp"
    text = present.read_text()
    if "const auto memory_pressure = vk::vmm_check_memory_usage();" not in text:
        old = """\tm_device->rebalance_memory_type_usage();
\tvk::vmm_check_memory_usage();

\t// m_rtts storage is double buffered and should be safe to tag on frame boundary
\tm_rtts.trim(*m_current_command_buffer, vk::vmm_determine_memory_load_severity());
"""
        new = """\tm_device->rebalance_memory_type_usage();
\tconst auto memory_pressure = vk::vmm_check_memory_usage();

\t// Reuse the sampled severity. The old path queried process and Vulkan
\t// memory twice per frame and could observe two different hysteresis states.
\tm_rtts.trim(*m_current_command_buffer, memory_pressure);
"""
        present.write_text(
            replace_once(text, old, new, "single frame memory pressure sample")
        )


def patch_rsx_semaphore(source: Path) -> None:
    path = source / "rpcs3/Emu/RSX/NV47/HW/nv406e.cpp"
    text = path.read_text()
    if MARKER in text:
        return
    include_anchor = '#include "Emu/RSX/RSXThread.h"\n'
    include_patch = f"""#include "Emu/RSX/RSXThread.h"

#ifdef RPCS3_IOS
#include "ios/RPCS3IOSPerformance.h"
#endif

// {MARKER}
"""
    text = replace_once(text, include_anchor, include_patch, "semaphore profiler include")
    text = replace_once(
        text,
        "\t\t\tu64 start = get_system_time();\n\t\t\tu64 last_check_val = start;\n",
        "\t\t\tu64 start = get_system_time();\n"
        "\t\t\tu64 last_check_val = start;\n"
        "\t\t\tbool timed_out = false;\n",
        "semaphore timeout state",
    )
    old_timeout = """\t\t\t\t\tif ((current - start) > tdr)
\t\t\t\t\t{
\t\t\t\t\t\t// If longer than driver timeout force exit
\t\t\t\t\t\trsx_log.error("nv406e::semaphore_acquire has timed out. semaphore_address=0x%X", addr);
\t\t\t\t\t\tbreak;
\t\t\t\t\t}
"""
    new_timeout = """\t\t\t\t\tif ((current - start) > tdr)
\t\t\t\t\t{
\t\t\t\t\t\t// Keep RPCS3's recovery semantics: report the stale label and
\t\t\t\t\t\t// leave the wait after the configured deadline. Never forge the
\t\t\t\t\t\t// guest semaphore value to hide the synchronization fault.
\t\t\t\t\t\ttimed_out = true;
\t\t\t\t\t\trsx_log.error(
\t\t\t\t\t\t\t"nv406e::semaphore_acquire timed out: address=0x%X expected=0x%X observed=0x%X waited_us=%llu",
\t\t\t\t\t\t\taddr, arg, static_cast<u32>(sema), current - start);
\t\t\t\t\t\tbreak;
\t\t\t\t\t}
"""
    text = replace_once(text, old_timeout, new_timeout, "semaphore timeout telemetry")
    wait_end = """\t\t\tRSX(ctx)->fifo_wake_delay();
\t\t\tRSX(ctx)->performance_counters.idle_time += (get_system_time() - start);
"""
    wait_end_patch = """\t\t\tconst u64 waited = get_system_time() - start;
#ifdef RPCS3_IOS
\t\t\trpcs3::ios::record_rsx_semaphore_wait(waited, timed_out);
#endif
\t\t\tRSX(ctx)->fifo_wake_delay();
\t\t\tRSX(ctx)->performance_counters.idle_time += waited;
"""
    path.write_text(
        replace_once(text, wait_end, wait_end_patch, "semaphore wait counter")
    )


def patch_ppu_cache_metrics(source: Path) -> None:
    path = source / "rpcs3/Emu/Cell/PPUThread.cpp"
    text = path.read_text()
    if "record_ppu_cache_lookup(cache_hit)" in text:
        return
    old = """\t\t// Check object file
\t\tif (jit_compiler::check(cache_path + obj_name))
\t\t{
"""
    new = """\t\t// Check object file. PPU objects are relocatable, versioned by
\t\t// code/settings/CPU and validated by LLVM before they are reused.
\t\tconst bool cache_hit = jit_compiler::check(cache_path + obj_name);
#ifdef RPCS3_IOS
\t\trpcs3::ios::record_ppu_cache_lookup(cache_hit);
#endif
\t\tif (cache_hit)
\t\t{
"""
    path.write_text(replace_once(text, old, new, "PPU cache metric"))


def patch_spu_metadata_cache(source: Path) -> None:
    header = source / "rpcs3/Emu/Cell/SPURecompiler.h"
    text = header.read_text()
    if "m_file_mutex" not in text:
        text = replace_once(
            text,
            "\tfs::file m_file;\n",
            "\tfs::file m_file;\n"
            "\tstd::shared_ptr<std::mutex> m_file_mutex = std::make_shared<std::mutex>();\n"
            "\tbool m_limit_reported = false;\n",
            "SPU cache mutex",
        )
        text = replace_once(
            text,
            "#include <memory>\n",
            "#include <memory>\n#include <mutex>\n",
            "SPU cache mutex include",
        )
        header.write_text(text)

    path = source / "rpcs3/Emu/Cell/SPUCommonRecompiler.cpp"
    text = path.read_text()
    if MARKER in text:
        return

    old_get_start = text.index("std::deque<spu_program> spu_cache::get()")
    old_add_start = text.index("void spu_cache::add(const spu_program& func)", old_get_start)
    old_init_start = text.index("void spu_cache::initialize(bool build_existing_cache)", old_add_start)
    new_cache_functions = f"""std::deque<spu_program> spu_cache::get()
{{
\t// {MARKER}: append-only metadata survives termination. Serialize readers
\t// and writers, validate every record and remove an incomplete tail before
\t// any later compilation appends behind it.
\tstd::lock_guard lock{{*m_file_mutex}};
\tstd::deque<spu_program> result;

\tif (!m_file)
\t{{
\t\treturn result;
\t}}

\tconstexpr u64 maximum_cache_bytes = 128ull * 0x100000;
\tconstexpr u32 maximum_cache_entries = 65'536;
\tconst u64 original_size = m_file.size();
\tconst u64 readable_size = std::min(original_size, maximum_cache_bytes);
\tu64 valid_end = 0;
\tu32 rejected = 0;
\tu32 entries = 0;
\tbool damaged_tail = original_size > maximum_cache_bytes;

\tm_file.seek(0);
\twhile (m_file.pos() < readable_size && entries < maximum_cache_entries)
\t{{
\t\tstruct block_info_t
\t\t{{
\t\t\tbe_t<u16> crc;
\t\t\tbe_t<u16> size;
\t\t\tbe_t<u32> addr;
\t\t}} block_info{{}};

\t\tconst u64 entry_start = m_file.pos();
\t\tif (readable_size - entry_start < sizeof(block_info) || !m_file.read(block_info))
\t\t{{
\t\t\tdamaged_tail = true;
\t\t\tbreak;
\t\t}}

\t\tconst u32 crc = block_info.crc;
\t\tconst u32 size = block_info.size;
\t\tconst u32 addr = block_info.addr;
\t\tentries++;
\t\tconst u64 payload_bytes = static_cast<u64>(size) * sizeof(u32);
\t\tif (utils::add_saturate<u32>(addr, size * 4) > SPU_LS_SIZE ||
\t\t\tpayload_bytes > readable_size - m_file.pos())
\t\t{{
\t\t\trejected++;
\t\t\tdamaged_tail = true;
\t\t\tbreak;
\t\t}}

\t\tstd::vector<u32> func;
\t\tif (!m_file.read(func, size))
\t\t{{
\t\t\trejected++;
\t\t\tdamaged_tail = true;
\t\t\tbreak;
\t\t}}
\t\tvalid_end = m_file.pos();

\t\tif (!size || !func[0])
\t\t{{
\t\t\t// Old-format Giga entries have known boundaries and can be skipped.
\t\t\trejected++;
\t\t\tcontinue;
\t\t}}

\t\tif (crc && std::max<u32>(calculate_crc16(
\t\t\treinterpret_cast<const uchar*>(func.data()), size * 4), 1) != crc)
\t\t{{
\t\t\trejected++;
\t\t\tcontinue;
\t\t}}

\t\tspu_program res;
\t\tres.entry_point = addr;
\t\tres.lower_bound = addr;
\t\tres.data = std::move(func);
\t\tresult.emplace_front(std::move(res));
\t}}

\tif (entries >= maximum_cache_entries && m_file.pos() < original_size)
\t{{
\t\tdamaged_tail = true;
\t}}

\tu64 repaired_bytes = 0;
\tif (damaged_tail && valid_end < original_size)
\t{{
\t\trepaired_bytes = original_size - valid_end;
\t\tif (!m_file.trunc(valid_end))
\t\t{{
\t\t\tspu_log.error("SPU metadata cache tail could not be repaired (%s)", fs::g_tls_error);
\t\t\trepaired_bytes = 0;
\t\t}}
\t\telse
\t\t{{
\t\t\tspu_log.warning("SPU metadata cache repaired: removed %llu invalid byte(s)", repaired_bytes);
\t\t}}
\t}}
\tm_file.seek(0, fs::seek_end);

#ifdef RPCS3_IOS
\trpcs3::ios::record_spu_metadata_cache_load(::narrow<u32>(result.size()), rejected, repaired_bytes);
\tspu_log.notice(
\t\t"CACHEPROF domain=spu_metadata loaded=%u rejected=%u repaired_bytes=%llu size_bytes=%llu limit_bytes=%llu",
\t\t::narrow<u32>(result.size()), rejected, repaired_bytes, m_file.size(), maximum_cache_bytes);
#endif
\treturn result;
}}

void spu_cache::add(const spu_program& func)
{{
\tstd::lock_guard lock{{*m_file_mutex}};
\tif (!m_file)
\t{{
\t\treturn;
\t}}

\tbe_t<u32> size = ::size32(func.data);
\tbe_t<u32> addr = func.entry_point;
\tsize |= std::max<u32>(calculate_crc16(
\t\treinterpret_cast<const uchar*>(func.data.data()), size * 4), 1) << 16;

\tconst fs::iovec_clone gather[3]
\t{{
\t\t{{&size, sizeof(size)}},
\t\t{{&addr, sizeof(addr)}},
\t\t{{func.data.data(), func.data.size() * 4}}
\t}};
\tconst u64 write_size = sizeof(size) + sizeof(addr) + func.data.size() * 4;
\tconstexpr u64 maximum_cache_bytes = 128ull * 0x100000;
\tconst u64 original_size = m_file.size();
\tif (write_size > maximum_cache_bytes - std::min(original_size, maximum_cache_bytes))
\t{{
\t\tif (!m_limit_reported)
\t\t{{
\t\t\tm_limit_reported = true;
\t\t\tspu_log.warning("SPU metadata cache reached its 128 MiB per-title limit; new blocks remain usable in memory");
\t\t}}
\t\treturn;
\t}}

\tif (m_file.write_gather(gather, 3) != write_size)
\t{{
\t\t// A failed gathered write must not poison the append point for every
\t\t// future launch. Roll back the partial record immediately.
\t\tm_file.trunc(original_size);
\t\tm_file.seek(0, fs::seek_end);
\t\tspu_log.error("SPU metadata cache append failed and was rolled back (%s)", fs::g_tls_error);
\t}}
#ifdef RPCS3_IOS
\telse
\t{{
\t\trpcs3::ios::record_spu_metadata_write();
\t}}
#endif
}}

"""
    text = text[:old_get_start] + new_cache_functions + text[old_init_start:]
    path.write_text(text)


def patch_spu_compile_metrics_and_log_sampling(source: Path) -> None:
    path = source / "rpcs3/Emu/Cell/SPULLVMRecompiler.cpp"
    text = path.read_text()
    if MARKER in text:
        return

    include_anchor = '#include "Emu/RSX/Core/RSXReservationLock.hpp"\n'
    include_patch = f"""#include "Emu/RSX/Core/RSXReservationLock.hpp"
#ifdef RPCS3_IOS
#include "ios/RPCS3IOSPerformance.h"
#include "util/tsc.hpp"
#endif
// {MARKER}
"""
    text = replace_once(text, include_anchor, include_patch, "SPU profiler include")

    llvm_anchor = "#ifdef LLVM_AVAILABLE\n\n"
    helper = """#ifdef LLVM_AVAILABLE

#ifdef RPCS3_IOS
namespace
{
bool should_emit_spu_compile_diagnostic() noexcept
{
\tstatic atomic_t<u64> diagnostic_count{0};
\tconst u64 current = ++diagnostic_count;
\trpcs3::ios::record_spu_compile_diagnostic();
\treturn current <= 8 || (current % 256) == 0;
}
}
#endif

"""
    text = replace_once(text, llvm_anchor, helper, "SPU diagnostic sampler")

    metric_anchor = """\t\tif (auto& cache = g_fxo->get<spu_cache>(); cache && g_cfg.core.spu_cache && !add_loc->cached.exchange(1))
\t\t{
\t\t\tadd_to_file = true;
\t\t}

\t\t{
"""
    metric_patch = """#ifdef RPCS3_IOS
\t\tconst u64 compile_started = utils::get_tsc();
#endif

\t\tif (auto& cache = g_fxo->get<spu_cache>(); cache && g_cfg.core.spu_cache && !add_loc->cached.exchange(1))
\t\t{
\t\t\tadd_to_file = true;
\t\t}
\t\t{
"""
    text = replace_once(text, metric_anchor, metric_patch, "SPU compilation counter")

    compile_success_anchor = """\t\t// Install unconditionally, possibly replacing existing one from spu_fast
\t\tadd_loc->compiled = fn;
"""
    compile_success_patch = """\t\t// Install unconditionally, possibly replacing existing one from spu_fast
\t\tadd_loc->compiled = fn;
#ifdef RPCS3_IOS
\t\trpcs3::ios::record_spu_block_compiled(
\t\t\t::narrow<u32>(func_size * sizeof(u32)), utils::get_tsc() - compile_started);
#endif
"""
    text = replace_once(
        text,
        compile_success_anchor,
        compile_success_patch,
        "successful SPU compilation counter",
    )

    diagnostics = [
        'spu_log.todo("[%s:0x%05x] Unmatched spu_re(a) found in FMA", m_hash, m_pos);',
        'spu_log.todo("[%s:0x%05x] Unmatched spu_re(b) found in FMA", m_hash, m_pos);',
        'spu_log.todo("[%s:0x%05x] Unmatched spu_rsqrte(c) found in FMA", m_hash, m_pos);',
    ]
    for index, line in enumerate(diagnostics):
        wrapped = f"""#ifdef RPCS3_IOS
\t\t\tif (should_emit_spu_compile_diagnostic())
\t\t\t{{
\t\t\t\t{line}
\t\t\t}}
#else
\t\t\t{line}
#endif"""
        text = replace_once(text, "\t\t\t" + line, wrapped, f"SPU FMA diagnostic {index}")
    path.write_text(text)

    common = source / "rpcs3/Emu/Cell/SPUCommonRecompiler.cpp"
    text = common.read_text()
    if "should_emit_spu_branch_diagnostic" in text:
        return
    helper_anchor = "const extern spu_decoder<spu_iflag> g_spu_iflag;\n\n"
    helper_patch = """const extern spu_decoder<spu_iflag> g_spu_iflag;

#ifdef RPCS3_IOS
namespace
{
bool should_emit_spu_branch_diagnostic() noexcept
{
\tstatic atomic_t<u64> diagnostic_count{0};
\tconst u64 current = ++diagnostic_count;
\trpcs3::ios::record_spu_compile_diagnostic();
\treturn current <= 8 || (current % 256) == 0;
}
}
#endif

"""
    text = replace_once(text, helper_anchor, helper_patch, "SPU branch sampler")
    warning = '\t\t\t\tspu_log.warning("[0x%x] At 0x%x: indirect branch to 0x%x%s", entry_point, pos, target, op.d ? " (D)" : op.e ? " (E)" : "");'
    warning_patch = """#ifdef RPCS3_IOS
\t\t\t\tif (should_emit_spu_branch_diagnostic())
\t\t\t\t{
\t\t\t\t\tspu_log.warning("[0x%x] At 0x%x: indirect branch to 0x%x%s", entry_point, pos, target, op.d ? " (D)" : op.e ? " (E)" : "");
\t\t\t\t}
#else
\t\t\t\tspu_log.warning("[0x%x] At 0x%x: indirect branch to 0x%x%s", entry_point, pos, target, op.d ? " (D)" : op.e ? " (E)" : "");
#endif"""
    common.write_text(
        replace_once(text, warning, warning_patch, "SPU indirect branch sampling")
    )


def patch_rsx_shader_cache(source: Path) -> None:
    path = source / "rpcs3/Emu/RSX/rsx_cache.h"
    text = path.read_text()
    if MARKER in text:
        return

    member_anchor = """\t\tbackend_storage& m_storage;

\t\tstatic std::string get_message(u32 index, u32 processed, u32 entry_count)
"""
    member_patch = f"""\t\tbackend_storage& m_storage;

\t\t// {MARKER}: a killed iOS process must leave either the old complete
\t\t// cache entry or the new complete entry, never a zero-byte destination.
\t\tstatic constexpr u64 maximum_raw_shader_size = 0x100000;

\t\tstatic bool write_atomically(const std::string& path, const void* data, usz size)
\t\t{{
\t\t\tif (!size)
\t\t\t{{
\t\t\t\treturn false;
\t\t\t}}
\t\t\tfs::pending_file pending{{path}};
\t\t\treturn pending.file && pending.file.write(data, size) == size && pending.commit();
\t\t}}

\t\tstatic std::string get_message(u32 index, u32 processed, u32 entry_count)
"""
    text = replace_once(text, member_anchor, member_patch, "atomic RSX cache helper")

    pipeline_read = """\t\t\t\t\tpipeline_data pdata{};
\t\t\t\t\tf.read(&pdata, f.size());

\t\t\t\t\tauto entry = unpack(pdata);
"""
    pipeline_read_patch = """\t\t\t\t\tpipeline_data pdata{};
\t\t\t\t\tif (f.read(&pdata, sizeof(pdata)) != sizeof(pdata))
\t\t\t\t\t{
\t\t\t\t\t\trsx_log.error("Removing truncated cached pipeline object %s", tmp.name.c_str());
\t\t\t\t\t\tf.close();
\t\t\t\t\t\tfs::remove_file(filename);
\t\t\t\t\t\tcontinue;
\t\t\t\t\t}

\t\t\t\t\tauto entry = unpack(pdata);
"""
    text = replace_once(text, pipeline_read, pipeline_read_patch, "pipeline read validation")

    old_writes = """\t\t\t// Writeback to cache either if file does not exist or it is invalid (unexpected size)
\t\t\t// Note: fs::write_file is not atomic, if the process is terminated in the middle an empty file is created
\t\t\tif (fs::stat_t s{}; !fs::get_stat(fp_name, s) || s.size != fp.ucode_length)
\t\t\t{
\t\t\t\tfs::write_file(fp_name, fs::rewrite, fp.get_data(), fp.ucode_length);
\t\t\t}

\t\t\tif (fs::stat_t s{}; !fs::get_stat(vp_name, s) || s.size != vp.data.size() * sizeof(u32))
\t\t\t{
\t\t\t\tfs::write_file(vp_name, fs::rewrite, vp.data);
\t\t\t}
"""
    new_writes = """\t\t\t// Replace invalid or absent raw programs atomically. Do not publish the
\t\t\t// pipeline record unless both referenced payloads are durable.
\t\t\tif (fs::stat_t s{}; !fs::get_stat(fp_name, s) || s.size != fp.ucode_length)
\t\t\t{
\t\t\t\tif (!write_atomically(fp_name, fp.get_data(), fp.ucode_length))
\t\t\t\t{
\t\t\t\t\trsx_log.error("Failed to save fragment shader cache entry atomically");
\t\t\t\t\treturn;
\t\t\t\t}
\t\t\t}

\t\t\tif (fs::stat_t s{}; !fs::get_stat(vp_name, s) || s.size != vp.data.size() * sizeof(u32))
\t\t\t{
\t\t\t\tif (!write_atomically(vp_name, vp.data.data(), vp.data.size() * sizeof(u32)))
\t\t\t\t{
\t\t\t\t\trsx_log.error("Failed to save vertex shader cache entry atomically");
\t\t\t\t\treturn;
\t\t\t\t}
\t\t\t}
"""
    text = replace_once(text, old_writes, new_writes, "raw shader atomic writes")
    text = replace_once(
        text,
        "\t\t\tfs::write_file(pipeline_path, fs::rewrite, &data, sizeof(data));\n",
        "\t\t\tif (!write_atomically(pipeline_path, &data, sizeof(data)))\n"
        "\t\t\t{\n"
        "\t\t\t\trsx_log.error(\"Failed to save pipeline cache entry atomically\");\n"
        "\t\t\t}\n",
        "pipeline atomic write",
    )

    old_vp = """\t\tRSXVertexProgram load_vp_raw(u64 program_hash) const
\t\t{
\t\t\tRSXVertexProgram vp = {};

\t\t\tfs::file f(fmt::format("%s/raw/%llX.vp", root_path, program_hash));
\t\t\tif (f) f.read(vp.data, f.size() / sizeof(u32));

\t\t\treturn vp;
\t\t}
"""
    new_vp = """\t\tRSXVertexProgram load_vp_raw(u64 program_hash) const
\t\t{
\t\t\tRSXVertexProgram vp = {};
\t\t\tconst std::string path = fmt::format("%s/raw/%llX.vp", root_path, program_hash);
\t\t\tfs::file f(path);
\t\t\tif (!f)
\t\t\t{
\t\t\t\treturn vp;
\t\t\t}
\t\t\tconst u64 size = f.size();
\t\t\tif (!size || size > maximum_raw_shader_size || size % sizeof(u32))
\t\t\t{
\t\t\t\tf.close();
\t\t\t\tfs::remove_file(path);
\t\t\t\treturn vp;
\t\t\t}
\t\t\tif (!f.read(vp.data, size / sizeof(u32)))
\t\t\t{
\t\t\t\tvp.data.clear();
\t\t\t\tf.close();
\t\t\t\tfs::remove_file(path);
\t\t\t}
\t\t\treturn vp;
\t\t}
"""
    text = replace_once(text, old_vp, new_vp, "vertex shader validation")

    old_fp = """\t\t\tconst u32 size = fp.ucode_length = f ? ::size32(f) : 0;

\t\t\tif (!size)
\t\t\t{
\t\t\t\treturn fp;
\t\t\t}

\t\t\tauto buf = std::make_unique<u8[]>(size);
\t\t\tfp.data = buf.get();
\t\t\tf.read(buf.get(), size);
\t\t\tfragment_program_data[fragment_program_data.push_begin()] = std::move(buf);
"""
    new_fp = """\t\t\tconst std::string path = fmt::format("%s/raw/%llX.fp", root_path, program_hash);
\t\t\tconst u64 file_size = f ? f.size() : 0;
\t\t\tif (!file_size || file_size > maximum_raw_shader_size)
\t\t\t{
\t\t\t\tif (f)
\t\t\t\t{
\t\t\t\t\tf.close();
\t\t\t\t\tfs::remove_file(path);
\t\t\t\t}
\t\t\t\treturn fp;
\t\t\t}

\t\t\tconst u32 size = fp.ucode_length = ::narrow<u32>(file_size);
\t\t\tauto buf = std::make_unique<u8[]>(size);
\t\t\tif (f.read(buf.get(), size) != size)
\t\t\t{
\t\t\t\tfp.ucode_length = 0;
\t\t\t\tf.close();
\t\t\t\tfs::remove_file(path);
\t\t\t\treturn fp;
\t\t\t}
\t\t\tfp.data = buf.get();
\t\t\tfragment_program_data[fragment_program_data.push_begin()] = std::move(buf);
"""
    text = replace_once(text, old_fp, new_fp, "fragment shader validation")

    hash_anchor = """\t\t\tfp.mrt_buffers_count = data.fp_mrt_count;

\t\t\treturn result;
"""
    hash_patch = """\t\t\tfp.mrt_buffers_count = data.fp_mrt_count;

\t\t\tconst bool vp_valid = !vp.data.empty() &&
\t\t\t\tm_storage.get_hash(vp) == data.vertex_program_hash;
\t\t\tconst bool fp_valid = fp.ucode_length &&
\t\t\t\tm_storage.get_hash(fp) == data.fragment_program_hash;
\t\t\tif (!vp_valid || !fp_valid)
\t\t\t{
\t\t\t\trsx_log.error("Discarding shader cache pipeline with mismatched raw-program hash");
\t\t\t\tif (!vp_valid)
\t\t\t\t{
\t\t\t\t\tfs::remove_file(fmt::format("%s/raw/%llX.vp", root_path, data.vertex_program_hash));
\t\t\t\t\tvp.data.clear();
\t\t\t\t}
\t\t\t\tif (!fp_valid)
\t\t\t\t{
\t\t\t\t\tfs::remove_file(fmt::format("%s/raw/%llX.fp", root_path, data.fragment_program_hash));
\t\t\t\t\tfp.ucode_length = 0;
\t\t\t\t}
\t\t\t}

\t\t\treturn result;
"""
    path.write_text(replace_once(text, hash_anchor, hash_patch, "raw shader hash validation"))


def patch_rsx_shader_metrics(source: Path) -> None:
    path = source / "rpcs3/Emu/RSX/VK/VKGSRender.cpp"
    text = path.read_text()
    if "record_rsx_shader_cache_lookup" in text:
        return
    include_anchor = '#include "Emu/Memory/vm_locking.h"\n'
    include_patch = """#include "Emu/Memory/vm_locking.h"
#ifdef RPCS3_IOS
#include "ios/RPCS3IOSPerformance.h"
#endif
"""
    text = replace_once(text, include_anchor, include_patch, "RSX cache metric include")
    old = """\t\tif (m_prog_buffer->check_cache_missed())
\t\t{
"""
    new = """\t\tconst bool cache_missed = m_prog_buffer->check_cache_missed();
#ifdef RPCS3_IOS
\t\trpcs3::ios::record_rsx_shader_cache_lookup(!cache_missed);
#endif
\t\tif (cache_missed)
\t\t{
"""
    path.write_text(replace_once(text, old, new, "RSX shader cache metric"))


def patch_ios_cache_defaults(source: Path) -> None:
    path = source / "rpcs3/Emu/system_config.h"
    text = path.read_text()
    if "NEOSTATION_IOS_PERSISTENT_CACHE_BUDGET_V1" in text:
        return
    old = """\t\tcfg::_bool limit_cache_size{ this, "Limit disk cache size", false };
\t\tcfg::_int<0, 10240> cache_max_size{ this, "Disk cache maximum size (MB)", 5120 };
"""
    new = """#ifdef RPCS3_IOS
\t\t// NEOSTATION_IOS_PERSISTENT_CACHE_BUDGET_V1: persistent per-title PPU,
\t\t// SPU and RSX caches remain enabled, while oldest title directories are
\t\t// pruned only after the shared cache exceeds a bounded 4 GiB budget.
\t\tcfg::_bool limit_cache_size{ this, "Limit disk cache size", true };
\t\tcfg::_int<0, 10240> cache_max_size{ this, "Disk cache maximum size (MB)", 4096 };
#else
\t\tcfg::_bool limit_cache_size{ this, "Limit disk cache size", false };
\t\tcfg::_int<0, 10240> cache_max_size{ this, "Disk cache maximum size (MB)", 5120 };
#endif
"""
    path.write_text(replace_once(text, old, new, "iOS cache budget defaults"))


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(
            "usage: patch_rpcs3_build258_runtime_resilience.py <rpcs3-source-root>"
        )
    source = Path(sys.argv[1]).resolve()
    patch_performance_profiler(source)
    patch_memory_pressure(source)
    patch_rsx_semaphore(source)
    patch_ppu_cache_metrics(source)
    patch_spu_metadata_cache(source)
    patch_spu_compile_metrics_and_log_sampling(source)
    patch_rsx_shader_cache(source)
    patch_rsx_shader_metrics(source)
    patch_ios_cache_defaults(source)
    print("RPCS3 Build 258 runtime resilience patch: OK")


if __name__ == "__main__":
    main()
