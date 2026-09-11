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
    system.write_text(text)

print("NeoStation RPCS3 serial-profile layering patch applied")
