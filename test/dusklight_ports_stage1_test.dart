import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Ports exposes only the embedded Dusklight iOS engine', () {
    final root = jsonDecode(File('assets/systems/ports.json').readAsStringSync())
        as Map<String, dynamic>;
    final system = Map<String, dynamic>.from(root['system'] as Map);
    final emulators = (root['emulators'] as List).cast<Map>();

    expect(system['id'], 'ports');
    expect(
      (system['extensions'] as List).toSet(),
      containsAll(<String>['iso', 'gcm', 'rvz', 'wia', 'wbfs', 'ciso', 'gcz']),
    );
    expect(emulators, hasLength(1));
    expect(emulators.single['name'], 'Dusklight');
    expect(emulators.single['unique_id'], 'ports.ios.dusklight');
    expect(
      (emulators.single['platforms'] as Map)['ios']['embedded'],
      isTrue,
    );
  });

  test('Dusklight import owns an atomic private library', () {
    final service = File(
      'lib/services/dusklight_internal_service.dart',
    ).readAsStringSync();
    for (final folder in <String>[
      "'Ports'",
      "'Dusklight'",
      "'Games'",
      "'Saves'",
      "'Config'",
      "'Mods'",
      "'Metadata'",
    ]) {
      expect(service, contains(folder));
    }
    expect(service, contains(".part');"));
    expect(service, contains('Copied file length mismatch'));
    expect(service, contains('_hasSupportedRawDiscId'));
    for (final id in <String>[
      'GZ2E01',
      'GZ2J01',
      'GZ2P01',
      'RZDE01',
      'RZDJ01',
      'RZDP01',
    ]) {
      expect(service, contains("'$id'"));
    }
  });

  test('Ports scan and launch remain isolated from generic iOS fallback', () {
    final scanning = File(
      'lib/providers/sqlite_config_provider/scanning.dart',
    ).readAsStringSync();
    final launcher = File(
      'lib/services/game/game_launch_service.dart',
    ).readAsStringSync();
    final playlist = File(
      'lib/screens/game_screen/my_games_list.dart',
    ).readAsStringSync();

    expect(scanning, contains('refreshDusklightInternalLibrary'));
    expect(scanning, contains('DusklightInternalService.gamesDirectory'));
    final portsRoute = launcher.indexOf(
      "system.folderName.toLowerCase() == 'ports'",
    );
    final genericIosRoute = launcher.indexOf(
      'if (Platform.isIOS) {',
      portsRoute,
    );
    expect(portsRoute, greaterThanOrEqualTo(0));
    expect(genericIosRoute, greaterThan(portsRoute));
    expect(playlist, contains('DusklightInternalPlaylistActions'));
  });
}
