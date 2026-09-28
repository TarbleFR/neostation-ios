#!/usr/bin/env python3
"""Contracts for the Build 351 God of War III CELL-engine pass."""

from pathlib import Path
import sys


GOW3_SERIALS = {
    "BCES00510", "BCES00799", "BCUS98111",
    "BCJS37001", "BCAS25003", "BCKS15003",
}
MLAA_HASHES = {
    "SPU-530c255936b07b25467a58e24ceff5fd4e2960b7",
    "SPU-2239af4827b17317522bd6323c646b45b34ebf14",
}
MLAA_PATCH = {0x5948: 0x40800094, 0x690C: 0x40800027}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def modeled_patch(title_id: str, spu_hash: str, enabled: bool) -> dict[int, int]:
    if not enabled or title_id not in GOW3_SERIALS or spu_hash not in MLAA_HASHES:
        return {}
    return dict(MLAA_PATCH)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: rpcs3_build351_gow3_engine_test.py <rpcs3-source-root>")
    source = Path(sys.argv[1])
    read = lambda relative: (source / relative).read_text()

    spu_llvm = read("rpcs3/Emu/Cell/SPULLVMRecompiler.cpp")
    spu_thread = read("rpcs3/Emu/Cell/SPUThread.cpp")
    sys_spu = read("rpcs3/Emu/Cell/lv2/sys_spu.cpp")
    ppu_module = read("rpcs3/Emu/Cell/PPUModule.cpp")
    policy = read("rpcs3/ios/RPCS3IOSExperimentalPolicy.cpp")
    config = read("rpcs3/Emu/system_config.h")
    settings = read("rpcs3/ios/RPCS3IOSSettings.cpp")

    require("m_test_state->use_empty()" in spu_llvm and
            "m_dispatch->use_empty()" in spu_llvm,
            "unreachable SPU LLVM helpers are not removed")
    helper_cleanup = spu_llvm.index("m_test_state->use_empty()")
    require(helper_cleanup < spu_llvm.index("m_blocks.clear();", helper_cleanup),
            "SPU LLVM helpers must be removed before compiler context cleanup")

    # Build 353 caches spu_accurate_reservations in the local `accurate` flag, while
    # Build 351/352 spelled the same condition directly from g_cfg. Accept both source
    # shapes but keep asserting the protected behavior: the narrow range-lock/CAS path
    # must precede the heavyweight writer lock.
    fast_tokens = (
        "if (!g_cfg.core.spu_accurate_reservations && diff16_pos != umax)",
        "if (!accurate && diff16_pos != umax)",
    )
    fast_token = next((token for token in fast_tokens if token in spu_thread), None)
    require(fast_token is not None, "relaxed PUTLLC fast path is missing")
    fast = spu_thread.index(fast_token)
    heavy = spu_thread.index("vm::writer_lock lock(addr, range_lock);", fast)
    require(fast < heavy and "vm::range_lock<128>(range_lock, addr, 128);" in spu_thread[fast:heavy],
            "relaxed PUTLLC does not take the upstream narrow atomic path")

    for token in GOW3_SERIALS | MLAA_HASHES | {
        "0x00005948", "0x40800094", "0x0000690c", "0x40800027",
    }:
        require(token in sys_spu, f"missing guarded MLAA token: {token}")
    require("get_experimental_policy().gow3_mlaa_bypass" in sys_spu,
            "MLAA engine bypass is not opt-in")
    require("PPU-19724fde16a5b111b7b4d2a065f5dccaf8e01962" in ppu_module and
            "0x0052bf2c" in ppu_module and "0x0023137c" in ppu_module and
            "0x60000000" in ppu_module and
            "_main.get_ref<u32>(address)" in ppu_module and
            "_main.get_ref<be_t<u32>>(address)" not in ppu_module,
            "official God of War III 01.03 PPU MLAA bypass is missing")
    require("get_experimental_policy().gow3_mlaa_bypass" in ppu_module and
            "!ar" in ppu_module,
            "PPU MLAA bypass is not guarded from savestate/disabled paths")
    require("God of War III MLAA Bypass" in config and
            "God of War III MLAA bypass" in settings,
            "MLAA engine policy is not represented in iOS configuration")
    require("resolve_mode(g_cfg.ios_experimental.gow3_mlaa_bypass, false)" in policy,
            "MLAA bypass must remain disabled by default outside a title profile")

    for serial in GOW3_SERIALS:
        for spu_hash in MLAA_HASHES:
            require(modeled_patch(serial, spu_hash, True) == MLAA_PATCH,
                    "supported God of War III module was not patched")
    require(not modeled_patch("BCES00510", next(iter(MLAA_HASHES)), False),
            "disabled policy unexpectedly patches the module")
    require(not modeled_patch("OTHER0001", next(iter(MLAA_HASHES)), True),
            "another title unexpectedly receives the patch")
    require(not modeled_patch("BCES00510", "SPU-" + "0" * 40, True),
            "an unknown SPU module unexpectedly receives the patch")
    print("RPCS3 Build 351 God of War III CELL-engine contracts: OK")


if __name__ == "__main__":
    main()
