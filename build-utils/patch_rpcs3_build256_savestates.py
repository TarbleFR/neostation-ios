#!/usr/bin/env python3
"""NeoStation Build 256 savestate slots, relocation and safe preflight.

This is intentionally layered after the existing Build 254 transaction patch.
It keeps the public RPCS3 iOS ABI at version 30 and exports one NeoStation-only
entry point for numbered slots.
"""

from __future__ import annotations

import sys
from pathlib import Path


MARKER = "NEOSTATION_SAVESTATE_SLOTS_V2"


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{description}: expected one source anchor, found {count}")
    return text.replace(old, new, 1)


def patch_status(source: Path) -> None:
    path = source / "rpcs3/ios/NeoStationSavestateStatus.h"
    text = path.read_text()
    if MARKER in text:
        return
    text = replace_once(
        text,
        """struct snapshot
{
    phase state;
    bool active;
    bool committed;
    std::string message;
};
""",
        f"""struct snapshot
{{
    phase state;
    bool active;
    bool committed;
    std::uint32_t slot; // {MARKER}: 0=rolling, 1..10=user slot
    std::string message;
}};
""",
        "savestate snapshot slot",
    )
    text = replace_once(
        text,
        """    snapshot value{phase::idle, false, false, {}};
public:
    bool begin()
    {
        std::lock_guard lock(mutex);
        if (value.active) return false;
        value = {phase::preparing, true, false, {}};
""",
        """    snapshot value{phase::idle, false, false, 0, {}};
public:
    bool begin(std::uint32_t slot = 0)
    {
        std::lock_guard lock(mutex);
        if (value.active || slot > 10) return false;
        value = {phase::preparing, true, false, slot, {}};
""",
        "savestate operation slot",
    )
    path.write_text(text)


def patch_system(source: Path) -> None:
    path = source / "rpcs3/Emu/System.cpp"
    text = path.read_text()
    if MARKER in text:
        return

    # Reject an active HLE decoder before attempting to quiesce SPUs. The
    # Build 255 diagnostic demonstrated that retrying during the same decoder
    # lifetime could leave the RSX waiting on SPU-owned semaphores.
    preflight_anchor = """\t\t\t\tstd::vector<std::pair<shared_ptr<named_thread<spu_thread>>, u32>> paused_spus;

\t\t\t\tif (!try_lock_spu_threads_in_a_state_compatible_with_savestates(false, &paused_spus))
"""
    preflight_patch = f"""\t\t\t\tstd::vector<std::pair<shared_ptr<named_thread<spu_thread>>, u32>> paused_spus;

\t\t\t\t// {MARKER}: VDEC is known to be unsaveable. Test it before SPU
\t\t\t\t// quiescence so repeated taps during a cutscene cannot perturb SPU/RSX.
\t\t\t\tif (check_if_vdec_contexts_exist())
\t\t\t\t{{
\t\t\t\t\tneostation::savestate::current.error("An HLE video decoder is active and cannot be captured safely. Finish or skip the cutscene before retrying.");
\t\t\t\t\trsx::overlays::queue_message(localized_string_id::SAVESTATE_FAILED_DUE_TO_VDEC);
\t\t\t\t\tsys_log.error("Savestate rejected before SPU quiescence because an HLE video decoder is active.");
\t\t\t\t\tm_emu_state_close_pending = false;
\t\t\t\t\tCallFromMainThread([pause = std::move(pause_thread)]() {{ }}, nullptr, false);
\t\t\t\t\treturn;
\t\t\t\t}}

\t\t\t\tif (!try_lock_spu_threads_in_a_state_compatible_with_savestates(false, &paused_spus))
"""
    text = replace_once(text, preflight_anchor, preflight_patch, "VDEC preflight")

    # Use ten stable, atomically replaced filenames instead of an unbounded
    # rolling sequence when NeoStation requested a numbered slot.
    path_anchor = """\t\t\tpath.resize(path.rfind(save) + save.size());
\t\t\tpath += ".zst";
"""
    path_patch = f"""\t\t\tpath.resize(path.rfind(save) + save.size());
\t\t\tpath += ".zst";
#ifdef RPCS3_IOS
\t\t\tif (const u32 slot = neostation::savestate::current.read().slot; slot >= 1 && slot <= 10)
\t\t\t{{
\t\t\t\t// {MARKER}: the existing pending_file commit provides atomic overwrite.
\t\t\t\tpath = get_savestate_file(m_title_id, m_path, -1);
\t\t\t\tpath += fmt::format("%s_1_%u.SAVESTAT.zst", m_title_id, slot - 1);
\t\t\t}}
#endif
"""
    text = replace_once(text, path_anchor, path_patch, "fixed savestate slots")

    clean_anchor = """\t\t\t\tclean_savestates(m_title_id, m_path, max_files, max_files_size_mb << 20);
"""
    clean_patch = """#ifdef RPCS3_IOS
\t\t\t\t// Numbered NeoStation slots are already bounded to ten. Do not let a
\t\t\t\t// legacy global rolling limit delete a slot immediately after commit.
\t\t\t\tif (neostation::savestate::current.read().slot == 0)
\t\t\t\t\tclean_savestates(m_title_id, m_path, max_files, max_files_size_mb << 20);
#else
\t\t\t\tclean_savestates(m_title_id, m_path, max_files, max_files_size_mb << 20);
#endif
"""
    text = replace_once(text, clean_anchor, clean_patch, "slot retention")

    # New iOS states store the real serial instead of an ephemeral app-container
    # UUID. Desktop RPCS3 keeps its original on-disk format.
    iso_save_anchor = """\t\t\t\t\tar(m_path.substr(iso_device::virtual_device_name.size() + 1));
\t\t\t\t\tar(iso_dev->get_loaded_iso());
"""
    iso_save_patch = """\t\t\t\t\tar(m_path.substr(iso_device::virtual_device_name.size() + 1));
#ifdef RPCS3_IOS
\t\t\t\t\t// Resolve this serial through the current installation on load. iOS
\t\t\t\t\t// changes its sandbox container UUID after reinstall/update.
\t\t\t\t\tar(m_title_id.empty() ? iso_dev->get_loaded_iso() : m_title_id);
#else
\t\t\t\t\tar(iso_dev->get_loaded_iso());
#endif
"""
    text = replace_once(text, iso_save_anchor, iso_save_patch, "portable ISO identity")

    iso_load_anchor = """\t\t\tlaunching_from_disc_archive = is_iso_file(disc_info, nullptr, &launching_from_optical_drive);

\t\t\tsys_log.notice("Savestate: is iso archive = %d ('%s')", launching_from_disc_archive, disc_info);
"""
    iso_load_patch = """\t\t\tlaunching_from_disc_archive = is_iso_file(disc_info, nullptr, &launching_from_optical_drive);

#ifdef RPCS3_IOS
\t\t\t// Build 255 and older states can contain an absolute path from a prior
\t\t\t// iOS container. Remap it through the already registered real Game ID.
\t\t\tif (!launching_from_disc_archive && disc_info.starts_with("/"sv) &&
\t\t\t\t!fs::is_file(disc_info) && !m_title_id.empty())
\t\t\t{
\t\t\t\tif (const std::string current_disc = m_games_config.get_path(m_title_id);
\t\t\t\t\tis_iso_file(current_disc, nullptr, &launching_from_optical_drive))
\t\t\t\t{
\t\t\t\t\tsys_log.notice("Relocating savestate disc source for %s from '%s' to '%s'", m_title_id, disc_info, current_disc);
\t\t\t\t\tdisc_info = current_disc;
\t\t\t\t\tlaunching_from_disc_archive = true;
\t\t\t\t}
\t\t\t}
#endif

\t\t\tsys_log.notice("Savestate: is iso archive = %d ('%s')", launching_from_disc_archive, disc_info);
"""
    text = replace_once(text, iso_load_anchor, iso_load_patch, "legacy ISO relocation")

    mapped_iso_anchor = """\t\t\t\t\tif (is_iso_file(game_path))
\t\t\t\t\t{
\t\t\t\t\t\tgame_path = iso_device::virtual_device_name + "/PS3_GAME/./";
\t\t\t\t\t}

\t\t\t\t\tif (game_path.ends_with("/./"))
"""
    mapped_iso_patch = """\t\t\t\t\tif (is_iso_file(game_path, nullptr, &launching_from_optical_drive))
\t\t\t\t\t{
#ifdef RPCS3_IOS
\t\t\t\t\t\t// A portable iOS state stored the Game ID. Load the current ISO now;
\t\t\t\t\t\t// the virtual device cannot survive an application relaunch.
\t\t\t\t\t\tdisc_info = game_path;
\t\t\t\t\t\tlaunching_from_disc_archive = true;
#else
\t\t\t\t\t\tgame_path = iso_device::virtual_device_name + "/PS3_GAME/./";
#endif
\t\t\t\t\t}

\t\t\t\t\tif (!launching_from_disc_archive && game_path.ends_with("/./"))
"""
    text = replace_once(text, mapped_iso_anchor, mapped_iso_patch, "Game ID ISO reload")

    text = replace_once(
        text,
        """\t\t\tif (disc_info.starts_with("/"sv))
""",
        """\t\t\tif (!launching_from_disc_archive && disc_info.starts_with("/"sv))
""",
        "ISO is not an SFO path",
    )

    path.write_text(text)


def patch_orphan_cleanup(source: Path) -> None:
    system = source / "rpcs3/Emu/System.cpp"
    text = system.read_text()
    init_anchor = """\tmake_path_verbose(fs::get_parent_dir(get_savestate_file("NO_ID", "/NO_FILE", -1, -1)), false);
"""
    if "clean_orphaned_savestate_temps();" not in text:
        text = replace_once(
            text,
            init_anchor,
            init_anchor
            + "\t// ARMSX3 issue #123: reclaim temp streams stranded by process death.\n"
            + "\tclean_orphaned_savestate_temps();\n",
            "orphan cleanup call",
        )
        system.write_text(text)

    header = source / "rpcs3/Emu/savestate_utils.hpp"
    text = header.read_text()
    declaration = "void clean_orphaned_savestate_temps();"
    if declaration not in text:
        text = text.rstrip() + "\n" + declaration + "\n"
        header.write_text(text)

    cpp = source / "rpcs3/Emu/savestate_utils.cpp"
    text = cpp.read_text()
    if "void clean_orphaned_savestate_temps()" not in text:
        anchor = "\nbool load_and_check_reserved(utils::serial& ar, usz size)\n"
        implementation = r'''
void clean_orphaned_savestate_temps()
{
	// Ported from ARMSX3 4468462: pending_file cannot clean a POSIX temp if
	// iOS kills the whole process during a large state write.
	constexpr std::string_view temp_prefix = "\xEF\xBC\x84"; // U+FF04
	const std::string root = fs::get_config_dir() + "savestates/";
	const auto sweep = [&](const std::string& directory)
	{
		for (const auto& entry : fs::dir{directory})
		{
			if (entry.is_directory || !entry.name.starts_with(temp_prefix) ||
				!entry.name.ends_with(".tmp") || entry.name.find(".SAVESTAT") == umax)
				continue;
			const std::string path = directory + entry.name;
			if (fs::remove_file(path))
				sys_log.success("Removed orphaned savestate temporary '%s' (%d bytes).", path, entry.size);
			else
				sys_log.error("Failed to remove orphaned savestate temporary '%s'! (error: %s)", path, fs::g_tls_error);
		}
	};
	for (const auto& entry : fs::dir{root})
	{
		if (!entry.is_directory || entry.name == "." || entry.name == "..") continue;
		sweep(root + entry.name + "/");
	}
}
'''
        text = replace_once(text, anchor, implementation + anchor, "orphan cleanup implementation")
        cpp.write_text(text)


def patch_api(source: Path) -> None:
    cpp = source / "rpcs3/ios/RPCS3IOS.cpp"
    text = cpp.read_text()
    if "neostation_rpcs3_ios_save_state_slot" not in text:
        text = replace_once(
            text,
            'extern "C" RPCS3_IOS_EXPORT rpcs3_ios_status neostation_rpcs3_ios_save_state(void) noexcept\n{\n',
            "static rpcs3_ios_status neostation_rpcs3_ios_save_state_impl(uint32_t requested_slot) noexcept\n{\n",
            "savestate implementation signature",
        )
        text = replace_once(
            text,
            "if (!neostation::savestate::current.begin())",
            "if (!neostation::savestate::current.begin(requested_slot))",
            "savestate operation slot handoff",
        )
        wrapper_anchor = 'extern "C" RPCS3_IOS_EXPORT rpcs3_ios_status neostation_rpcs3_ios_get_savestate_status(\n'
        wrappers = r'''extern "C" RPCS3_IOS_EXPORT rpcs3_ios_status neostation_rpcs3_ios_save_state(void) noexcept
{
    return neostation_rpcs3_ios_save_state_impl(0);
}

extern "C" RPCS3_IOS_EXPORT rpcs3_ios_status neostation_rpcs3_ios_save_state_slot(uint32_t slot) noexcept
{
    if (slot < 1 || slot > 10)
    {
        set_error("A NeoStation save-state slot must be between 1 and 10");
        return RPCS3_IOS_INVALID_ARGUMENT;
    }
    return neostation_rpcs3_ios_save_state_impl(slot);
}

'''
        text = replace_once(text, wrapper_anchor, wrappers + wrapper_anchor, "slot API wrappers")
        cpp.write_text(text)

    exports = source / "rpcs3/ios/RPCS3IOS.exports"
    text = exports.read_text()
    symbol = "_neostation_rpcs3_ios_save_state_slot"
    if symbol not in text.splitlines():
        exports.write_text(text.rstrip() + "\n" + symbol + "\n")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_rpcs3_build256_savestates.py <rpcs3-source-root>")
    source = Path(sys.argv[1]).resolve()
    patch_status(source)
    patch_system(source)
    patch_orphan_cleanup(source)
    patch_api(source)
    print("NeoStation Build 256 savestate slots/relocation patch: OK")


if __name__ == "__main__":
    main()
