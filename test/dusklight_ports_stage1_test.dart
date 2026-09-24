import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Ports keeps Dusklight playable and advertises Mario Kart Wii', () {
    final root = jsonDecode(File('assets/systems/ports.json').readAsStringSync())
        as Map<String, dynamic>;
    final system = Map<String, dynamic>.from(root['system'] as Map);
    final emulators = (root['emulators'] as List).cast<Map>();

    expect(system['id'], 'ports');
    expect(
      (system['details'] as Map)['notable_games'],
      containsAll(<String>[
        'The Legend of Zelda: Twilight Princess',
        'Mario Kart Wii',
      ]),
    );
    expect(emulators, hasLength(1));
    expect(emulators.single['name'], 'Dusklight');
    expect(emulators.single['unique_id'], 'ports.ios.dusklight');
    expect((emulators.single['platforms'] as Map)['ios']['embedded'], isTrue);
  });

  test('KartPad owns a strict private PAL RMCP01 user import', () {
    final service =
        File('lib/services/kartpad_internal_service.dart').readAsStringSync();
    for (final folder in <String>[
      "'Ports'",
      "'KartPad'",
      "'Games'",
      "'Saves'",
      "'Config'",
      "'Mods'",
      "'Logs'",
      "'Metadata'",
    ]) {
      expect(service, contains(folder));
    }
    expect(service, contains("supportedDiscId = 'RMCP01'"));
    expect(service, contains('supportedDiscNumber = 0'));
    expect(service, contains('supportedRevision = 0'));
    expect(service, contains('0x5D1C9EA3'));
    expect(service, contains("'Mario Kart Wii'"));
    expect(
      service,
      contains("supportedGameExtensions = <String>{'iso', 'wbfs'}"),
    );
    expect(service, contains("MethodChannel('neostation/dolphin_internal')"));
    expect(service, contains("'saveIdentity'"));
    expect(service, contains(r"File('${output.path}.part')"));
  });

  test('Ports exposes one Import menu with DuskLight and Mario Kart Pad', () {
    final widget =
        File('lib/widgets/ports_internal_playlist_actions.dart')
            .readAsStringSync();
    expect(widget, contains("ValueKey('ports-internal-import')"));
    expect(widget, contains("'import'"));
    expect(widget, contains("'dusklight'"));
    expect(widget, contains("'kartpad'"));
    expect(widget, contains('DusklightInternalService.importGames()'));
    expect(widget, contains('KartPadInternalService.importGame()'));
  });

  test('Ports scan and launch isolate KartPad from Dusklight', () {
    final scanning =
        File('lib/providers/sqlite_config_provider/scanning.dart')
            .readAsStringSync();
    final launcher =
        File('lib/services/game/game_launch_service.dart').readAsStringSync();
    final playlist =
        File('lib/screens/game_screen/my_games_list.dart').readAsStringSync();

    expect(scanning, contains('refreshPortsInternalLibrary'));
    expect(scanning, contains('DusklightInternalService.rootDirectory'));
    expect(scanning, contains('KartPadInternalService.rootDirectory'));
    expect(scanning, contains('KartPadInternalService.gamesDirectory'));

    final portsRoute =
        launcher.indexOf("system.folderName.toLowerCase() == 'ports'");
    final kartPadDispatch =
        launcher.indexOf('KartPadInternalService.ownsGamePath', portsRoute);
    final dusklightLaunch =
        launcher.indexOf('DusklightInternalService.launch', portsRoute);
    expect(portsRoute, greaterThanOrEqualTo(0));
    expect(kartPadDispatch, greaterThan(portsRoute));
    expect(dusklightLaunch, greaterThan(kartPadDispatch));

    expect(playlist, contains('PortsInternalPlaylistActions'));
    expect(playlist, contains('_buildPortsImportAction'));
    expect(playlist, contains('_buildEmbeddedPortsImportAction'));
  });
}
