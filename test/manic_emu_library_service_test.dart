import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/manic_emu_library_service.dart';

import 'database_test_helper.dart';

void main() {
  test('resolves both Manic Documents and Datas selections', () async {
    final root = await Directory.systemTemp.createTemp('manic_library_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final data = Directory('${root.path}/Datas')..createSync();

    expect(
      await ManicEmuLibraryService.resolveDataFolder(root.path),
      data.path,
    );
    expect(
      await ManicEmuLibraryService.resolveDataFolder(data.path),
      data.path,
    );
  });

  test('detects 3DS and CIA games in the flat Manic library', () async {
    final data = await Directory.systemTemp.createTemp('manic_datas_');
    addTearDown(() async {
      if (await data.exists()) await data.delete(recursive: true);
    });

    expect(
      await ManicEmuLibraryService.containsNintendo3dsGames(data.path),
      isFalse,
    );
    File('${data.path}/Game.cia').writeAsStringSync('game');
    expect(
      await ManicEmuLibraryService.containsNintendo3dsGames(data.path),
      isTrue,
    );
  });

  test('reads a large mixed Datas library without opening ROM contents', () async {
    final data = await Directory.systemTemp.createTemp('manic_mixed_datas_');
    addTearDown(() async {
      if (await data.exists()) await data.delete(recursive: true);
    });

    const extensions = ['nes', 'sfc', 'gba', 'gbc', 'nds', '3ds'];
    for (var index = 0; index < 60; index++) {
      final extension = extensions[index % extensions.length];
      File('${data.path}/Game $index.$extension').writeAsStringSync('rom');
    }

    expect(
      await ManicEmuLibraryService.extensionsInDataFolder(data.path),
      containsAll(extensions),
    );
  });

  test('imports a 3DS ROM from Manic Datas as an extra scan path', () async {
    final helper = DatabaseTestHelper();
    final db = await helper.setUp();
    addTearDown(helper.tearDown);
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('3ds', 'Nintendo 3DS', '3ds')",
    );
    for (final extension in ['3ds', 'cia', 'app']) {
      await db.rawInsert(
        'INSERT INTO app_system_extensions (system_id, extension) VALUES (?, ?)',
        ['3ds', extension],
      );
    }

    final root = await Directory.systemTemp.createTemp('manic_root_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final data = Directory('${root.path}/Datas')..createSync();
    File('${data.path}/Mario Kart 7.3ds').writeAsStringSync('game');

    const system = SystemModel(
      id: '3ds',
      realName: 'Nintendo 3DS',
      folderName: '3ds',
      iconImage: '',
      color: '#000000',
      recursiveScan: true,
    );
    await SqliteDatabaseService.scanSystemRoms(
      system,
      [root.path],
      additionalScanPaths: [data.path],
    );

    final games = await db.rawQuery(
      "SELECT filename FROM user_roms WHERE app_system_id = '3ds'",
    );
    expect(games.single['filename'], 'Mario Kart 7.3ds');
  });
}
