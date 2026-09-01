import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS emulator return persists game identity for NeoSync recovery', () {
    final sessionManager = File(
      'lib/services/game/game_session_manager.dart',
    ).readAsStringSync();
    expect(
      sessionManager,
      contains('if (Platform.isAndroid || Platform.isIOS)'),
    );
    expect(
      sessionManager,
      contains('GameSessionPersistence.saveGameSession('),
    );
    expect(
      sessionManager,
      isNot(contains('unawaited(GameSessionPersistence.markSkipStartupScan())')),
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
