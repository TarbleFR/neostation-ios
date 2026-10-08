import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/retroarch_folder_recovery.dart';

void main() {
  test('rebase uses a path boundary and retains nested library layouts', () {
    expect(
      RetroArchFolderRecovery.rebase('/old/roms/gba/a.gba', '/old', '/new'),
      '/new/roms/gba/a.gba',
    );
    expect(
      RetroArchFolderRecovery.rebase('/old2/a.gba', '/old', '/new'),
      isNull,
    );
    expect(
      RetroArchFolderRecovery.rebase('/other/a.gba', '/old', '/new'),
      isNull,
    );
  });

  late DatabaseAdapter db;
  setUp(() async {
    db = DatabaseAdapter(sqlite.sqlite3.openInMemory());
    await db.execute(
      'CREATE TABLE user_rom_folders(id INTEGER PRIMARY KEY, path TEXT UNIQUE)',
    );
    await db.execute(
      'CREATE TABLE user_roms(id INTEGER PRIMARY KEY, rom_path TEXT UNIQUE, is_favorite INTEGER, play_time INTEGER, title TEXT)',
    );
    await db.insert('user_rom_folders', {'id': 1, 'path': '/old/roms'});
    await db.insert('user_roms', {
      'id': 42,
      'rom_path': '/old/roms/gba/a.gba',
      'is_favorite': 1,
      'play_time': 999,
      'title': 'My title',
    });
    await db.insert('user_roms', {
      'id': 43,
      'rom_path': '/old/roms2/b.gba',
      'is_favorite': 0,
      'play_time': 3,
      'title': 'Other emulator',
    });
  });
  tearDown(() async => db.close());

  test(
    'production SQLite relocation preserves favorites and unrelated libraries',
    () async {
      await RetroArchFolderRecovery.relocate(db, '/old/roms', '/new/roms');
      final rows = await db.query('user_roms', orderBy: 'id');
      expect(rows.first, {
        'id': 42,
        'rom_path': '/new/roms/gba/a.gba',
        'is_favorite': 1,
        'play_time': 999,
        'title': 'My title',
      });
      expect(rows.last['rom_path'], '/old/roms2/b.gba');
      expect((await db.query('user_rom_folders')).single['path'], '/new/roms');
      await RetroArchFolderRecovery.relocate(db, '/old/roms', '/new/roms');
      expect(await db.query('user_roms', orderBy: 'id'), rows);
    },
  );

  test(
    'a path collision rolls back every update and keeps the old root',
    () async {
      await db.insert('user_roms', {
        'id': 44,
        'rom_path': '/new/roms/gba/a.gba',
        'is_favorite': 0,
        'play_time': 0,
      });
      final before = await db.query('user_roms', orderBy: 'id');
      await expectLater(
        RetroArchFolderRecovery.relocate(db, '/old/roms', '/new/roms'),
        throwsA(isA<sqlite.SqliteException>()),
      );
      expect(await db.query('user_roms', orderBy: 'id'), before);
      expect((await db.query('user_rom_folders')).single['path'], '/old/roms');
    },
  );
}
