import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/retroarch_folder_recovery.dart';
import 'package:neostation/services/retroarch_library_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

SystemModel system(String folder) => SystemModel(
  id: folder,
  realName: folder,
  folderName: folder,
  iconImage: '',
  color: '#000000',
  recursiveScan: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory temp;
  setUp(() async {
    db = await helper.setUp();
    temp = await Directory.systemTemp.createTemp('ra-restoration-');
    await db.insert('app_systems', {
      'id': 'gba',
      'folder_name': 'gba',
      'real_name': 'Game Boy Advance',
      'manufacturer': 'Nintendo',
    });
    await db.insert('app_system_folders', {
      'system_id': 'gba',
      'folder_name': 'gba',
    });
    await db.insert('app_system_extensions', {
      'system_id': 'gba',
      'extension': 'gba',
    });
  });
  tearDown(() async {
    await helper.tearDown();
    await temp.delete(recursive: true);
  });

  test(
    'five stale sources cannot block a newly bookmarked library or erase rows',
    () async {
      final stale = List.generate(5, (i) => '${temp.path}/old-$i');
      final active = Directory('${temp.path}/RetroArch');
      final games = Directory('${active.path}/Bibliothèques /gba');
      await games.create(recursive: true);
      await File('${games.path}/Recovered.gba').writeAsString('rom');
      await db.insert('user_roms', {
        'app_system_id': 'gba',
        'rom_path': '${stale.first}/gba/Favorite.gba',
        'filename': 'Favorite.gba',
        'is_favorite': 1,
        'play_time': 999,
      });
      await db.insert('user_detected_systems', {
        'app_system_id': 'gba',
        'actual_folder_name': 'gba',
        'is_hidden': 1,
      });
      final roots = await RetroArchFolderRecovery.reconcileResolved(
        roots: [...stale, stale.first],
        systemFolders: ['gba'],
        active: active.path,
        previous: null,
        db: db,
        prefs: await SharedPreferences.getInstance(),
      );
      expect(roots, [...stale, '${active.path}/Bibliothèques ']);
      expect((await db.query('user_rom_folders')).length, 6);
      final scan = await SqliteDatabaseService.scanSystemRoms(
        system('gba'),
        roots,
        preserveUnscannedSources: true,
      );
      expect(scan.removed, 0);
      expect((await db.query('user_roms')).length, 2);
      final favorite = (await db.query(
        'user_roms',
        where: 'is_favorite = 1',
      )).single;
      expect(favorite['play_time'], 999);
      await SqliteService.updateDetectedSystems([]);
      expect((await db.query('user_detected_systems')).single['is_hidden'], 1);
      final kept = await RetroArchFolderRecovery.reconcileResolved(
        roots: roots,
        systemFolders: ['gba'],
        active: null,
        previous: active.path,
        db: db,
        prefs: await SharedPreferences.getInstance(),
      );
      expect(kept, roots);
    },
  );

  test(
    'scan prunes missing games only inside directories successfully walked',
    () async {
      final root = Directory('${temp.path}/live');
      await Directory('${root.path}/gba').create(recursive: true);
      for (final romPath in [
        '${root.path}/gba/deleted.gba',
        '${temp.path}/missing/gba/retained.gba',
        RetroArchLibraryImporter.libraryPath(
          'Nintendo - Game Boy Advance',
          'export.gba',
        ),
      ]) {
        await db.insert('user_roms', {
          'app_system_id': 'gba',
          'rom_path': romPath,
          'filename': 'game.gba',
        });
      }
      final summary = await SqliteDatabaseService.scanSystemRoms(
        system('gba'),
        [root.path, '${temp.path}/missing'],
        preserveUnscannedSources: true,
      );
      expect(summary.removed, 1);
      expect((await db.query('user_roms')).length, 2);
      await db.insert('user_roms', {
        'app_system_id': 'gba',
        'rom_path': '${root.path}/inaccessible/retained.gba',
        'filename': 'retained.gba',
        'is_favorite': 1,
        'play_time': 321,
      });
      final failure = await SqliteDatabaseService.scanSystemRoms(
        system('gba'),
        [root.path],
        preserveUnscannedSources: true,
        rootFoldersMap: {
          root.path: {'gba': '${root.path}/inaccessible'},
        },
      );
      expect(failure.removed, 0);
      expect((await db.query('user_roms')).length, 3);
      expect(
        (await db.query(
          'user_roms',
          where: 'is_favorite = 1',
        )).single['play_time'],
        321,
      );
    },
  );

  test(
    'export restores 4842 games idempotently while preserving favorites and native ownership',
    () async {
      final entries = List.generate(
        4842,
        (i) => <String, dynamic>{
          'filename': 'Game $i.gba',
          'titleId': 'Game $i.gba',
          'titleName': 'Game $i',
          'system': 'Nintendo - Game Boy Advance',
        },
      );
      expect(await RetroArchLibraryImporter.restore(db, entries), 4842);
      final favoritePath = RetroArchLibraryImporter.libraryPath(
        'Nintendo - Game Boy Advance',
        'Game 0.gba',
      );
      await db.update(
        'user_roms',
        {'is_favorite': 1, 'play_time': 120},
        where: 'rom_path = ?',
        whereArgs: [favoritePath],
      );
      expect(await RetroArchLibraryImporter.restore(db, entries), 4842);
      expect((await db.query('user_roms')).length, 4842);
      expect(
        (await db.query(
          'user_roms',
          where: 'is_favorite = 1',
        )).single['play_time'],
        120,
      );
      await db.insert('app_systems', {
        'id': 'gc',
        'folder_name': 'gc',
        'real_name': 'GameCube',
        'manufacturer': 'Nintendo',
      });
      expect(
        await RetroArchLibraryImporter.restore(db, [
          {'filename': 'Native.iso', 'system': 'Nintendo - GameCube'},
        ]),
        0,
      );
      expect((await db.query('user_roms')).length, 4842);
    },
  );

  test('embedded tiles remain available before a successful external scan', () {
    final all = [
      'gba',
      'gc',
      'wii',
      'ps2',
      'ps3',
      'ports',
    ].map(system).toList();
    expect(
      SystemRepository.visibleSystems(
        all,
        [],
        isIOS: true,
        isAndroid: false,
      ).map((s) => s.folderName),
      ['gc', 'wii', 'ps2', 'ps3', 'ports'],
    );
    expect(
      SystemRepository.visibleSystems(all, [], isIOS: false, isAndroid: false),
      isEmpty,
    );
  });

  test('failed production scan terminates its loading phase', () async {
    final provider = SqliteConfigProvider();
    addTearDown(provider.dispose);
    await db.execute('DROP TABLE app_systems');
    await provider.scanSystems();
    expect(provider.error, isNotNull);
    expect(provider.isScanning, isFalse);
    expect(provider.scanCompleted, isTrue);
  });
}
