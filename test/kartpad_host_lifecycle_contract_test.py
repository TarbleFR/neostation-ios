#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "native/kartpad/donor/NeoKartPadDonorCore.mm").read_text()
control = (ROOT / "native/kartpad/donor/DonorSessionControl.inc").read_text()
abi = (ROOT / "packages/kartpad_internal_bridge/ios/Classes/KartPadCoreABI.h").read_text()
plugin = (ROOT / "packages/kartpad_internal_bridge/ios/Classes/KartPadInternalBridgePlugin.mm").read_text()
host_policy = (ROOT / "packages/kartpad_internal_bridge/ios/Classes/KartPadHostWindowPolicy.h").read_text()
host_selection = (ROOT / "packages/kartpad_internal_bridge/ios/Classes/KartPadHostWindowSelection.h").read_text()
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
confirmation = control.split('void ConfirmGameLanguage(', 1)[1].split('bool BeginExitTransition(', 1)[0]
assert 'commands.confirm(generation)' in confirmation
assert 'WriteGameLanguageSysConf(&persistenceError)' in confirmation
assert 'ReturnToNeoStation(NEO_KARTPAD_EXIT_LANGUAGE_RESTART)' in confirmation
assert confirmation.index('WriteGameLanguageSysConf(&persistenceError)') < confirmation.index('ReturnToNeoStation(NEO_KARTPAD_EXIT_LANGUAGE_RESTART)')
assert 'BeginExitTransition(cpu)' in control
assert 'NeoKartPadPerformRunLoop(block);' in control
assert 'languageBefore.apply' not in control
assert "requestedExitReason = reason" in core
assert "lastExitReason.store(exitReason" in core
assert "caught RuntimeMain exception" in core
assert "RuntimeMainOnUIKitThread();\n        PollForRuntimeWindow(0);" not in core
assert "finishReusable()" in core
assert core.count("RestoreNeoStationWindow();") == 2
assert 'RestoreNeoStationWindow();\n    NSLog' in core
assert 'RestoreNeoStationWindow();\n  if (session.state()' in core

for token in (
    "_launchCompletionDelivered",
    "_terminationDelivered",
    "ExitReasonName",
    '@"exitReason"',
    'exitReason == NEO_KARTPAD_EXIT_LANGUAGE_RESTART',
):
    assert token in plugin, token

# A language change closes the game and the Flutter route exactly once. The
# player relaunches it from NeoStation after the terminal event.
assert 'restartFreshSessionForTransaction' not in plugin
assert 'sessionRestarted' not in plugin
assert 'FindFlutterHostWindow(' in plugin
assert '_registrar.viewController, _hostWindow, FlutterViewController.class' in plugin
assert '_hostWindow = hostWindow;' in plugin
assert 'appendWindow(retainedWindow);' in host_selection
assert host_selection.index('appendController(flutterController);') < host_selection.index('appendWindow(retainedWindow);')
assert 'SelectHostWindow(candidates)' in host_selection
assert 'neoStationWindow = selectedHostWindow;' in core
assert 'window.isKeyWindow) { keyWindow' not in plugin
assert 'candidate.flutterOwned && candidate.attached && candidate.visible &&' in host_policy
assert "exitReason == 'languageRestart' ||" in manager
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

print("PASS: explicit exit reasons, single completion, manual language relaunch, and reentrant pinned profile")

# The behavioral Apple test must exercise the same entry as production.
assert '#include "../core/SessionRunLoop.h"' in core
assert 'runtimeEntryTimer = NeoKartPadScheduleRunLoop' in core
assert 'dispatch_async(dispatch_get_main_queue(), ^{ RuntimeMainOnUIKitThread(); });' not in core
assert 'commands = neokartpad::SessionCommands{}' not in core
assert '[runtimeWindowTimer invalidate]' in core
assert '[sessionAlertRetryTimer invalidate]' in core

# The only library-return control belongs to the settings menu, never the HUD.
assert 'returnButton' not in core
assert 'InstallReturnButton' not in core
settings_overlay = core.split('void InstallSettingsButton() {', 1)[1].split('void PollForRuntimeWindow', 1)[0]
assert 'BuildNeoKartPadSettingsMenu()' in settings_overlay
assert 'ReturnToNeoStation(' not in settings_overlay
assert 'root.safeAreaLayoutGuide.topAnchor' in settings_overlay
assert 'BuildReturnToNeoStationAction()' in core
