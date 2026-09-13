#!/usr/bin/env python3
"""Contracts for Build 258's diagnostic-driven runtime resilience patch."""

from __future__ import annotations

import sys
from pathlib import Path


MARKER = "NEOSTATION_BUILD258_RUNTIME_RESILIENCE_V1"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(
            "usage: rpcs3_build258_runtime_resilience_test.py <rpcs3-source-root>"
        )
    source = Path(sys.argv[1]).resolve()

    profiler_h = (source / "rpcs3/ios/RPCS3IOSPerformance.h").read_text()
    profiler_cpp = (source / "rpcs3/ios/RPCS3IOSPerformance.cpp").read_text()
    memory_cpp = (
        source / "rpcs3/Emu/RSX/VK/VKResourceManager.cpp"
    ).read_text()
    memory_h = (source / "rpcs3/Emu/RSX/VK/vkutils/memory.h").read_text()
    present_cpp = (source / "rpcs3/Emu/RSX/VK/VKPresent.cpp").read_text()
    semaphore_cpp = (
        source / "rpcs3/Emu/RSX/NV47/HW/nv406e.cpp"
    ).read_text()
    spu_h = (source / "rpcs3/Emu/Cell/SPURecompiler.h").read_text()
    spu_common = (
        source / "rpcs3/Emu/Cell/SPUCommonRecompiler.cpp"
    ).read_text()
    spu_llvm = (source / "rpcs3/Emu/Cell/SPULLVMRecompiler.cpp").read_text()
    ppu = (source / "rpcs3/Emu/Cell/PPUThread.cpp").read_text()
    rsx_cache = (source / "rpcs3/Emu/RSX/rsx_cache.h").read_text()
    vk_renderer = (source / "rpcs3/Emu/RSX/VK/VKGSRender.cpp").read_text()
    config = (source / "rpcs3/Emu/system_config.h").read_text()
    public_abi = (source / "rpcs3/ios/RPCS3IOS.h").read_text()

    for name, text in {
        "profiler header": profiler_h,
        "profiler implementation": profiler_cpp,
        "memory pressure policy": memory_cpp,
        "RSX semaphore": semaphore_cpp,
        "SPU metadata": spu_common,
        "SPU LLVM": spu_llvm,
        "RSX cache": rsx_cache,
    }.items():
        require(MARKER in text, f"{name}: resilience marker is missing")

    require(
        "rsx::problem_severity vmm_check_memory_usage();" in memory_h,
        "memory pressure sampling must return the sampled severity",
    )
    require(
        "next_reclaim" in memory_cpp
        and "last_reclaimed_severity" in memory_cpp
        and "std::chrono::milliseconds(750)" in memory_cpp
        and "std::chrono::milliseconds(1500)" in memory_cpp,
        "moderate memory reclamation lacks cooldown and escalation state",
    )
    require(
        "record_vram_allocation(true, memory_size)" in memory_cpp
        and "record_vram_allocation(false, info.size)" in memory_cpp,
        "Vulkan allocation and free churn is not measured",
    )
    frame_boundary = present_cpp[
        present_cpp.index("void VKGSRender::advance_queued_frames()") :
        present_cpp.index("void VKGSRender::queue_swap_request")
    ]
    require(
        "vmm_determine_memory_load_severity()" not in frame_boundary
        and frame_boundary.count("vmm_check_memory_usage()") == 1
        and "m_rtts.trim(*m_current_command_buffer, memory_pressure)" in frame_boundary,
        "the frame boundary still samples memory pressure more than once",
    )

    semaphore_wait = semaphore_cpp[
        semaphore_cpp.index("void semaphore_acquire") :
        semaphore_cpp.index("void semaphore_release")
    ]
    for field in ("address=0x%X", "expected=0x%X", "observed=0x%X", "waited_us=%llu"):
        require(field in semaphore_wait, f"semaphore telemetry is missing {field}")
    require(
        "record_rsx_semaphore_wait" in semaphore_wait,
        "RSX semaphore waits are not attributed to the profiler",
    )
    require(
        "atomic_sema.store" not in semaphore_wait and "sema = arg" not in semaphore_wait,
        "timeout handling must never forge the guest semaphore",
    )

    require(
        "std::shared_ptr<std::mutex> m_file_mutex" in spu_h,
        "SPU metadata reads and appends are not serialized",
    )
    for token in (
        "maximum_cache_bytes = 128ull * 0x100000",
        "maximum_cache_entries = 65'536",
        "calculate_crc16",
        "m_file.trunc(valid_end)",
        "m_file.trunc(original_size)",
        "record_spu_metadata_cache_load",
        "record_spu_metadata_write",
        "CACHEPROF domain=spu_metadata",
    ):
        require(token in spu_common, f"SPU metadata hardening is missing: {token}")
    require(
        "current <= 8 || (current % 256) == 0" in spu_common
        and "current <= 8 || (current % 256) == 0" in spu_llvm,
        "repetitive SPU diagnostics are not sampled",
    )
    require(
        "record_spu_block_compiled" in spu_llvm
        and "utils::get_tsc() - compile_started" in spu_llvm
        and "add_loc->compiled = fn;" in spu_llvm,
        "successful SPU compilations are not counted and timed",
    )
    require(
        "ARM64 objects embed process-specific host addresses" in spu_llvm,
        "unsafe cross-process ARM64 SPU machine objects were re-enabled",
    )

    for token in (
        "fs::pending_file pending{path}",
        "maximum_raw_shader_size = 0x100000",
        "f.read(&pdata, sizeof(pdata)) != sizeof(pdata)",
        "const bool vp_valid = !vp.data.empty()",
        "m_storage.get_hash(vp) == data.vertex_program_hash",
        "const bool fp_valid = fp.ucode_length",
        "m_storage.get_hash(fp) == data.fragment_program_hash",
    ):
        require(token in rsx_cache, f"RSX persistent cache validation is missing: {token}")
    require(
        rsx_cache.count("write_atomically(") >= 4,
        "raw shaders and pipeline records are not all written atomically",
    )
    require(
        "record_ppu_cache_lookup(cache_hit)" in ppu
        and "record_rsx_shader_cache_lookup(!cache_missed)" in vk_renderer,
        "PPU/RSX cache hit-rate instrumentation is incomplete",
    )

    for field in (
        "memory_reclaims=",
        "memory_reclaim_effective=",
        "memory_reclaim_deferred=",
        "vram_allocations=",
        "vram_allocation_mib=",
        "rsx_semaphore_wait_ms=",
        "rsx_semaphore_timeouts=",
        "ppu_cache_hits=",
        "spu_compiles=",
        "spu_compile_ms=",
        "spu_metadata_rejected=",
        "shader_cache_hits=",
    ):
        require(field in profiler_cpp, f"COREPROF_RESILIENCE is missing: {field}")
    require(
        "COREPROF_RESILIENCE" in profiler_cpp
        and "record_spu_metadata_write" in profiler_h
        and "record_vram_allocation" in memory_cpp,
        "resilience metrics are not exposed through the internal profiler",
    )
    profile_window = profiler_cpp[
        profiler_cpp.index("void report_profile_window()") :
        profiler_cpp.index(
            "std::atomic<u64> m_presented_frames",
            profiler_cpp.index("void report_profile_window()"),
        )
    ]
    require(
        profile_window.index("COREPROF_RESILIENCE")
        < profile_window.index(
            "if (current_frames <= frame_baseline || !frequency)"
        ),
        "resilience telemetry disappears when presentation has stalled",
    )

    ios_defaults = config[
        config.index("NEOSTATION_IOS_PERSISTENT_CACHE_BUDGET_V1") :
        config.index("#else", config.index("NEOSTATION_IOS_PERSISTENT_CACHE_BUDGET_V1"))
    ]
    require(
        '"Limit disk cache size", true' in ios_defaults
        and '"Disk cache maximum size (MB)", 4096' in ios_defaults,
        "the iOS persistent cache does not have a bounded default budget",
    )

    require(MARKER not in public_abi, "the stable RPCS3 iOS ABI changed")
    print("RPCS3 Build 258 runtime resilience contract: OK")


if __name__ == "__main__":
    main()
