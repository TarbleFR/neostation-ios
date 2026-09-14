#!/usr/bin/env python3
"""Contracts for Build 264's God of War ARM64 core changes."""

from __future__ import annotations

import json
import sys
from pathlib import Path


MARKER = "NEOSTATION_BUILD264_GOW3_ARM64_LTO_V1"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def validate_generated_build(build: Path) -> None:
    database = build / "compile_commands.json"
    ninja = build / "build.ninja"
    require(database.is_file(), "CMake did not emit compile_commands.json")
    require(ninja.is_file(), "CMake did not emit build.ninja")

    commands = json.loads(database.read_text())
    for filename in (
        "SPULLVMRecompiler.cpp",
        "nv406e.cpp",
        "RPCS3IOS.cpp",
    ):
        matches = [entry for entry in commands if entry["file"].endswith(filename)]
        require(len(matches) == 1, f"missing unique compile command for {filename}")
        require("-flto=thin" in matches[0]["command"],
                f"selective ThinLTO is missing from {filename}")

    llvm_commands = [
        entry for entry in commands
        if "/3rdparty/llvm/" in entry["file"].replace("\\", "/")
    ]
    require(llvm_commands, "LLVM third-party compile commands were not generated")
    require(all("-flto=thin" not in entry["command"] for entry in llvm_commands),
            "ThinLTO leaked into the bundled LLVM dependency")
    require("-flto=thin" in ninja.read_text(),
            "RPCS3Core final link does not enable ThinLTO")


def main() -> None:
    if len(sys.argv) not in (2, 3):
        raise SystemExit(
            "usage: rpcs3_build264_gow3_core_test.py <rpcs3-source-root> [build-dir]"
        )
    source = Path(sys.argv[1]).resolve()

    semaphore = (source / "rpcs3/Emu/RSX/NV47/HW/nv406e.cpp").read_text()
    root_cmake = (source / "CMakeLists.txt").read_text()
    emu_cmake = (source / "rpcs3/Emu/CMakeLists.txt").read_text()
    core_cmake = (source / "rpcs3/CMakeLists.txt").read_text()
    build_info = (source / "rpcs3/ios/RPCS3IOS.cpp").read_text()
    spu = (source / "rpcs3/Emu/Cell/SPULLVMRecompiler.cpp").read_text()

    require(MARKER in semaphore, "Build 264 RSX marker is missing")
    require("RsxSemaphore observed = atomic_sema.load();" in semaphore,
            "RSX label does not use an acquire atomic load")
    require("progress_started = current;" in semaphore,
            "RSX timeout is not reset when its producer makes progress")
    require("if (!recovery_attempted)" in semaphore,
            "the bounded single RSX recovery phase is missing")
    require("RSX(ctx)->sync();" in semaphore and "RSX(ctx)->flush_fifo();" in semaphore,
            "RSX recovery does not synchronize and expose FIFO progress")
    require("atomic_sema.store" not in semaphore and "observed = arg" not in semaphore,
            "RSX recovery must never forge a guest semaphore value")
    require("get_system_time() - wait_started" in semaphore,
            "RSX telemetry does not measure the complete recovery wait")

    require("RPCS3_IOS_SELECTIVE_THINLTO" in root_cmake,
            "selective ThinLTO CMake option is missing")
    require(MARKER in emu_cmake and "target_compile_options(rpcs3_emu PRIVATE" in emu_cmake,
            "rpcs3_emu is not a selective ThinLTO target")
    require(MARKER in core_cmake and "target_link_options(RPCS3Core PRIVATE" in core_cmake,
            "RPCS3Core is not the ThinLTO final link target")
    require("add_compile_options(-flto" not in root_cmake,
            "ThinLTO must not be enabled globally")
    require(MARKER in build_info and "thin-rpcs3-core-only" in build_info,
            "the embedded Core does not report its ThinLTO policy")
    require("NEOSTATION_ARMSX3_SPU_BYTE_FAST_PATHS_V1" in spu,
            "SPU byte add/sub/compare folds are missing")
    require("NEOSTATION_SPU_ARM64_LOWERING_41F0ECC_V1" in spu,
            "recent ARM64 SPU lowering guards are missing")

    if len(sys.argv) == 3:
        validate_generated_build(Path(sys.argv[2]).resolve())
    print("RPCS3 Build 264 God of War ARM64/ThinLTO contract: OK")


if __name__ == "__main__":
    main()
