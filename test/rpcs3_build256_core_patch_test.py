#!/usr/bin/env python3
"""Contract checks for Build 256's native savestate changes."""

from pathlib import Path
import sys


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: rpcs3_build256_core_patch_test.py <rpcs3-source-root>")
    source = Path(sys.argv[1]).resolve()
    system = (source / "rpcs3/Emu/System.cpp").read_text()
    api = (source / "rpcs3/ios/RPCS3IOS.cpp").read_text()
    status = (source / "rpcs3/ios/NeoStationSavestateStatus.h").read_text()
    exports = (source / "rpcs3/ios/RPCS3IOS.exports").read_text().splitlines()
    utils = (source / "rpcs3/Emu/savestate_utils.cpp").read_text()

    require(system.count("NEOSTATION_SAVESTATE_SLOTS_V2") == 2,
            "slot/preflight/relocation native markers are incomplete")
    require("check_if_vdec_contexts_exist()" in system and
            system.index("check_if_vdec_contexts_exist()") < system.index("try_lock_spu_threads_in_a_state_compatible_with_savestates"),
            "VDEC must be rejected before SPU quiescence")
    require('fmt::format("%s_1_%u.SAVESTAT.zst", m_title_id, slot - 1)' in system,
            "ten stable slot filenames are missing")
    require("if (neostation::savestate::current.read().slot == 0)" in system,
            "numbered slots must bypass the legacy rolling deletion limit")
    require("Relocating savestate disc source" in system and
            "m_games_config.get_path(m_title_id)" in system,
            "legacy iOS container paths are not remapped through Game ID")
    require("m_title_id.empty() ? iso_dev->get_loaded_iso() : m_title_id" in system,
            "new ISO savestates must serialize a relocatable Game ID")
    require("std::uint32_t slot" in status and "slot > 10" in status,
            "native operation state does not enforce slots 1..10")
    require("neostation_rpcs3_ios_save_state_slot(uint32_t slot)" in api,
            "numbered native save entry point is missing")
    require(exports.count("_neostation_rpcs3_ios_save_state_slot") == 1,
            "numbered native save symbol must be exported exactly once")
    require("void clean_orphaned_savestate_temps()" in utils and
            'entry.name.ends_with(".tmp")' in utils,
            "ARMSX3 orphaned temporary-state cleanup is missing")
    print("RPCS3 Build 256 native savestate patch contract: OK")


if __name__ == "__main__":
    main()
