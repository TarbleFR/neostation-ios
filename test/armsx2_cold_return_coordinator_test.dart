import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('integrated ARMSX2 launch arms independent sync and PS2 return markers', () {
    final launcher = File(
      'lib/services/ios_shortcut_jit_launch_service.dart',
    ).readAsStringSync();

    expect(launcher, contains('Armsx2ReturnStateService.arm()'));
    expect(launcher, contains('StikJitArmsx2Service.isExperimentalEnabled'));
    expect(launcher, contains('StikJitArmsx2Service.launch(gameUrl: input)'));
    expect(launcher, contains('Armsx2ReturnStateService.clearAll()'));
    expect(
      launcher,
      contains('StikDebug fallback deliberately carries no ARMSX2 recovery marker'),
    );

    final state = File(
      'lib/services/armsx2_return_state_service.dart',
    ).readAsStringSync();
    expect(state, contains('ios_armsx2_neosync_pending_v1'));
    expect(state, contains('ios_armsx2_library_return_pending_v1'));
    expect(state, contains('clearPendingSync'));
    expect(state, contains('clearPendingLibraryReturn'));
  });

  test('cold ARMSX2 return restores PS2 and syncs ARMSX2 only', () {
    final coordinator = File(
      'lib/widgets/armsx2_cold_return_coordinator.dart',
    ).readAsStringSync();

    expect(coordinator, contains('GameSessionPersistence.hasActiveSession()'));
    expect(coordinator, contains('GameSessionPersistence.clearActiveGameSession()'));
    expect(coordinator, contains("getSystemByFolderName('ps2')"));
    expect(coordinator, contains('SystemGamesList('));
    expect(coordinator, contains('ConfigService.linkedArmsx2SaveFolderPath'));
    expect(coordinator, contains('NeoSyncAdapter.kProviderId'));
    expect(coordinator, contains('autoSyncArmsx2UploadsOnly()'));
    expect(coordinator, isNot(contains('await neoSync.autoSyncUploads()')));
    expect(coordinator, contains('clearPendingLibraryReturn()'));
    expect(coordinator, contains('clearPendingSync()'));

    final provider = File(
      'lib/providers/neo_sync_provider.dart',
    ).readAsStringSync();
    expect(provider, contains('Future<bool> autoSyncArmsx2UploadsOnly()'));
    expect(provider, contains("const categories = <String>['memcards', 'savestates', 'sstates']"));
    expect(provider, contains('NeoSyncUpload(this)._uploadArmsx2File('));
    expect(provider, isNot(contains('autoSyncArmsx2UploadsOnly() async {\n    await autoSyncUploads()')));
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
