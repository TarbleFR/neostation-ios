#!/usr/bin/env python3
"""Layer NeoStation's serial profile over custom RPCS3 settings on iOS.

RPCS3 normally ignores its configuration database whenever a complete custom
configuration exists. NeoStation Build 247 created such files for launched
titles, which would hide the new partial serial profiles. Keep desktop behavior
unchanged, but on iOS preserve the custom/global values and then apply the
small managed database overlay selected by the real PARAM.SFO title ID.
"""

from pathlib import Path
import sys


root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
system = root / "rpcs3/Emu/System.cpp" if root else None
if not system or not system.exists():
    raise SystemExit("usage: patch_rpcs3_serial_profiles.py <rpcs3-source-root>")

text = system.read_text()
marker = "NeoStation iOS serial profiles intentionally layer after custom config"
if marker not in text:
    old = '''\t\t\t\t\t\t\tif (m_add_database_config)
\t\t\t\t\t\t\t{
\t\t\t\t\t\t\t\t// A custom config exists. Do not add the database config.
\t\t\t\t\t\t\t\tsys_log.notice("Found custom config. Ignoring database config");
\t\t\t\t\t\t\t\tm_add_database_config = false;
\t\t\t\t\t\t\t}
'''
    new = '''\t\t\t\t\t\t\tif (m_add_database_config)
\t\t\t\t\t\t\t{
#ifdef RPCS3_IOS
\t\t\t\t\t\t\t\t// NeoStation iOS serial profiles intentionally layer after custom config.
\t\t\t\t\t\t\t\t// The database document is partial, so unrelated user/global values survive.
\t\t\t\t\t\t\t\tsys_log.notice("Found custom config. Applying iOS serial profile afterwards");
#else
\t\t\t\t\t\t\t\t// A custom config exists. Do not add the database config.
\t\t\t\t\t\t\t\tsys_log.notice("Found custom config. Ignoring database config");
\t\t\t\t\t\t\t\tm_add_database_config = false;
#endif
\t\t\t\t\t\t\t}
'''
    if old not in text:
        raise SystemExit("RPCS3 custom/database configuration anchor drifted")
    text = text.replace(old, new, 1)

upscale_marker = "Preserving user-selected iOS resolution scale after serial profile"
if upscale_marker not in text:
    state_old = '''#ifdef RPCS3_IOS
			// This one setting is global-only. Custom title files are complete cfg
			// snapshots, so preserve config.yml's value before applying one.
			const auto ios_global_persistent_spu_cache = g_cfg.ios_experimental.persistent_spu_object_cache.get();
#endif
'''
    state_new = '''#ifdef RPCS3_IOS
			// This one setting is global-only. Custom title files are complete cfg
			// snapshots, so preserve config.yml's value before applying one.
			const auto ios_global_persistent_spu_cache = g_cfg.ios_experimental.persistent_spu_object_cache.get();
			u32 ios_custom_resolution_scale = 0;
			bool ios_has_custom_resolution_scale = false;
#endif
'''
    if state_old not in text:
        raise SystemExit("RPCS3 iOS profile state anchor drifted")
    text = text.replace(state_old, state_new, 1)

    custom_old = '''						if (g_cfg.from_string(cfg_file.to_string()))
						{
							g_cfg.name = config_path;
							m_config_path = config_path;
'''
    custom_new = '''						if (g_cfg.from_string(cfg_file.to_string()))
						{
#ifdef RPCS3_IOS
							ios_custom_resolution_scale = g_cfg.video.resolution_scale_percent.get();
							ios_has_custom_resolution_scale = true;
#endif
							g_cfg.name = config_path;
							m_config_path = config_path;
'''
    if custom_old not in text:
        raise SystemExit("RPCS3 custom title configuration anchor drifted")
    text = text.replace(custom_old, custom_new, 1)

    database_old = '''			if (m_add_database_config && m_db_config && !m_db_config->empty())
			{
				// Add database config
				sys_log.notice("Applying database config");

				if (g_cfg.from_string(*m_db_config))
				{
					g_cfg.name = "database_config";
				}
				else
				{
					sys_log.error("Failed to apply database config");
				}
			}
'''
    database_new = database_old + '''
#ifdef RPCS3_IOS
			if (ios_has_custom_resolution_scale)
			{
				sys_log.notice("Preserving user-selected iOS resolution scale after serial profile: %u%%", ios_custom_resolution_scale);
				g_cfg.video.resolution_scale_percent.set(ios_custom_resolution_scale);
			}
#endif
'''
    if database_old not in text:
        raise SystemExit("RPCS3 database application anchor drifted")
    text = text.replace(database_old, database_new, 1)

system.write_text(text)

print("NeoStation RPCS3 serial-profile layering patch applied")
