import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/retroarch_library_protocol.dart';
import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Build419 rescans and database reopen retain one physical row and user metadata',
    () async {
      final root = await Directory.systemTemp.createTemp('library-restart-');
      sqlite.Database? native;
      try {
        final folder = Directory('${root.path}/snes')..createSync();
        final rom = File('${folder.path}/Game.smc')
          ..writeAsStringSync('fixture');
        final database = '${root.path}/data.sqlite';
        native = sqlite.sqlite3.open(database);
        var db = DatabaseAdapter(native);
        SqliteService.setTestingDatabase(db);
        await DatabaseTestHelper().createMinimalSchema(db);
        await db.insert('app_systems', {
          'id': 'snes',
          'real_name': 'Super Nintendo',
          'folder_name': 'snes',
        });
        await db.insert('app_system_extensions', {
          'system_id': 'snes',
          'extension': 'smc',
        });
        const system = SystemModel(
          id: 'snes',
          realName: 'Super Nintendo',
          folderName: 'snes',
          iconImage: '',
          color: '#000000',
          recursiveScan: true,
        );
        await SqliteDatabaseService.scanSystemRoms(system, [root.path]);
        await db.execute('UPDATE user_roms SET is_favorite=1,play_time=321');
        for (var i = 0; i < 3; i++) {
          await SqliteDatabaseService.scanSystemRoms(system, [
            root.path,
            root.path,
          ]);
          final rows = await db.query('user_roms');
          expect(rows, hasLength(1));
          expect(rows.single['rom_path'], rom.path);
          expect(rows.single['is_favorite'], 1);
          expect(rows.single['play_time'], 321);
        }
        native.close();
        native = sqlite.sqlite3.open(database);
        db = DatabaseAdapter(native);
        SqliteService.setTestingDatabase(db);
        await SqliteDatabaseService.scanSystemRoms(system, [root.path]);
        final reopened = await db.query('user_roms');
        expect(reopened, hasLength(1));
        expect(reopened.single['is_favorite'], 1);
        expect(reopened.single['play_time'], 321);
      } finally {
        native?.close();
        SqliteService.setTestingDatabase(
          DatabaseAdapter(sqlite.sqlite3.openInMemory()),
        );
        await root.delete(recursive: true);
      }
    },
  );
  test('one game can retain two legitimate playlist memberships', () {
    final entries = [
      {
        'filename': 'Game.smc',
        'gameId': 'SNES.lpl:0',
        'system': 'SNES',
        'coreName': 'Snes9x',
      },
      {
        'filename': 'Game.smc',
        'gameId': 'Collection.lpl:4',
        'system': 'Collection',
        'coreName': 'Snes9x',
      },
    ];
    final index = RetroArchLibraryProtocol.index(entries);
    expect(index['retroarch-export-record:0']!['gameId'], 'SNES.lpl:0');
    expect(index['retroarch-export-record:1']!['gameId'], 'Collection.lpl:4');
    expect(index['retroarch-library://game/SNES/Game.smc'], isNotNull);
    expect(index['retroarch-library://game/Collection/Game.smc'], isNotNull);
  });
}
