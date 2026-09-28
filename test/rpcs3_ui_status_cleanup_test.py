#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
main = (ROOT / "lib/main.dart").read_text()
manager = (ROOT / "lib/screens/rpcs3_manager_screen.dart").read_text()
playlist = (ROOT / "lib/widgets/rpcs3_internal_playlist_actions.dart").read_text()
service = (ROOT / "lib/services/rpcs3_internal_service.dart").read_text()
header = (ROOT / "lib/widgets/header.dart").read_text()

def require(value, message):
    if not value:
        raise SystemExit(message)

blocking = main[main.index("void main() async {"):main.index("await AudioPolicyService().initialize();")]
require("synchronizeFilesWorkspace()" not in blocking,
        "RPCS3 Files workspace still blocks NeoStation cold startup")
require("migrateLegacyRootFiles()" not in blocking,
        "diagnostic migration still blocks NeoStation cold startup")
require("_prepareIosFilesWorkspaceAfterStartup" in main and
        "addPostFrameCallback" in main and
        "Duration(milliseconds: 750)" in main,
        "Files maintenance is not deferred until after the real app frame")

require("await synchronizeFilesWorkspace();" in service,
        "manual RPCS3 Files imports are not consumed before explicit Core startup")
require("static bool get jitPrepared => _jitPrepared;" in service,
        "authoritative JIT prepared state is not exposed")

require("diagnostics['jitPrepared'] == true" in manager and
        "Rpcs3InternalService.jitPrepared" in manager,
        "RPCS3 manager still ignores authoritative JIT state")
require("JIT activé • RPCS3 Core prêt." in manager and
        "JIT activé • RPCS3 Core à la demande." in manager,
        "RPCS3 manager active-state labels are missing")

require("value: 'saves'" not in playlist,
        "playlist popup still exposes Export save data")
require("value: 'restoreSaves'" not in playlist,
        "playlist popup still exposes Import save data")

require("header-jit-active-dot" in header,
        "main header JIT active dot is missing")
require("Rpcs3InternalService.runtimeStates.listen" in header and
        "state.jitReady || Rpcs3InternalService.jitPrepared" in header,
        "main header JIT dot is not driven by authoritative runtime state")
require("Color(0xFF22C55E)" in header and "JIT activé" in header,
        "main header JIT dot is not green/labeled")

print("PASS: startup non-blocking, popup clean, JIT status and green header dot authoritative")
