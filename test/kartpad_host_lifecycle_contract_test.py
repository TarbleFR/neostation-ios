#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "native/kartpad/donor/NeoKartPadDonorCore.mm").read_text()
control = (ROOT / "native/kartpad/donor/DonorSessionControl.inc").read_text()
abi = (ROOT / "packages/kartpad_internal_bridge/ios/Classes/KartPadCoreABI.h").read_text()
plugin = (ROOT / "packages/kartpad_internal_bridge/ios/Classes/KartPadInternalBridgePlugin.mm").read_text()
manager = (ROOT / "lib/services/game_launch_manager.dart").read_text()
patcher = (ROOT / "build-utils/kartpad/patch_donor_session_bridge.py").read_text()

for token in (
    "NEO_KARTPAD_EXIT_USER_RETURN",
    "NEO_KARTPAD_EXIT_LANGUAGE_RESTART",
    "NEO_KARTPAD_EXIT_NORMAL_TERMINATION",
    "NEO_KARTPAD_EXIT_LAUNCH_FAILURE",
    "NEO_KARTPAD_EXIT_RUNTIME_FAILURE",
    "NEO_KARTPAD_EXIT_CRASH",
    "last_exit_reason",
):
    assert token in abi, token

assert "restartAfterShutdown" not in control
assert "restartLanguage" not in control
assert "ReturnToNeoStation(NEO_KARTPAD_EXIT_LANGUAGE_RESTART)" in control
assert "requestedExitReason = reason" in core
assert "lastExitReason.store(exitReason" in core
assert "caught RuntimeMain exception" in core
assert "RuntimeMainOnUIKitThread();\n        PollForRuntimeWindow(0);" not in core
assert "finishReusable()" in core

for token in (
    "_launchCompletionDelivered",
    "_terminationDelivered",
    "ExitReasonName",
    '@"exitReason"',
    'exitReason == NEO_KARTPAD_EXIT_LANGUAGE_RESTART',
    "restartFreshSessionForTransaction",
    'invokeMethod:@"sessionRestarted"',
    "hostResult=languageRestart",
):
    assert token in plugin, token

# A language restart is consumed internally by the bridge. It cannot become a
# terminal Flutter session event and the manager defensively ignores one.
assert "if (exitReason == 'languageRestart') return;" in manager
assert "exitReason == 'userReturn'" in manager
assert "exitReason == 'runtimeFailure'" in manager

# The pinned runtime itself is made reentrant only at the verified post-freeze
# profile-selection branch; this prevents the second RuntimeMain exception.
for token in (
    "SELECT_PROFILE_SHA",
    "SELECT_FROZEN_ORIGINAL = 0x540002A0",
    "SELECT_FROZEN_RETURN = 0x10005A0FC",
    "reentrantFrozenProfile",
):
    assert token in patcher, token

print("PASS: explicit exit reasons, single completion, host-owned language restart, and reentrant pinned profile")
