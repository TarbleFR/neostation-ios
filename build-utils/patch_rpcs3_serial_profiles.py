#!/usr/bin/env python3
"""Add recommended -> sparse user-override layering to RPCS3's iOS API.

Legacy full custom configs remain fully user-owned and keep RPCS3's upstream
behaviour (they suppress GameDB). New per-game edits are stored as a sparse
key/value sidecar and replayed after the recommended profile. This lets the
database evolve without silently overwriting an explicit user choice.
"""

from pathlib import Path
import sys


root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
if not root or not (root / "rpcs3/Emu/System.cpp").exists():
    raise SystemExit("usage: patch_rpcs3_serial_profiles.py <rpcs3-source-root>")

system_path = root / "rpcs3/Emu/System.cpp"
header_path = root / "rpcs3/ios/RPCS3IOSSettings.h"
settings_path = root / "rpcs3/ios/RPCS3IOSSettings.cpp"
api_path = root / "rpcs3/ios/RPCS3IOS.cpp"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"RPCS3 {label} anchor drifted")
    return text.replace(old, new, 1)


system = system_path.read_text()
marker = "NeoStation sparse user overrides are always the final title layer"
if marker not in system:
    system = replace_once(
        system,
        '#include "ios/RPCS3IOSExperimentalPolicy.h"\n',
        '#include "ios/RPCS3IOSExperimentalPolicy.h"\n#include "ios/RPCS3IOSSettings.h"\n',
        "System settings include",
    )
    system = replace_once(
        system,
        "\t\t\tconst auto ios_global_persistent_spu_cache = g_cfg.ios_experimental.persistent_spu_object_cache.get();\n",
        "\t\t\tconst auto ios_global_persistent_spu_cache = g_cfg.ios_experimental.persistent_spu_object_cache.get();\n"
        "\t\t\tbool ios_has_legacy_custom_config = false;\n",
        "legacy custom state",
    )
    system = replace_once(
        system,
        "\t\t\t\t\t\tif (g_cfg.from_string(cfg_file.to_string()))\n\t\t\t\t\t\t{\n\t\t\t\t\t\t\tg_cfg.name = config_path;\n\t\t\t\t\t\t\tm_config_path = config_path;\n",
        "\t\t\t\t\t\tif (g_cfg.from_string(cfg_file.to_string()))\n\t\t\t\t\t\t{\n"
        "#ifdef RPCS3_IOS\n\t\t\t\t\t\t\tios_has_legacy_custom_config = true;\n#endif\n"
        "\t\t\t\t\t\t\tg_cfg.name = config_path;\n\t\t\t\t\t\t\tm_config_path = config_path;\n",
        "legacy custom detection",
    )
    database = '''\t\t\tif (m_add_database_config && m_db_config && !m_db_config->empty())
\t\t\t{
\t\t\t\t// Add database config
\t\t\t\tsys_log.notice("Applying database config");

\t\t\t\tif (g_cfg.from_string(*m_db_config))
\t\t\t\t{
\t\t\t\t\tg_cfg.name = "database_config";
\t\t\t\t}
\t\t\t\telse
\t\t\t\t{
\t\t\t\t\tsys_log.error("Failed to apply database config");
\t\t\t\t}
\t\t\t}
'''
    layered = database + '''
#ifdef RPCS3_IOS
\t\t\t// NeoStation sparse user overrides are always the final title layer.
\t\t\t// A legacy full custom config remains authoritative and suppresses GameDB.
\t\t\tif (!ios_has_legacy_custom_config && !m_title_id.empty() &&
\t\t\t\t!rpcs3::ios::apply_game_setting_overrides(m_title_id))
\t\t\t{
\t\t\t\tsys_log.error("Failed to apply sparse iOS user overrides for %s", m_title_id);
\t\t\t}
#endif
'''
    system = replace_once(system, database, layered, "database layer")
    system_path.write_text(system)


header = header_path.read_text()
if "apply_game_setting_overrides" not in header:
    header = replace_once(
        header,
        "bool remove_game_settings(std::string_view title_id) noexcept;\n",
        "bool remove_game_settings(std::string_view title_id) noexcept;\n"
        "bool has_game_setting_overrides(std::string_view title_id) noexcept;\n"
        "bool apply_game_setting_overrides(std::string_view title_id) noexcept;\n"
        "bool save_game_setting_override(std::string_view title_id, std::string_view key, std::string_view value) noexcept;\n"
        "bool remove_game_setting_overrides(std::string_view title_id) noexcept;\n",
        "settings declarations",
    )
    header_path.write_text(header)


settings = settings_path.read_text()
settings_marker = "maximum_sparse_overrides_per_title"
if settings_marker not in settings:
    settings = replace_once(
        settings,
        '#include "GameLibrary.h"\n',
        '#include "GameLibrary.h"\n#include "RPCS3IOSZcullAccuracy.h"\n\n#include "yaml-cpp/yaml.h"\n',
        "YAML includes",
    )
    helpers_anchor = "constexpr std::size_t maximum_preset_name_size = 80;\n"
    helpers = r'''constexpr std::size_t maximum_sparse_overrides_per_title = 512;
constexpr std::size_t maximum_sparse_override_size = 1024u * 1024u;

std::string game_setting_overrides_directory()
{
	return rpcs3::utils::get_custom_config_dir() + "overrides/";
}

std::string game_setting_overrides_path(std::string_view title_id)
{
	return game_setting_overrides_directory() + std::string{title_id} + ".yml";
}

bool read_game_setting_overrides(
	std::string_view title_id,
	std::vector<std::pair<std::string, std::string>>& values)
{
	values.clear();
	if (!is_valid_game_title_id(title_id))
	{
		return false;
	}
	const std::string path = game_setting_overrides_path(title_id);
	if (!fs::is_file(path))
	{
		return fs::g_tls_error == fs::error::noent;
	}
	fs::file file{path, fs::read};
	if (!file || file.size() == 0 || file.size() > maximum_sparse_override_size)
	{
		return false;
	}
	try
	{
		const YAML::Node root = YAML::Load(file.to_string());
		if (!root.IsMap() || root.size() > maximum_sparse_overrides_per_title)
		{
			return false;
		}
		values.reserve(root.size());
		for (const auto& item : root)
		{
			if (!item.first.IsScalar() || !item.second.IsScalar())
			{
				return false;
			}
			values.emplace_back(item.first.Scalar(), item.second.Scalar());
		}
		return true;
	}
	catch (const YAML::Exception&)
	{
		return false;
	}
}

bool write_game_setting_overrides(
	std::string_view title_id,
	const std::vector<std::pair<std::string, std::string>>& values)
{
	if (!is_valid_game_title_id(title_id) ||
		values.size() > maximum_sparse_overrides_per_title ||
		!fs::create_path(game_setting_overrides_directory()))
	{
		return false;
	}
	YAML::Emitter output;
	output << YAML::BeginMap;
	for (const auto& [key, value] : values)
	{
		output << YAML::Key << key << YAML::Value << value;
	}
	output << YAML::EndMap;
	if (!output.good() || output.size() > maximum_sparse_override_size)
	{
		return false;
	}
	fs::pending_file destination{game_setting_overrides_path(title_id)};
	return destination.file &&
		destination.file.write(output.c_str(), output.size()) == output.size() &&
		destination.commit();
}

'''
    settings = replace_once(
        settings,
        helpers_anchor,
        helpers + helpers_anchor,
        "sparse helper insertion",
    )
    public_anchor = '''bool remove_game_settings(std::string_view title_id) noexcept
{
\tif (title_id.empty())
\t{
\t\treturn false;
\t}

\tconst std::string path = rpcs3::utils::get_custom_config_path(std::string{title_id});
\treturn fs::remove_file(path) || fs::g_tls_error == fs::error::noent;
}
'''
    public_impl = public_anchor + r'''

bool has_game_setting_overrides(std::string_view title_id) noexcept
{
	if (!is_valid_game_title_id(title_id))
	{
		return false;
	}
	return fs::is_file(game_setting_overrides_path(title_id));
}

bool apply_game_setting_overrides(std::string_view title_id) noexcept
{
	std::vector<std::pair<std::string, std::string>> values;
	if (!read_game_setting_overrides(title_id, values))
	{
		return false;
	}
	for (const auto& [key, value] : values)
	{
		if (key == "gpu.zcull_accuracy")
		{
			const auto state = parse_zcull_accuracy(value);
			if (!state)
			{
				return false;
			}
			g_cfg.video.precise_zpass_count.from_string(state->precise ? "true" : "false");
			g_cfg.video.relaxed_zcull_sync.from_string(state->relaxed ? "true" : "false");
			continue;
		}
		const setting_record* setting = find_setting(key, setting_context::game);
		if (!setting || !setting->entry->from_string(value))
		{
			return false;
		}
	}
	return true;
}

bool save_game_setting_override(
	std::string_view title_id,
	std::string_view key,
	std::string_view value) noexcept
{
	if (!find_setting(key, setting_context::game))
	{
		return false;
	}
	std::vector<std::pair<std::string, std::string>> values;
	if (!read_game_setting_overrides(title_id, values))
	{
		return false;
	}
	if (auto found = std::ranges::find_if(values, [&](const auto& item)
	{
		return item.first == key;
	}); found != values.end())
	{
		found->second = value;
	}
	else
	{
		values.emplace_back(key, value);
	}
	return write_game_setting_overrides(title_id, values);
}

bool remove_game_setting_overrides(std::string_view title_id) noexcept
{
	if (!is_valid_game_title_id(title_id))
	{
		return false;
	}
	return fs::remove_file(game_setting_overrides_path(title_id)) ||
		fs::g_tls_error == fs::error::noent;
}
'''
    settings = replace_once(
        settings,
        public_anchor,
        public_impl,
        "sparse public implementation",
    )
    settings_path.write_text(settings)


api = api_path.read_text()
api_marker = "Load recommendations before sparse explicit user overrides"
if api_marker not in api:
    api = replace_once(
        api,
        "bool load_settings_for_api(std::string_view title_id, bool& has_custom_config)\n",
        "bool apply_database_settings_for_api(std::string_view title_id);\n\n"
        "bool load_settings_for_api(std::string_view title_id, bool& has_custom_config)\n",
        "database forward declaration",
    )
    old_load = '''\tconst auto result = rpcs3::ios::load_effective_settings(title_id, has_custom_config);
\tif (result == rpcs3::ios::settings_load_error::none)
\t{
\t\treturn true;
\t}

\tset_error(std::string{rpcs3::ios::settings_load_error_detail(result)});
\treturn false;
'''
    new_load = '''\tconst auto result = rpcs3::ios::load_effective_settings(title_id, has_custom_config);
\tif (result != rpcs3::ios::settings_load_error::none)
\t{
\t\tset_error(std::string{rpcs3::ios::settings_load_error_detail(result)});
\t\treturn false;
\t}

\t// Load recommendations before sparse explicit user overrides. Legacy full
\t// custom configs remain authoritative and deliberately suppress GameDB.
\tif (!title_id.empty() && !has_custom_config)
\t{
\t\tif (!apply_database_settings_for_api(title_id))
\t\t{
\t\t\treturn false;
\t\t}
\t\tif (!rpcs3::ios::apply_game_setting_overrides(title_id))
\t\t{
\t\t\tset_error(fmt::format("Unable to apply user settings for %s", title_id));
\t\t\treturn false;
\t\t}
\t}
\treturn true;
'''
    api = replace_once(api, old_load, new_load, "API profile layering")
    api = replace_once(
        api,
        '''\t\tif (!has_custom_config && !apply_database_settings_for_api(title_id))
\t\t{
\t\t\treturn RPCS3_IOS_CONFIG_DATABASE_INVALID;
\t\t}
''',
        "",
        "preset duplicate database layer",
    )
    api = replace_once(
        api,
        "\t\t*has_custom_config = custom_config ? 1u : 0u;\n",
        "\t\t*has_custom_config = (custom_config || rpcs3::ios::has_game_setting_overrides(title_id)) ? 1u : 0u;\n",
        "override enumeration state",
    )
    api = replace_once(
        api,
        '''\t\tif (!rpcs3::ios::save_game_settings(title_id))
\t\t{
\t\t\tset_error(fmt::format("Unable to save the custom configuration for %s", title_id));
\t\t\treturn RPCS3_IOS_SETTINGS_SAVE_FAILED;
\t\t}
\t\temit_log(4, fmt::format("Saved game setting %s = %s for %s", key, value, title_id));
''',
        '''\t\tconst bool saved = has_custom_config
\t\t\t? rpcs3::ios::save_game_settings(title_id)
\t\t\t: rpcs3::ios::save_game_setting_override(title_id, key, value);
\t\tif (!saved)
\t\t{
\t\t\tset_error(fmt::format("Unable to save the user override for %s", title_id));
\t\t\treturn RPCS3_IOS_SETTINGS_SAVE_FAILED;
\t\t}
\t\temit_log(4, fmt::format("Saved explicit user override %s = %s for %s", key, value, title_id));
''',
        "sparse setting save",
    )
    api = replace_once(
        api,
        '''\t\tif (!rpcs3::ios::remove_game_settings(title_id))
\t\t{
\t\t\tset_error(fmt::format("Unable to remove the custom configuration for %s", title_id));
\t\t\treturn RPCS3_IOS_SETTINGS_SAVE_FAILED;
\t\t}
''',
        '''\t\tif (!rpcs3::ios::remove_game_settings(title_id) ||
\t\t\t!rpcs3::ios::remove_game_setting_overrides(title_id))
\t\t{
\t\t\tset_error(fmt::format("Unable to remove the custom configuration for %s", title_id));
\t\t\treturn RPCS3_IOS_SETTINGS_SAVE_FAILED;
\t\t}
''',
        "override removal",
    )
    api_path.write_text(api)

print("NeoStation RPCS3 recommended/user profile layering patch applied")
