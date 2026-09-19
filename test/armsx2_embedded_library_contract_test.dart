import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('embedded ARMSX2 PS2 library contract stays Files-visible', () {
    final storage = File(
      'lib/services/armsx2_internal_service.dart',
    ).readAsStringSync();
    final systems = File(
      'lib/repositories/system_repository.dart',
    ).readAsStringSync();
    final list = File(
      'lib/screens/game_screen/my_games_list.dart',
    ).readAsStringSync();
    final core = File(
      'packages/armsx2_internal_bridge/core/ARMSX2Core.mm',
    ).readAsStringSync();
    final launcher = File(
      'lib/services/stikjit_armsx2_service.dart',
    ).readAsStringSync();

    expect(storage, contains("path.join(documents.path, 'ARMSX2')"));
    expect(storage, contains("path.join(root.path, 'Games')"));
    expect(storage, contains("path.join(root.path, 'BIOS')"));
    expect(storage, contains("path.join(root.path, 'Saves')"));
    expect(storage, contains('importGames()'));
    expect(storage, contains('importBios()'));

    expect(systems, contains("const <String>['ps2', 'ps3']"));
    expect(list, contains('armsx2-internal-import-menu') == false);
    expect(list, contains('_isArmsx2Library'));
    expect(list, contains('_buildEmbeddedArmsx2ImportAction'));

    expect(core, contains('folder(saves_root,r.data,"Saves")'));
    expect(core, contains('folder(EmuFolders::MemoryCards,saves_root,"Memory Cards")'));
    expect(core, contains('folder(EmuFolders::Savestates,saves_root,"Savestates")'));

    expect(launcher, contains('Armsx2InternalService.ensureLayout()'));
    expect(launcher, contains("outside NeoStation/ARMSX2/Games"));
    expect(launcher, isNot(contains('resolveBookmarkedFolder')));
  });

  test('ARMSX2 import menu exposes BIOS and games', () {
    final widget = File(
      'lib/widgets/armsx2_internal_playlist_actions.dart',
    ).readAsStringSync();

    expect(widget, contains("ValueKey('armsx2-internal-import-menu')"));
    expect(widget, contains("'Importer des jeux'"));
    expect(widget, contains("'Importer le BIOS'"));
    expect(widget, contains('Armsx2InternalService.importGames()'));
    expect(widget, contains('Armsx2InternalService.importBios()'));
  });
}
