import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ARMSX2 launch arms independent sync and PS2 return markers', () {
    final launcher = File(
      'lib/services/ios_shortcut_jit_launch_service.dart',
    ).readAsStringSync();

    expect(launcher, contains('Armsx2ReturnStateService.arm()'));
    expect(launcher, contains('shortcutName == armsx2ShortcutName'));
    expect(launcher, contains('Armsx2ReturnStateService.clearAll()'));

    final state = File(
      'lib/services/armsx2_return_state_service.dart',
    ).readAsStringSync();
    expect(state, contains('ios_armsx2_neosync_pending_v1'));
    expect(state, contains('ios_armsx2_library_return_pending_v1'));
    expect(state, contains('clearPendingSync'));
    expect(state, contains('clearPendingLibraryReturn'));
  });

  test('cold ARMSX2 return restores PS2 and syncs dedicated save root', () {
    final coordinator = File(
      'lib/widgets/armsx2_cold_return_coordinator.dart',
    ).readAsStringSync();

    expect(coordinator, contains('GameSessionPersistence.hasActiveSession()'));
    expect(coordinator, contains('GameSessionPersistence.clearActiveGameSession()'));
    expect(coordinator, contains("getSystemByFolderName('ps2')"));
    expect(coordinator, contains('SystemGamesList('));
    expect(coordinator, contains('ConfigService.linkedArmsx2SaveFolderPath'));
    expect(coordinator, contains('NeoSyncAdapter.kProviderId'));
    expect(coordinator, contains('await neoSync.autoSyncUploads()'));
    expect(coordinator, contains('clearPendingLibraryReturn()'));
    expect(coordinator, contains('clearPendingSync()'));
  });

  test('MainScreen installs ARMSX2 cold-return coordinator', () {
    final mainScreen = File('lib/screens/main_screen.dart').readAsStringSync();
    expect(mainScreen, contains('Armsx2ColdReturnCoordinator'));
    expect(
      mainScreen,
      contains('Armsx2ColdReturnCoordinator(child: AppScreen())'),
    );
  });
}
