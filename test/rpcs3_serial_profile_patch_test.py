#!/usr/bin/env python3
from pathlib import Path
import sys


root = Path(sys.argv[1]) if len(sys.argv) > 1 else None
if not root:
    raise SystemExit("usage: rpcs3_serial_profile_patch_test.py <rpcs3-source-root>")

system = (root / "rpcs3/Emu/System.cpp").read_text()
settings = (root / "rpcs3/ios/RPCS3IOSSettings.cpp").read_text()
header = (root / "rpcs3/ios/RPCS3IOSSettings.h").read_text()
api = (root / "rpcs3/ios/RPCS3IOS.cpp").read_text()

# Upstream legacy configs remain authoritative: GameDB cannot overwrite them.
assert "Found custom config. Ignoring database config" in system
assert "m_add_database_config = false;" in system
assert "Applying iOS serial profile afterwards" not in system

# New edits are sparse and are replayed after recommendations at boot and in UI.
assert "NeoStation sparse user overrides are always the final title layer" in system
assert system.index("// Add database config") < system.index(
    "NeoStation sparse user overrides are always the final title layer"
)
assert "apply_game_setting_overrides(m_title_id)" in system
assert "apply_game_setting_overrides" in header
assert "maximum_sparse_overrides_per_title = 512" in settings
assert "YAML::BeginMap" in settings
assert "fs::pending_file destination{game_setting_overrides_path(title_id)}" in settings
assert "Load recommendations before sparse explicit user overrides" in api
assert api.index("apply_database_settings_for_api(title_id)") < api.index(
    "rpcs3::ios::apply_game_setting_overrides(title_id)"
)
assert "save_game_setting_override(title_id, key, value)" in api
assert "remove_game_setting_overrides(title_id)" in api
assert "!has_custom_config && !apply_database_settings_for_api(title_id)" not in api
print("RPCS3 recommended/user profile layering contract: OK")
