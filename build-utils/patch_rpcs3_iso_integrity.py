#!/usr/bin/env python3
"""Reject truncated PS3 images and allow an atomic clean re-import."""

from pathlib import Path
import sys


root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
if not root or not (root / "rpcs3/ios/GameLibrary.cpp").exists():
    raise SystemExit("usage: patch_rpcs3_iso_integrity.py <rpcs3-source-root>")

cpp_path = root / "rpcs3/ios/GameLibrary.cpp"
header_path = root / "rpcs3/ios/GameLibrary.h"
cpp = cpp_path.read_text()
header = header_path.read_text()

marker = "NeoStation ISO extent integrity"
if marker not in cpp:
    anchor = """std::optional<installed_game> installed_iso(const std::string& directory)
{"""
    helper = r'''// NeoStation ISO extent integrity: ISO9660 metadata may remain readable in a
// truncated image even though a later game file points beyond EOF. Validate the
// complete extent tree before accepting or booting the image so this condition
// becomes an actionable import error instead of a permanent guest retry loop.
bool validate_iso_node_extents(
	const iso_fs_node& node,
	u64 image_size,
	std::string_view parent,
	std::string& detail)
{
	std::string path{parent};
	if (!node.metadata.name.empty())
	{
		if (!path.empty())
		{
			path += '/';
		}
		path += node.metadata.name;
	}

	if (!node.metadata.is_directory)
	{
		for (const iso_extent_info& extent : node.metadata.extents)
		{
			if (extent.start > std::numeric_limits<u64>::max() / ISO_SECTOR_SIZE)
			{
				detail = fmt::format("%s has an overflowing ISO extent", path);
				return false;
			}
			const u64 byte_offset = extent.start * ISO_SECTOR_SIZE;
			if (byte_offset > image_size || extent.size > image_size - byte_offset)
			{
				detail = fmt::format(
					"%s requires ISO bytes through %llu, but the image contains only %llu bytes",
					path, byte_offset + extent.size, image_size);
				return false;
			}
		}
	}

	for (const auto& child : node.children)
	{
		if (child && !validate_iso_node_extents(*child, image_size, path, detail))
		{
			return false;
		}
	}
	return true;
}

'''
    if anchor not in cpp:
        raise SystemExit("GameLibrary.cpp installed-ISO anchor drifted")
    cpp = cpp.replace(anchor, helper + anchor, 1)

    public_anchor = """bool is_valid_game_title_id(std::string_view title_id) noexcept
{
	return valid_title_id(title_id);
}
"""
    public_impl = public_anchor + r'''
bool validate_installed_game_iso(const std::string& iso_path, std::string& detail)
{
	detail.clear();
	u64 image_size = 0;
	if (!is_iso_file(iso_path, &image_size) || !image_size)
	{
		detail = "The installed disc image is missing or unreadable";
		return false;
	}

	iso_archive archive{iso_path};
	if (!archive.is_valid())
	{
		detail = "The installed disc image has an invalid ISO filesystem";
		return false;
	}
	return validate_iso_node_extents(archive.root(), image_size, {}, detail);
}
'''
    if public_anchor not in cpp:
        raise SystemExit("GameLibrary.cpp public validation anchor drifted")
    cpp = cpp.replace(public_anchor, public_impl, 1)

    copy_old = """	return source.pos() == source.size();
}

bool copy_folder_file_with_progress("""
    copy_new = """	// Flush and verify the destination as well as the source. A provider-backed
	// document can otherwise report its advertised length even after a short
	// transfer, leaving a sparse/truncated private copy that only fails in-game.
	destination.sync();
	return source.pos() == source.size() &&
		destination.size() == source.size();
}

bool copy_folder_file_with_progress("""
    if copy_old not in cpp:
        raise SystemExit("GameLibrary.cpp progressive copy anchor drifted")
    cpp = cpp.replace(copy_old, copy_new, 1)

    archive_anchor = """	iso_archive archive{temporary_iso};
	const psf::registry metadata = archive.open_psf("PS3_GAME/PARAM.SFO");
"""
    archive_new = """	iso_archive archive{temporary_iso};
	std::string integrity_detail;
	if (!archive.is_valid() ||
		!validate_iso_node_extents(archive.root(), iso_size, {}, integrity_detail))
	{
		return invalid_iso(fmt::format(
			"The selected image is truncated or corrupt: %s", integrity_detail));
	}
	const psf::registry metadata = archive.open_psf("PS3_GAME/PARAM.SFO");
"""
    if archive_anchor not in cpp:
        raise SystemExit("GameLibrary.cpp metadata validation anchor drifted")
    cpp = cpp.replace(archive_anchor, archive_new, 1)

    replace_old = """	const std::string final_directory = root + title_id;
	if (fs::is_dir(final_directory))
	{
		return iso_installation_failed(
			fmt::format("A disc image for %s is already installed", title_id), title_id, title);
	}
	if (!fs::rename(temporary.path, final_directory, false))
	{
		return iso_installation_failed("Unable to finalize the ISO installation", title_id, title);
	}
	temporary.path.clear();
"""
    replace_new = """	const std::string final_directory = root + title_id;
	const std::string previous_directory = root + ".replace-" + title_id;
	const bool replacing = fs::exists(final_directory);
	if (fs::exists(previous_directory))
	{
		fs::remove_all(previous_directory, true, true);
	}
	if (replacing && !fs::rename(final_directory, previous_directory, false))
	{
		return iso_installation_failed(
			fmt::format("Unable to preserve the existing disc image for %s", title_id), title_id, title);
	}
	if (!fs::rename(temporary.path, final_directory, false))
	{
		if (replacing)
		{
			fs::rename(previous_directory, final_directory, false);
		}
		return iso_installation_failed("Unable to finalize the ISO installation", title_id, title);
	}
	temporary.path.clear();
	if (replacing)
	{
		fs::remove_all(previous_directory, true, true);
	}
"""
    if replace_old not in cpp:
        raise SystemExit("GameLibrary.cpp replacement anchor drifted")
    cpp = cpp.replace(replace_old, replace_new, 1)

declaration = (
    "bool validate_installed_game_iso("
    "const std::string& iso_path, std::string& detail);"
)
if declaration not in header:
    anchor = "bool is_valid_game_title_id(std::string_view title_id) noexcept;\n"
    if anchor not in header:
        raise SystemExit("GameLibrary.h validation declaration anchor drifted")
    header = header.replace(anchor, anchor + declaration + "\n", 1)

cpp_path.write_text(cpp)
header_path.write_text(header)
print("RPCS3 ISO extent-integrity patch applied")
