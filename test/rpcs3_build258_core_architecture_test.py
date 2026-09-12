#!/usr/bin/env python3
"""Contract checks for Build 258's core-only architecture changes."""

from __future__ import annotations

import sys
from pathlib import Path


MARKER = "NEOSTATION_BUILD258_CORE_ARCHITECTURE_V1"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: rpcs3_build258_core_architecture_test.py <rpcs3-source-root>")
    source = Path(sys.argv[1]).resolve()

    pipeline_h = (source / "rpcs3/Emu/RSX/VK/VKPipelineCompiler.h").read_text()
    pipeline_cpp = (source / "rpcs3/Emu/RSX/VK/VKPipelineCompiler.cpp").read_text()
    performance_h = (source / "rpcs3/ios/RPCS3IOSPerformance.h").read_text()
    performance_cpp = (source / "rpcs3/ios/RPCS3IOSPerformance.cpp").read_text()
    sync_cpp = (source / "rpcs3/Emu/RSX/VK/vkutils/sync.cpp").read_text()
    vm_cpp = (source / "rpcs3/Emu/Memory/vm.cpp").read_text()
    public_abi = (source / "rpcs3/ios/RPCS3IOS.h").read_text()

    for name, text in {
        "pipeline header": pipeline_h,
        "pipeline implementation": pipeline_cpp,
        "performance header": performance_h,
        "performance implementation": performance_cpp,
        "Vulkan synchronization": sync_cpp,
        "VM range lock": vm_cpp,
    }.items():
        require(MARKER in text, f"{name}: Build 258 marker is missing")

    require("atomic_t<u32> m_pending_jobs{0};" in pipeline_h,
            "pipeline load must include queued and in-flight work")
    require("u64 queued_tsc = utils::get_tsc();" in pipeline_h,
            "pipeline queue latency timestamp is missing")
    require(pipeline_cpp.count("const u32 pending = ++m_pending_jobs;") == 3,
            "all three asynchronous pipeline entry points must publish their load")
    require("m_pending_jobs--;" in pipeline_cpp,
            "pipeline worker does not retire completed work")
    require("load < best_load" in pipeline_cpp and "best->pending_jobs()" in pipeline_cpp,
            "pipeline dispatcher is not least-loaded")
    require("thread_index % g_num_pipe_compilers" not in pipeline_cpp,
            "blind round-robin pipeline dispatch is still present")

    require("std::thread m_profile_thread;" in performance_cpp,
            "core profiler must run outside the RSX presentation thread")
    require("thread_sample_period = std::chrono::milliseconds(500)" in performance_cpp,
            "thread utilization sampling cadence changed unexpectedly")
    require("std::array<std::atomic<u64>, frame_ring_size>" in performance_cpp,
            "lock-free frame-time ring is missing")
    require("task_threads(mach_task_self()" in performance_cpp,
            "Mach thread accounting is missing")
    require("THREAD_EXTENDED_INFO" in performance_cpp and "pth_name" in performance_cpp,
            "thread names and utilization must come from one Mach snapshot")
    require("pthread_from_mach_thread_np" not in performance_cpp,
            "profiler must not contend on libpthread's global thread-list lock")
    record_frame = performance_cpp[
        performance_cpp.index("void record_presented_frame(u32 rsx_load) noexcept"):
        performance_cpp.index("void record_pipeline_job_queued", performance_cpp.index("void record_presented_frame"))
    ]
    require("task_threads" not in record_frame and "std::lock_guard" not in record_frame,
            "frame hot path must not enumerate threads or take a mutex")

    for field in (
        "avg_fps=", "low1_fps=", "frametime_ms=", "p95_ms=", "p99_ms=",
        "ppu_ms=", "spu_ms=", "rsx_ms=", "jit_ms=", "gpu_time_ms=-1",
        "gpu_fence_wait_ms=", "gpu_fence_stalls=", "range_stalls=",
        "pipeline_queue_ms=", "pipeline_compile_ms=", "pipeline_peak=",
        "ppu_threads=", "spu_threads=", "memory_mib=", "headroom_mib=",
    ):
        require(field in performance_cpp, f"COREPROF metric is missing: {field}")

    require("record_gpu_fence_wait" in sync_cpp and "utils::get_tsc()" in sync_cpp,
            "GPU fence waits are not timed")
    require("record_range_lock_wait" in vm_cpp and "atomic_wait_timeout{50'000}" in vm_cpp,
            "notified range-lock waits are not timed")
    require("record_pipeline_job_completed" in performance_h,
            "pipeline profiling API is missing")

    # Build 258 adds internal hooks only: the stable frontend ABI remains byte-compatible.
    abi_struct = public_abi[
        public_abi.index("typedef struct rpcs3_ios_performance_metrics"):
        public_abi.index("} rpcs3_ios_performance_metrics;")
    ]
    require(abi_struct.count("double ") == 3 and abi_struct.count("uint64_t ") == 2,
            "public performance ABI changed; Build 258 must stay core-only")
    require(MARKER not in public_abi, "Build 258 must not modify the public frontend ABI")

    print("RPCS3 Build 258 core architecture contract: OK")


if __name__ == "__main__":
    main()
