#!/usr/bin/env python3
"""Apply NeoStation-only RPCS3 in-game/session hooks to the pinned iOS core.

The upstream ABI remains version 30.  NeoStation adds private symbols for live
savestate management, hardens savestate SPU image restoration, registers disc
images before boot, and adjusts the iOS RemoteIO underrun tail so a transient
short read cannot turn into a repeated-sample buzz.
"""
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
if not root or not (root / "rpcs3/ios/RPCS3IOS.cpp").exists():
    raise SystemExit("usage: patch_rpcs3_neostation_session.py <rpcs3-source-root>")

cpp = root / "rpcs3/ios/RPCS3IOS.cpp"
exports = root / "rpcs3/ios/RPCS3IOS.exports"
audio = root / "rpcs3/Emu/Audio/IOS/IOSAudioBackend.cpp"
ppu_module = root / "rpcs3/Emu/Cell/PPUModule.cpp"

text = cpp.read_text()
include = '#include "IOSMemoryPressurePolicy.h"\n'
if include not in text:
    marker = '#include "IOSGSFrame.h"\n'
    if marker not in text:
        raise SystemExit("RPCS3IOS.cpp include anchor drifted")
    text = text.replace(marker, marker + include, 1)

marker = 'extern "C" rpcs3_ios_status rpcs3_ios_stop_emulation(void) noexcept\n'
private_api = r'''// NeoStation-private extension: save the live session using the exact RPCS3
// Home Menu path, then restart it without detaching the iOS Metal surface.
// This intentionally does not change RPCS3_IOS_ABI_VERSION.
extern "C" RPCS3_IOS_EXPORT rpcs3_ios_status neostation_rpcs3_ios_save_state(void) noexcept
{
    std::lock_guard lock(g_api_mutex);
    if (g_lifecycle.state() != RPCS3_IOS_STATE_READY ||
        current_emulation_state() != RPCS3_IOS_EMULATION_STATE_RUNNING)
    {
        set_error("A running RPCS3 game is required before creating a savestate");
        return RPCS3_IOS_INVALID_STATE;
    }

    try
    {
        const u64 process_headroom = rpcs3::ios::available_process_memory_headroom();
        if (!rpcs3::ios::has_safe_savestate_headroom(process_headroom))
        {
            set_error(fmt::format(
                "Savestate skipped because iOS process headroom is only %llu MiB",
                process_headroom / rpcs3::ios::process_memory_mib));
            return RPCS3_IOS_SAVESTATE_STORAGE_FAILED;
        }

        emit_log(4, "NeoStation requested an in-game savestate");
        Emu.CallFromMainThread([]()
        {
            Emu.after_kill_callback = []() { Emu.Restart(true, false); };
            Emu.SetContinuousMode(true);
            Emu.Kill(false, true);
        });
        return RPCS3_IOS_OK;
    }
    catch (const std::exception& error)
    {
        set_error(error.what());
    }
    catch (...)
    {
        set_error("Unknown exception while requesting an in-game savestate");
    }
    return RPCS3_IOS_INTERNAL_ERROR;
}

// NeoStation-private read-only enumeration. Upstream's public enumeration is
// deliberately idle-only; this variant is safe for the native in-game picker
// because it only snapshots savestate file metadata and never mutates Emu.
extern "C" RPCS3_IOS_EXPORT rpcs3_ios_status neostation_rpcs3_ios_enumerate_savestates_live(
    const char* title_id,
    rpcs3_ios_savestate_callback callback,
    void* user_context) noexcept
{
    std::lock_guard lock(g_api_mutex);
    if (!title_id || !title_id[0] || !callback)
    {
        set_error("Live savestate enumeration requires a title ID and callback");
        return RPCS3_IOS_INVALID_ARGUMENT;
    }
    if (g_lifecycle.state() != RPCS3_IOS_STATE_READY)
    {
        set_error("RPCS3Core must be ready before enumerating savestates");
        return RPCS3_IOS_INVALID_STATE;
    }

    try
    {
        const auto game = rpcs3::ios::find_installed_game(title_id);
        if (!game)
        {
            set_error(fmt::format("Installed game not found: %s", title_id));
            return RPCS3_IOS_GAME_NOT_FOUND;
        }

        for (const auto& savestate : enumerate_title_savestates(game->title_id, game->path))
        {
            const rpcs3_ios_savestate_info info{
                sizeof(rpcs3_ios_savestate_info),
                savestate.compatible ? 1u : 0u,
                savestate.size,
                savestate.modified_time,
                savestate.identifier.c_str(),
            };
            callback(user_context, &info);
        }
        return RPCS3_IOS_OK;
    }
    catch (const std::exception& error)
    {
        set_error(error.what());
    }
    catch (...)
    {
        set_error("Unknown exception while enumerating live savestates");
    }
    return RPCS3_IOS_INTERNAL_ERROR;
}

'''
if 'neostation_rpcs3_ios_save_state' not in text:
    if marker not in text:
        raise SystemExit("RPCS3IOS.cpp stop-emulation anchor drifted")
    text = text.replace(marker, private_api + marker, 1)

# The iOS library is authoritative and intentionally ignores stale games.yml
# entries. Register its validated disc-image path before every disc boot so
# RPCS3 can resolve /dev_bdvd again during process transitions as well as when
# restoring a savestate. This also replaces an obsolete path for the same ID.
disc_boot_marker = '''\t\tstd::string boot_path = game->path;\n'''
disc_boot_registration = '''\t\t// NeoStation's core-owned library is the source of truth for disc images.\n\t\t// Register the validated path before every boot so RPCS3 can resolve the\n\t\t// disc again across guest process transitions and savestate restoration.\n\t\tif (game->category == "DG")\n\t\t{\n\t\t\tconst game_boot_result registration = Emu.AddGame(game->path);\n\t\t\tif (registration != game_boot_result::no_errors &&\n\t\t\t\tregistration != game_boot_result::already_added)\n\t\t\t{\n\t\t\t\tset_error(fmt::format("Could not register the installed disc source before boot: %s", registration));\n\t\t\t\treturn RPCS3_IOS_BOOT_FAILED;\n\t\t\t}\n\t\t}\n\n\t\tstd::string boot_path = game->path;\n'''
old_savestate_registration = '''\n\t\t\t// Savestates for disc titles store the title ID and restore the\n\t\t\t// current disc source through RPCS3's games configuration. The iOS\n\t\t\t// library is independently core-owned, so make sure its validated\n\t\t\t// path is registered before the savestate reader resolves that ID.\n\t\t\tif (game->category == "DG")\n\t\t\t{\n\t\t\t\tconst game_boot_result registration = Emu.AddGame(game->path);\n\t\t\t\tif (registration != game_boot_result::no_errors &&\n\t\t\t\t\tregistration != game_boot_result::already_added)\n\t\t\t\t{\n\t\t\t\t\tset_error(fmt::format("Could not register the installed disc source before loading a save state: %s", registration));\n\t\t\t\t\treturn RPCS3_IOS_BOOT_FAILED;\n\t\t\t\t}\n\t\t\t}\n'''
if 'source of truth for disc images' not in text:
    if disc_boot_marker not in text or old_savestate_registration not in text:
        raise SystemExit("RPCS3IOS.cpp disc-boot registration anchor drifted")
    text = text.replace(disc_boot_marker, disc_boot_registration, 1)
    text = text.replace(old_savestate_registration, '', 1)
cpp.write_text(text)

exp = exports.read_text()
for symbol in (
    '_neostation_rpcs3_ios_save_state',
    '_neostation_rpcs3_ios_enumerate_savestates_live',
):
    if symbol not in exp.splitlines():
        exp = exp.rstrip() + '\n' + symbol + '\n'
exports.write_text(exp)

a = audio.read_text()
old = '''\tif (written >= bytes_per_frame)\n\t{\n\t\tstd::memcpy(\n\t\t\tbackend->m_last_frame.data(),\n\t\t\toutput + written - bytes_per_frame,\n\t\t\tbytes_per_frame);\n\t}\n\n\tfor (u32 offset = written; offset < requested; offset += bytes_per_frame)\n\t{\n\t\tstd::memcpy(output + offset, backend->m_last_frame.data(), bytes_per_frame);\n\t}\n'''
new = '''\tif (written >= bytes_per_frame)\n\t{\n\t\tstd::memcpy(\n\t\t\tbackend->m_last_frame.data(),\n\t\t\toutput + written - bytes_per_frame,\n\t\t\tbytes_per_frame);\n\t}\n\n\t// RemoteIO must always receive a complete slice. Repeating the final sample\n\t// across an underrun turns a short mixer miss into an audible DC-like buzz.\n\t// Silence only the missing tail; normal fully-written callbacks are untouched.\n\tif (written < requested)\n\t{\n\t\tstd::memset(output + written, 0, requested - written);\n\t}\n'''
if 'DC-like buzz' not in a:
    if old not in a:
        raise SystemExit("IOSAudioBackend.cpp underrun anchor drifted")
    a = a.replace(old, new, 1)
audio.write_text(a)

# The savestate reader re-scans candidate SPU images. The pinned upstream loop
# subtracts 16 from an unsigned end offset and does not clamp that offset to the
# captured segment. A short/empty candidate therefore underflows and reaches
# read_from_ptr out of bounds while reloading an otherwise valid state.
p = ppu_module.read_text()
old_scan = '''\t\t\t\t\tfor (u32 found = 0, last_vaddr = 0, it = 16; it < end - 16; it += 4)\n'''
new_scan = '''\t\t\t\t\t// NeoStation iOS: a short savestate SPU segment must not make the\n\t\t\t\t\t// unsigned `end - 16` bound underflow into read_from_ptr().\n\t\t\t\t\tconst u32 scan_end = std::min<u32>(end, ::size32(ls_segment));\n\t\t\t\t\tfor (u32 found = 0, last_vaddr = 0, it = 16;\n\t\t\t\t\t\tscan_end >= 16 && it < scan_end - 16; it += 4)\n'''
if 'short savestate SPU segment' not in p:
    if old_scan not in p:
        raise SystemExit("PPUModule.cpp savestate SPU scan anchor drifted")
    p = p.replace(old_scan, new_scan, 1)
ppu_module.write_text(p)

print("NeoStation RPCS3 session/audio patch applied")
