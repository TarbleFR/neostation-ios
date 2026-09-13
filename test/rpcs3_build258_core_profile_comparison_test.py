#!/usr/bin/env python3
import importlib.util
import json
import math
from pathlib import Path
import tempfile


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "core_profiles", root / "build-utils/compare_rpcs3_core_profiles.py"
)
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)


def capture(path: Path, fps: float, low: float, wait: float) -> None:
    rows = [
        {"timestamp": 100.0, "stage": "game_boot_begin", "message": "BCUS98111"},
        {"timestamp": 101.0, "stage": "game_boot_return", "message": "BCUS98111 status=0"},
    ]
    for index in range(3):
        message = (
            "[iOS Core Profiler] COREPROF frames=300 "
            f"avg_fps={fps + index:.3f} low1_fps={low + index:.3f} "
            "frametime_ms=20.000 p95_ms=24.000 p99_ms=31.000 "
            "ppu_ms=8.000 spu_ms=25.000 rsx_ms=4.000 jit_ms=1.000 gpu_time_ms=-1 "
            f"gpu_fence_wait_ms={wait:.3f} gpu_fence_stalls=5 gpu_fence_timeouts=0 "
            "range_wait_ms=0.500 range_stalls=3 pipeline_jobs=7 pipeline_queue_ms=2.000 "
            "pipeline_compile_ms=8.000 pipeline_peak=2 ppu_threads=2.00 spu_threads=6.00 "
            "rsx_threads=1.00 jit_threads=2.00 memory_mib=1700 headroom_mib=800"
        )
        rows.append({"timestamp": 102.0 + index * 5, "stage": "core_log", "message": message})
        resilience = (
            "[iOS Core Profiler] COREPROF_RESILIENCE memory_reclaims=1 "
            "memory_reclaim_effective=1 memory_reclaim_deferred=20 memory_pressure_peak=1 "
            "vram_allocations=10 vram_frees=8 vram_allocation_mib=24.500 "
            "rsx_semaphore_wait_ms=0.500 rsx_semaphore_stalls=2 rsx_semaphore_timeouts=0 "
            "ppu_cache_hits=9 ppu_cache_misses=1 spu_compiles=3 spu_compile_kib=12.000 "
            "spu_compile_ms=18.500 "
            "spu_metadata_writes=2 spu_metadata_loaded=4 spu_metadata_rejected=0 "
            "spu_metadata_repaired_bytes=0 spu_diagnostics=5 shader_cache_hits=8 "
            "shader_cache_misses=2"
        )
        rows.append({"timestamp": 102.1 + index * 5, "stage": "core_log", "message": resilience})
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))


with tempfile.TemporaryDirectory() as directory:
    before_path = Path(directory) / "build257.log"
    after_path = Path(directory) / "build258.log"
    capture(before_path, 40.0, 28.0, 2.0)
    capture(after_path, 50.0, 40.0, 0.8)
    before = module.measure(before_path, "bcus98111")
    after = module.measure(after_path, "BCUS98111")
    report = module.comparison(before, after)
    assert after["average_fps"] > before["average_fps"]
    assert after["gpu_fence_wait_ms"] < before["gpu_fence_wait_ms"]
    assert math.isnan(after["gpu_time_ms"])
    assert after["ppu_cache_hit_rate"] == 90.0
    assert after["shader_cache_hit_rate"] == 80.0
    assert after["memory_reclaims"] == 3
    assert after["vram_allocations"] == 30
    assert after["vram_allocation_mib"] == 73.5
    assert after["spu_compile_ms"] == 55.5
    assert "| 1% low FPS |" in report
    assert "Physical GPU / frame (ms) | unavailable" in report
    assert "fence wait is reported" in report
    assert "| PPU cache hit rate (%) |" in report
    assert "| RSX semaphore timeouts |" in report
    assert "| Vulkan allocation traffic (MiB) |" in report
    assert "| SPU compilation time (ms) |" in report
print("RPCS3 Build 258 core profile comparison contract: OK")
