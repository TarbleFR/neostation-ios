#!/usr/bin/env python3
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
pubspec = (ROOT / 'pubspec.yaml').read_text()
abi = (ROOT / 'packages/kartpad_internal_bridge/ios/Classes/KartPadCoreABI.h').read_text()
loader = (ROOT / 'packages/kartpad_internal_bridge/ios/Classes/KartPadCoreLoader.h').read_text()
plugin = (ROOT / 'packages/kartpad_internal_bridge/ios/Classes/KartPadInternalBridgePlugin.mm').read_text()
dart_bridge = (ROOT / 'packages/kartpad_internal_bridge/lib/kartpad_internal_bridge.dart').read_text()
service = (ROOT / 'lib/services/kartpad_internal_service.dart').read_text()
launcher = (ROOT / 'lib/services/game/game_launch_service.dart').read_text()
manager = (ROOT / 'lib/services/game_launch_manager.dart').read_text()
pins = json.loads((ROOT / 'build-utils/kartpad/source.json').read_text())

assert 'packages/kartpad_internal_bridge' in pubspec
assert 'kartpad_internal_bridge:' in pubspec
assert 'NEO_KARTPAD_ABI_VERSION 1u' in abi
assert 'kartpad_rmcp01_full_game_v1' in abi
for member in ('initialize', 'start', 'stop', 'is_running', 'set_event_callback',
               'session_state', 'set_ui_text', 'runtime_identity'):
    assert member in abi, member
assert 'dlopen(path, RTLD_NOW | RTLD_LOCAL)' in loader
assert 'dlsym(_coreHandle, "NeoKartPad_GetAPI")' in plugin
assert 'KARTPAD_RUNTIME_PROFILE_MISMATCH' in plugin
assert 'dlclose(' not in plugin
assert "MethodChannel('neostation/kartpad_internal')" in dart_bridge
assert 'sessionEvents' in dart_bridge and 'sessionEnded' in dart_bridge
assert 'KartPadInternalBridge.launch' in service
assert "'ios_kartpad_internal'" in launcher
assert 'KartPadInternalBridge.sessionEvents.listen' in manager
assert pins['release'] == 'v0.5.1-experimental.1'
assert pins['compiledSource'] == '67c7e2f942c1226af149e6a9cc571f647528e25e'
assert pins['discProfile']['expectedTranslatedFunctions'] == 29637
assert pins['runtimeIdentity'] == 'kartpad_rmcp01_full_game_v1'
print('PASS: KartPad ABI v1, lazy loader, launch route and session monitor are wired')
