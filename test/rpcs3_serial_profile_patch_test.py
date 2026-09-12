#!/usr/bin/env python3
from pathlib import Path
import sys


root = Path(sys.argv[1]) if len(sys.argv) > 1 else None
if not root:
    raise SystemExit("usage: rpcs3_serial_profile_patch_test.py <rpcs3-source-root>")

system = (root / "rpcs3/Emu/System.cpp").read_text()
assert "NeoStation iOS serial profiles intentionally layer after custom config" in system
assert "Applying iOS serial profile afterwards" in system
assert "#ifdef RPCS3_IOS" in system
assert "m_add_database_config = false;\n#endif" in system
assert system.index("Applying iOS serial profile afterwards") < system.index(
    "// Add database config"
)
assert "ios_custom_resolution_scale = g_cfg.video.resolution_scale_percent.get();" in system
assert "Preserving user-selected iOS resolution scale after serial profile" in system
assert system.index("// Add database config") < system.index(
    "Preserving user-selected iOS resolution scale after serial profile"
)
print("RPCS3 serial-profile layering patch contract: OK")
