#!/usr/bin/env python3
"""Contract checks for the audited ARMSX3-derived RPCS3 changes."""

from __future__ import annotations

import sys
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: rpcs3_armsx3_performance_patch_test.py <rpcs3-source-root>")
    source = Path(sys.argv[1]).resolve()
    spu = (source / "rpcs3/Emu/Cell/SPUThread.cpp").read_text()
    vm = (source / "rpcs3/Emu/Memory/vm.cpp").read_text()

    require(spu.count("NEOSTATION_ARMSX3_NEON_RESERVATION_COPY_V1") == 2,
            "both 128-byte reservation copies must use the ARM64 NEON path")
    require(spu.count("#elif defined(ARCH_ARM64)") >= 2,
            "ARM64 reservation copy branches are missing")
    require(spu.count("vld1q_u8(src + 0x70)") == 2,
            "each reservation copy must load all eight 16-byte vectors")
    require(spu.count("vst1q_u8(dst + 0x70, v7)") == 2,
            "each reservation copy must store all eight 16-byte vectors")
    require("const u64 left = (g_range_lock_bits[1] &=" in spu,
            "range-lock clear transition is not observed")
    require(spu.count("g_range_lock_bits[1].notify_all();") == 2,
            "range-lock waiters are not notified by both release paths")
    require("NEOSTATION_ARMSX3_RANGE_LOCK_WAIT_V1" in vm,
            "range-lock wait marker is missing")
    require("atomic_wait_timeout{50'000}" in vm,
            "range-lock wait lost its timeout safety net")
    require("std::this_thread::yield();" not in vm[vm.index("void passive_lock"):vm.index("bool temporary_unlock")],
            "passive range-lock path still yields blindly")
    print("RPCS3 ARMSX3-derived performance patch contract: OK")


if __name__ == "__main__":
    main()
