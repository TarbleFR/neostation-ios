import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/game_file_deletion.dart';
import 'package:neostation/services/rpcs3_game_deletion.dart';
import 'package:neostation/services/rpcs3_library_service.dart';
import 'package:path/path.dart' as path;

import 'database_test_helper.dart';

void main() {
  final helper = DatabaseTestHelper();
  late Directory temp;
  late dynamic db;
  setUp(() async {
    db = await helper.setUp();
    temp = await Directory.systemTemp.createTemp('neostation-delete-');
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('snes', 'SNES', 'snes')",
    );
  });
  tearDown(() async {
    await helper.tearDown();
    await temp.delete(recursive: true);
  });

  Future<void> insert(String rom) async {
    await db.execute(
      "INSERT INTO user_roms (app_system_id, filename, rom_path) VALUES ('snes', 'game.sfc', ?)",
      [rom],
    );
  }

  Future<void> remove(String rom) => GameRepository.deleteGame(
    appSystemId: 'snes',
    filename: 'game.sfc',
    systemFolderName: 'snes',
    romBaseName: 'game',
    romPath: rom,
  );

  test(
    'file is removed before its SQLite row, and retry is idempotent',
    () async {
      final file = File(path.join(temp.path, 'game.sfc'));
      await file.writeAsString('rom');
      await insert(file.path);
      await remove(file.path);
      expect(await file.exists(), isFalse);
      expect(await db.rawQuery('SELECT * FROM user_roms'), isEmpty);
      await remove(file.path);
    },
  );

  test(
    'filesystem error preserves the DB row and is returned to the caller',
    () async {
      final folder = Directory(path.join(temp.path, 'game.sfc'));
      await folder.create();
      await File(path.join(folder.path, 'keep')).writeAsString('other game');
      await insert(folder.path);
      await expectLater(
        remove(folder.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await db.rawQuery('SELECT * FROM user_roms'), hasLength(1));
      expect(await File(path.join(folder.path, 'keep')).exists(), isTrue);
    },
  );

  test(
    'unavailable parent is not mistaken for an already deleted file',
    () async {
      final missing = path.join(temp.path, 'unavailable', 'game.sfc');
      await insert(missing);
      await expectLater(remove(missing), throwsA(isA<FileSystemException>()));
      expect(await db.rawQuery('SELECT * FROM user_roms'), hasLength(1));
    },
  );

  test('virtual paths are never silently passed to File.delete', () async {
    await expectLater(
      GameFileDeletion.delete('rpcs3-library://game?title-id=BLES00113'),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      GameFileDeletion.delete('retroarch-library://game/1'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('PS3 folder + legacy disc alias + update removed; saves and other games retained', () async {
    Future<File> file(String name) async {
      final value = File(path.join(temp.path, name));
      await value.parent.create(recursive: true);
      await value.writeAsString('fixture');
      return value;
    }

    final extracted = await file(
      'games/ExtractedGames/BLES00113/PS3_GAME/USRDIR/EBOOT.BIN',
    );
    final disc = await file('games/discImgs/BLES00113/game.iso');
    final update = await file(
      'dev_hdd0/game/BLES00113_UPDATE/USRDIR/EBOOT.BIN',
    );
    final other = await file(
      'games/ExtractedGames/BLES00114/PS3_GAME/USRDIR/EBOOT.BIN',
    );
    final save = await file(
      'dev_hdd0/home/00000001/savedata/BLES00113/save.dat',
    );
    final state = await file('savestates/BLES00113.state');
    final firmware = await file('dev_flash/sys/external/lib.sprx');
    final registrations = await file('games.yml');
    await registrations.writeAsString(
      'BLES00113: "/wrong/other-game"\nBLES00114: "keep"\n',
    );
    await Rpcs3GameDeletion.delete(dataRoot: temp.path, titleId: 'BLES00113');
    for (final removed in [extracted, disc, update]) {
      expect(await removed.exists(), isFalse);
    }
    for (final kept in [other, save, state, firmware]) {
      expect(await kept.exists(), isTrue);
    }
    expect(await registrations.readAsString(), 'BLES00114: "keep"\n');
    expect(
      (await Rpcs3LibraryService.discoverLibrary(temp.path))
          .where((g) => g.titleId == 'BLES00113'),
      isEmpty,
    );
    await Rpcs3GameDeletion.delete(dataRoot: temp.path, titleId: 'BLES00113');
  });

  test(
    'PS3 rejects linked installation before deleting any title files',
    () async {
      final outside = Directory(path.join(temp.path, 'outside'));
      await outside.create();
      final keep = File(path.join(outside.path, 'keep'));
      await keep.writeAsString('keep');
      final root = Directory(path.join(temp.path, 'Data/games/ExtractedGames'));
      await root.create(recursive: true);
      await Link(path.join(root.path, 'BLES00113')).create(outside.path);
      await expectLater(
        Rpcs3GameDeletion.delete(
          dataRoot: path.join(temp.path, 'Data'),
          titleId: 'BLES00113',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await keep.readAsString(), 'keep');
    },
  );

  test('PS3 rejects a title ID containing path traversal', () async {
    await expectLater(
      Rpcs3GameDeletion.delete(dataRoot: temp.path, titleId: '../savedata'),
      throwsArgumentError,
    );
  });
}
