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
candidate_workflow = (ROOT / '.github/workflows/ios-ci.yml').read_text()
embedder = (ROOT / 'build-utils/kartpad/embed_core.py').read_text()
ipa_validator = (ROOT / 'build-utils/validate_kartpad_ipa.py').read_text()
donor_core = (ROOT / 'native/kartpad/donor/NeoKartPadDonorCore.mm').read_text()
language_patcher = (ROOT / 'build-utils/kartpad/patch_donor_language_bridge.py').read_text()
ports_locale = (ROOT / 'lib/l10n/ports_locale.dart').read_text()

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
assert 'NeoKartPad_PrepareUserGame' in plugin
assert "'prepareGame'" in dart_bridge
assert 'dlclose(' not in plugin
assert "MethodChannel('neostation/kartpad_internal')" in dart_bridge
assert 'sessionEvents' in dart_bridge and 'sessionEnded' in dart_bridge
assert 'KartPadInternalBridge.launch' in service
assert 'KartPadInternalBridge.prepareGame' in service
assert "'ios_kartpad_internal'" in launcher
assert 'KartPadInternalBridge.sessionEvents.listen' in manager
assert "'ios_kartpad_internal'" in manager
assert 'if (_isEmbeddedIOSSession) return false;' in manager
for token in (
    'NeoKartPadGameLanguage',
    'WriteGameLanguageSysConf',
    '"IPL.LNG"',
    '@[@1, @2, @3, @4, @5, @6]',
    '"languageEnglish"',
    '"languageGerman"',
    '"languageFrench"',
    '"languageSpanish"',
    '"languageItalian"',
    '"languageDutch"',
    'game language=%ld persisted to Wii IPL.LNG',
    'com.neostation.kartpad.runtime-language',
    'PatchKartPadRuntimeMenuButton',
    'menuByReplacingChildren',
    'NSClassFromString(@"KartPadGameOverlay")',
    'NeoStationKartPadOverlayLayoutSubviews',
    'KartPadPreferredGame',
    'NeoStationKartPadShowLaunchPreference',
    'ignored KartPad On Launch chooser',
    'button.enabled = NO',
    'KartPadAutoAccelerate',
    'auto-accelerate lock forced off',
    'NeoStationKartPadAutoAccelerateChanged',
    'advanced-graphics',
    'disable_copy_filter',
    'disabled_post_processing_paths',
    'skip_unready_pipelines',
    'frame_interpolation_fps',
    'dev.kartpad.display',
    'kNeoKartPadPatchedMenuKey',
    'kNeoKartPadMenuActionInFlight',
    'ScheduleNativeMenuRefresh',
    'KartPadSettingsIOQueue',
    'ApplyLiveLanguageAndRestartGame',
    'SetRuntimeLanguageOverride',
    'g_dynamicAspectRatioEnabled',
    'com.neostation.kartpad.return-to-game',
    '"returnToGame"',
    'func_80635A3C',
    'func_80635AC8',
    '0x809C1E38u',
    '0x40u',
    '0x000000FFu',
    'TitleFromReset requested',
):
    assert token in donor_core, token

# The native three-dot menu must expose language at root, not bury it inside
# Display, and it must not rebuild itself synchronously from a UIAction.
assert '[children insertObject:returnToGame atIndex:0]' in donor_core
assert '[children insertObject:languageMenu' in donor_core
assert 'atIndex:MIN(languageIndex, children.count)' in donor_core
assert 'menuButton.menu == lastPatched' in donor_core
assert 'dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC))' in donor_core
assert 'std::exit(0)' not in donor_core
assert 'PresentRestartRequired' not in donor_core
assert 'func_801B11C4' not in donor_core
assert 'KartPadGuestWrite8Fn' not in donor_core
for token in (
    'SCGETLANGUAGE_SYMBOL = "_func_801B1D0C"',
    'ASPECT_SYMBOL = "_g_dynamicAspectRatioEnabled"',
    'EXPECTED_PROLOGUE = bytes.fromhex("f85fbca9f65701a9f44f02a9")',
    'encode_adrp',
    'encode_ldrb_w',
):
    assert token in language_patcher, token
assert "'languageRestartHint'" in ports_locale
for token in (
    "'restartRequiredTitle'", "'languageRestartMessage'",
    "'graphicsRestartMessage'", "'advancedGraphics'",
    "'sharperPicture'", "'disableBloom'", "'skipShaders'",
    "'frameInterpolation'",
):
    assert token in ports_locale, token
assert pins['release'] == 'v0.5.1-experimental.1'
assert pins['compiledSource'] == '67c7e2f942c1226af149e6a9cc571f647528e25e'
assert pins['discProfile']['expectedTranslatedFunctions'] == 29637
assert pins['runtimeIdentity'] == 'kartpad_rmcp01_full_game_v1'
for token in (
    'kartpad_core_run_id',
    'kartpad_core_host_sha',
    'KARTPAD_CANDIDATE',
    'Download validated KartPad Core candidate',
    'Embed validated KartPad Core candidate',
    'validate_kartpad_ipa.py',
    'KartPad candidates must not reuse the stable Build 322 number.',
):
    assert token in candidate_workflow, token
assert 'KartPadCore.framework' in embedder
assert 'KartPad-native-identity.json' in embedder
assert 'KartPad.app/' in ipa_validator
assert 'passiveLoad' in ipa_validator
print('PASS: KartPad ABI v1, lazy loader, launch route and session monitor are wired')
