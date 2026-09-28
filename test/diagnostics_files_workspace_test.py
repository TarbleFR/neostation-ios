#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
diag = (ROOT / "lib/services/diagnostics_directory.dart").read_text()
main = (ROOT / "lib/main.dart").read_text()
service = (ROOT / "lib/services/rpcs3_internal_service.dart").read_text()
native = (ROOT / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.mm").read_text()
external = (ROOT / "packages/external_folder_access/ios/Classes/ExternalFolderAccessPlugin.swift").read_text()

def require(value, message):
    if not value:
        raise SystemExit(message)

for token in (
    "DiagnosticsDirectory.migrateLegacyRootFiles()",
    "Rpcs3InternalService.synchronizeFilesWorkspace()",
):
    require(token in main, f"startup housekeeping missing: {token}")

for token in (
    "'Diagnostics'",
    "lower.endsWith('_debug.txt')",
    "lower.startsWith('diagnostic-')",
    "rpcs3-diagnostic.log",
    "rpcs3-milestones.log",
):
    require(token in diag, f"diagnostic migration contract missing: {token}")

for token in (
    "'Import/Game Saves'",
    "'Import/Savestates'",
    "'Export/Game Saves'",
    "'Export/Savestates'",
    "synchronizeFilesWorkspace",
    "consumeSource: true",
    "README.txt",
):
    require(token in service, f"RPCS3 Files workspace contract missing: {token}")

require('stringByAppendingPathComponent:@"Diagnostics"' in native,
        "native RPCS3 logs still target Documents root")
require('"Diagnostics"' in external and "appendingPathComponent(fileName)" in external,
        "JIT launch diagnostics still target Documents root")

print("PASS: Diagnostics folder and physical RPCS3 Import/Export workspace contracts")
