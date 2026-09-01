import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS emulator return persists game identity before the native handoff', () {
    final launchUtils = File(
      'lib/utils/game_launch_utils.dart',
    ).readAsStringSync();
    expect(
      launchUtils,
      contains('await GameSessionPersistence.saveGameSession('),
    );
    expect(launchUtils, contains('systemFolderName: system.folderName'));
    expect(launchUtils, contains('filename: game.romname'));
    expect(
      launchUtils,
      contains('await GameSessionPersistence.clearGameSession();'),
    );

    // GameSessionManager keeps the lightweight #71 scan guard on iOS. The full
    // identity is written earlier by launchGameWithDialog, so there is no late
    // unawaited write that can race a cold return and resurrect stale metadata.
    final sessionManager = File(
      'lib/services/game/game_session_manager.dart',
    ).readAsStringSync();
    expect(sessionManager, contains('else if (Platform.isIOS)'));
    expect(sessionManager, contains('GameSessionPersistence.markSkipStartupScan()'));
    expect(
      sessionManager,
      isNot(contains('if (Platform.isAndroid || Platform.isIOS)')),
    );

    final persistence = File(
      'lib/services/game_session_persistence.dart',
    ).readAsStringSync();
    expect(
      persistence,
      contains('static Future<void> clearActiveGameSession()'),
    );
    expect(
      persistence,
      contains('await prefs.remove(_keyGameActive);'),
    );
    expect(
      persistence,
      contains('await prefs.remove(_keySkipStartupScan);'),
    );
  });

  test('iOS warm and cold returns trigger per-game post-close sync', () {
    final lifecycle = File(
      'lib/widgets/app_lifecycle_handler.dart',
    ).readAsStringSync();

    expect(
      lifecycle,
      contains("_recoverPendingIosGameSync(reason: 'cold-start')"),
    );
    expect(
      lifecycle,
      contains("reason: 'warm-return'"),
    );
    expect(
      lifecycle,
      contains('syncProvider.syncGameSavesAfterClose(game)'),
    );
    expect(
      lifecycle,
      contains('GameSessionPersistence.clearActiveGameSession()'),
    );
    expect(
      lifecycle,
      contains('Platform.isIOS && GameService.isGameLaunched'),
    );
    expect(
      lifecycle,
      contains('requireMinimumElapsed: true'),
    );
  });

  test('memory is released before an external game while ROM scanning stays guarded', () {
    final launchFlow = File(
      'lib/screens/game_screen/my_games_list/launch_flow.dart',
    ).readAsStringSync();
    expect(launchFlow, contains('imageCache.clear();'));
    expect(launchFlow, contains('imageCache.clearLiveImages();'));
    expect(launchFlow, contains('_games = [];'));
    expect(launchFlow, contains('context.read<SystemBackgroundProvider>().clear();'));
    expect(launchFlow, contains('GameService.loadGamesForSystem(widget.system)'));

    final appScreen = File('lib/screens/app_screen.dart').readAsStringSync();
    expect(appScreen, contains('skipIosReturnScan'));
    expect(
      appScreen,
      contains('startupScanPending && !skipIosReturnScan && mounted'),
    );
  });

  test('ARMSX2 direct-launch bridge stays isolated from NeoSync recovery', () {
    final armsx2 = File(
      'lib/services/stikjit_armsx2_service.dart',
    ).readAsStringSync();
    expect(armsx2, contains('ARMSX2_AUTOLOAD_RESUMED'));
    expect(armsx2, contains('postJitHandoffSkipped'));
    expect(armsx2, contains('targetResumed'));

    final nativeBridge = File(
      'packages/stikjit_bridge/ios/Classes/'
      'NeoStationStikjitBridgePlugin.swift',
    ).readAsStringSync();
    expect(nativeBridge, contains('ARMSX2_AUTOLOAD_SAME_PID_RESUMED'));
    expect(nativeBridge, contains('resumedPID == UInt64(originalPID)'));
  });
}
