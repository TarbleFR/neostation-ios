import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RPCS3 exposes bidirectional Files save exchange for savedata and savestates', () {
    final service = File(
      'lib/services/rpcs3_internal_service.dart',
    ).readAsStringSync();
    final menu = File(
      'lib/widgets/rpcs3_internal_playlist_actions.dart',
    ).readAsStringSync();
    final manager = File(
      'lib/screens/rpcs3_manager_screen.dart',
    ).readAsStringSync();
    final iosConfiguration = File(
      'build-utils/configure_dolphin_ios_v2.py',
    ).readAsStringSync();

    for (final token in [
      "'dev_hdd0'",
      "'home'",
      "'00000001'",
      "'savedata'",
      "'Savestates'",
      "path.join(data.path, 'savestates')",
      "'Game Saves'",
      'getApplicationDocumentsDirectory()',
      "path.join(documents.path, 'RPCS3')",
      "path.join(exportRoot.path, 'Export')",
      'followLinks: false',
      'importSaveDataFromFiles',
      "path.join(exchangeRoot.path, 'Game Saves')",
      "path.join(exchangeRoot.path, 'Savestates')",
      "name.endsWith('.savestat.zst')",
      "name.endsWith('.savestat.gz')",
      "name.endsWith('.savestat')",
      'neostation-import-backup',
      "'Import/Game Saves'",
      "'Import/Savestates'",
      "'Export/Game Saves'",
      "'Export/Savestates'",
      'synchronizeFilesWorkspace',
    ]) {
      expect(service, contains(token), reason: token);
    }
    expect(service, isNot(contains("path.join(documents.path, 'Data')")));
    expect(service, contains('Firmware, games, caches, trophies'));
    expect(menu, contains("value: 'saves'"));
    expect(menu, contains("action != 'saves' && action != 'restoreSaves'"));
    expect(menu, contains("value: 'restoreSaves'"));
    expect(menu, contains('Rpcs3InternalService.importSaveDataFromFiles()'));
    expect(menu, contains('Exporter les sauvegardes'));
    expect(menu, contains('On My iPhone → NeoStation → RPCS3 → Export'));
    expect(manager, contains('rpcs3-manager-export-saves'));
    expect(manager, contains('Rpcs3InternalService.exportSaveData()'));
    expect(manager, contains('rpcs3-manager-import-saves'));
    expect(manager, contains('Rpcs3InternalService.importSaveDataFromFiles()'));
    expect(iosConfiguration, contains("payload['UIFileSharingEnabled'] = True"));
    expect(
      iosConfiguration,
      contains("payload['LSSupportsOpeningDocumentsInPlace'] = True"),
    );
  });
}
