import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/armsx2_folder_service.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('neostation-armsx2-isolated-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('prefers iso and scans games nested below it', () async {
    final nested = await Directory(
      path.join(temp.path, 'iso', 'Dragon Ball'),
    ).create(recursive: true);
    await File(path.join(nested.path, 'Budokai 2.chd')).writeAsBytes(<int>[0]);
    await Directory(path.join(temp.path, 'memcards')).create();

    final gameDir = await Armsx2FolderService.resolveGameDirectory(temp.path);

    expect(path.normalize(gameDir!), path.normalize(path.join(temp.path, 'iso')));
  });

  test('accepts isos games roms and a custom nested library', () async {
    for (final name in const <String>['isos', 'games', 'roms']) {
      final dir = await Directory(path.join(temp.path, name)).create();
      expect(
        path.normalize((await Armsx2FolderService.resolveGameDirectory(temp.path))!),
        path.normalize(dir.path),
      );
      await dir.delete(recursive: true);
    }

    final custom = Directory(path.join(temp.path, 'My PS2 Library'));
    final nested = await Directory(path.join(custom.path, 'RPG')).create(
      recursive: true,
    );
    await File(path.join(nested.path, 'Game.iso')).writeAsBytes(<int>[0]);

    final gameDir = await Armsx2FolderService.resolveGameDirectory(temp.path);
    expect(path.normalize(gameDir!), path.normalize(custom.path));
  });

  test('never treats save folders as the PS2 library', () async {
    final memcards = await Directory(path.join(temp.path, 'memcards')).create();
    await File(path.join(memcards.path, 'Mcd001.ps2')).writeAsBytes(<int>[0]);
    final states = await Directory(path.join(temp.path, 'sstates')).create();
    await File(path.join(states.path, 'state.bin')).writeAsBytes(<int>[0]);

    expect(await Armsx2FolderService.resolveGameDirectory(temp.path), isNull);
  });

  test('NeoSync resolves only ARMSX2 save folders from the same root', () async {
    await Directory(path.join(temp.path, 'iso')).create();
    final memcards = await Directory(path.join(temp.path, 'memcards')).create();
    final states = await Directory(path.join(temp.path, 'sstates')).create();
    final saveStates = await Directory(path.join(temp.path, 'savestates')).create();

    final saves = (await Armsx2FolderService.resolveSaveDirectories(temp.path))
        .map(path.normalize)
        .toSet();

    expect(saves, contains(path.normalize(memcards.path)));
    expect(saves, contains(path.normalize(states.path)));
    expect(saves, contains(path.normalize(saveStates.path)));
    expect(saves, isNot(contains(path.normalize(path.join(temp.path, 'iso')))));
  });

  test('old direct child links promote back to the ARMSX2 root', () async {
    final iso = await Directory(path.join(temp.path, 'iso')).create();
    final memcards = await Directory(path.join(temp.path, 'memcards')).create();
    final states = await Directory(path.join(temp.path, 'sstates')).create();

    for (final child in <Directory>[iso, memcards, states]) {
      expect(
        path.normalize(await Armsx2FolderService.resolveRoot(child.path)),
        path.normalize(temp.path),
      );
    }
  });

  test('ownership never captures a RetroArch path', () async {
    final armsx2Root = await Directory(path.join(temp.path, 'ARMSX2')).create();
    final armsx2Iso = await Directory(path.join(armsx2Root.path, 'iso')).create();
    final armsGame = await File(path.join(armsx2Iso.path, 'Game.iso'))
        .writeAsBytes(<int>[0]);

    final retroRoot = await Directory(path.join(temp.path, 'RetroArch')).create();
    final retroPs2 = await Directory(path.join(retroRoot.path, 'Games', 'ps2'))
        .create(recursive: true);
    final retroGame = await File(path.join(retroPs2.path, 'Game.iso'))
        .writeAsBytes(<int>[0]);

    expect(
      Armsx2FolderService.ownsRomPath(armsGame.path, armsx2Root.path),
      isTrue,
    );
    expect(
      Armsx2FolderService.ownsRomPath(retroGame.path, armsx2Root.path),
      isFalse,
    );
    expect(
      Armsx2FolderService.ownsRomPath(
        'armsx2://launch?game=Game.iso',
        armsx2Root.path,
      ),
      isTrue,
    );
  });
}
