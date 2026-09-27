#!/usr/bin/env python3
"""Contracts for the Build 352 bounded God of War III memory policy."""

from pathlib import Path
import sys


GOW3_SERIALS = {
    "BCES00510", "BCES00799", "BCUS98111",
    "BCJS37001", "BCAS25003", "BCKS15003",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: rpcs3_build352_gow3_memory_test.py <rpcs3-source-root>")
    source = Path(sys.argv[1])
    read = lambda relative: (source / relative).read_text()

    policy = read("rpcs3/ios/IOSMemoryPressurePolicy.h")
    manager = read("rpcs3/Emu/RSX/VK/VKResourceManager.cpp")

    for serial in GOW3_SERIALS:
        require(serial in policy, f"missing God of War III memory-profile serial: {serial}")

    for token in {
        "high_footprint_headroom_moderate_enter = 2560 * process_memory_mib",
        "high_footprint_headroom_moderate_exit = 2816 * process_memory_mib",
        "is_god_of_war_iii_title",
    }:
        require(token in policy, f"missing proactive memory policy token: {token}")

    require("Emu.GetTitleID()" in manager and
            "g_ios_process_memory_pressure.high_footprint_profile" in manager,
            "the proactive policy is not restricted by the active title")
    require("aggressive_reclaim_interval = std::chrono::seconds(8)" in manager,
            "the stronger cache reclaim is not rate limited")
    require("? rsx::problem_severity::severe" in manager and
            "load_severity == rsx::problem_severity::moderate" in manager,
            "moderate GOW3 pressure does not receive the bounded stronger reclaim")
    require("rsx::problem_severity::fatal" not in
            manager[manager.index("const bool aggressive_reclaim ="):
                    manager.index("const bool relieved =", manager.index("const bool aggressive_reclaim ="))],
            "the proactive path must not invoke fatal GPU drains")
    require("textures %llu MiB, surfaces %llu MiB" in manager,
            "pressure logs do not expose the two dominant Vulkan pools")
    require("std::chrono::milliseconds(1500)" in manager and
            "std::chrono::milliseconds(3000)" in manager,
            "the GOW3 moderate reclaim cooldown does not bound allocation churn")

    # These PS3Native RSX fixes predate the pinned source and must remain in the
    # materialized tree; Build 352 must not regress them while changing policy.
    require("Don't guess when working with main memory" in
            read("rpcs3/Emu/RSX/Common/texture_cache_helpers.h"),
            "PS3Native main-memory blit range fix is missing")
    require("mm_flush_partial" in read("rpcs3/Emu/RSX/Host/MM.cpp"),
            "PS3Native partial host-memory queue flush is missing")

    print("RPCS3 Build 352 God of War III bounded-memory contracts: OK")


if __name__ == "__main__":
    main()
