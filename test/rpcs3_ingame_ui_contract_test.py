#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
plugin = (root / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
abi = (root / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h').read_text()
overlay = (root / 'packages/rpcs3_internal_bridge/ios/Classes/RPCS3PerformanceOverlay.mm').read_text()
localization = (root / 'packages/rpcs3_internal_bridge/ios/Classes/RPCS3InGameLocalization.mm').read_text()
grid = (root / 'lib/widgets/game_view_footer.dart').read_text()
grid_screen = (root / 'lib/screens/game_screen/my_games_grid.dart').read_text()
podspec = (root / 'packages/rpcs3_internal_bridge/ios/rpcs3_internal_bridge.podspec').read_text()
build = (root / 'build-utils/build_rpcs3_embedded_core.sh').read_text()

# Grid mode hides both identity strings while preserving the old footer geometry.
assert 'showTitle: false' in grid_screen
for token in ['Visibility(', 'visible: showTitle', 'maintainSize: true', 'isActive: showTitle']:
    assert token in grid, token
assert 'showTitle && game.showRomFileNameSubtitle' in grid
assert 'height: 32.r' in grid, 'PLAY/action sizing must remain untouched'

# RPCS3 owns an isolated AVAudioSession only while its embedded session is live.
for token in [
    'setPreferredSampleRate:48000.0',
    'setPreferredIOBufferDuration:(512.0 / 48000.0)',
    'audio_session_active',
    'AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation',
]:
    assert token in plugin, token
assert "'AVFAudio'" in podspec

# Menu actions and performance UI are native to RPCS3, independent of Dolphin.
for token in [
    'localized:@"language"', 'localized:@"createState"', 'localized:@"loadState"',
    'chart.xyaxis.line', 'RPCS3PerformanceOverlay',
    'get_performance_metrics', 'system.language',
    'neostation_rpcs3_ios_save_state', 'neostation_rpcs3_ios_enumerate_savestates_live',
    'topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:70',
    'performance.topAnchor constraintEqualToAnchor:menu.bottomAnchor constant:8',
    'bringSubviewToFront:self.menuButton',
    'bringSubviewToFront:self.performanceButton',
]:
    assert token in plugin or token in abi, token
assert 'performance.leadingAnchor constraintEqualToAnchor:menu.trailingAnchor' not in plugin
for token in ['setLocaleIdentifier:', 'RPCS3LocalizedString(@"performance"',
              'RPCS3LocalizedString(@"memory"', 'RPCS3LocalizedString(@"frameTime"']:
    assert token in plugin or token in overlay, token
for locale in ['de', 'en', 'es', 'fr', 'id', 'it', 'ja', 'ko', 'pt', 'ru', 'zh', 'zh_Hant']:
    assert f'@"{locale}": @{{' in localization, locale
for key in [
    'menu', 'performance', 'enabled', 'disabled', 'ok', 'cancel',
    'language', 'languageTitle', 'languageRestart', 'createState',
    'loadState', 'quitGame', 'state', 'states', 'stateStarted', 'noStates',
    'unknownDate', 'incompatible', 'incompatibleState', 'memory', 'frameTime',
]:
    assert localization.count(f'@"{key}":') == 12, key
for hardcoded in ['@"Langue"', '@"Créer une savestate"', '@"Charger une savestate"',
                  '@"Quitter le jeu"', '@"Frame time (ms) · 60 s"']:
    assert hardcoded not in plugin and hardcoded not in overlay, hardcoded
assert 'uiLocale' in plugin

# Core build must apply and verify the private session/audio patch every time.
assert 'patch_rpcs3_neostation_session.py' in build
assert 'rpcs3_neostation_session_patch_test.py' in build
print('RPCS3 in-game UI/audio integration contract: OK')
