import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/embedded_library_recovery.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/models/system_model.dart';
import 'database_test_helper.dart';

const oldContainer =
    '/var/mobile/Containers/Data/Application/00000000-0000-4000-8000-000000000001';
const suffix = 'Library/Application Support/NeoStation/Dolphin/Library/gc';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'relocation before two scans and repeated recovery preserves identity and metadata',
    () async {
      final helper = DatabaseTestHelper();
      final db = await helper.setUp();
      addTearDown(helper.tearDown);
      final temp = await Directory.systemTemp.createTemp('embedded-recovery-');
      addTearDown(() => temp.delete(recursive: true));
      final root =
          '${temp.path}/Library/Application Support/NeoStation/Dolphin/Library';
      await Directory('$root/gc').create(recursive: true);
      await File('$root/gc/Game.rvz').writeAsString('fixture');
      await db.insert('app_systems', {
        'id': 'gc',
        'folder_name': 'gc',
        'real_name': 'GameCube',
      });
      await db.insert('app_system_folders', {
        'system_id': 'gc',
        'folder_name': 'gc',
      });
      await db.insert('app_system_extensions', {
        'system_id': 'gc',
        'extension': 'rvz',
      });
      await db.insert('user_roms', {
        'app_system_id': 'gc',
        'filename': 'Game.rvz',
        'rom_path': '$oldContainer/$suffix/Game.rvz',
        'is_favorite': 1,
        'play_time': 999,
        'description': 'Keep me',
      });
      final system = SystemModel(
        id: 'gc',
        realName: 'GameCube',
        folderName: 'gc',
        iconImage: '',
        color: '#000000',
        recursiveScan: true,
      );
      for (var i = 0; i < 2; i++) {
        await SqliteDatabaseService.scanSystemRoms(
          system,
          [root],
          preserveUnscannedSources: true,
          embeddedContainerRoot: temp.path,
        );
      }
      await Future.wait(
        List.generate(
          2,
          (_) => SqliteDatabaseService.scanSystemRoms(
            system,
            [root],
            preserveUnscannedSources: true,
            embeddedContainerRoot: temp.path,
          ),
        ),
      );
      final row = (await db.query('user_roms')).single;
      expect(row['rom_path'], '$root/gc/Game.rvz');
      expect(row['is_favorite'], 1);
      expect(row['play_time'], 999);
      expect(row['description'], 'Keep me');
      expect(await db.query('user_library_path_repair_v1'), hasLength(1));
      expect(await File('$root/gc/Game.rvz').readAsString(), 'fixture');
    },
  );

  test(
    'existing duplicates backed up; metadata conflicts, distinct systems and paths retained',
    () async {
      final helper = DatabaseTestHelper();
      final db = await helper.setUp();
      addTearDown(helper.tearDown);
      for (final name in [
        'Game.rvz',
        'Conflict.rvz',
        'History.rvz',
        'Missing.rvz',
        'Other/Game.rvz',
      ]) {
        for (final root in [oldContainer, '/current']) {
          await db.insert('user_roms', {
            'app_system_id': 'gc',
            'filename': name.split('/').last,
            'rom_path': '$root/$suffix/$name',
            'is_favorite': root == oldContainer ? 1 : 0,
            'play_time': name == 'History.rvz' ? 10 : 0,
            'description': name == 'Conflict.rvz' ? root : null,
          });
        }
      }
      await db.insert('user_roms', {
        'app_system_id': 'wii',
        'filename': 'Game.rvz',
        'rom_path': '$oldContainer/Documents/Other/Game.rvz',
      });
      final result = EmbeddedLibraryRecovery.reconcile(
        db,
        systemId: 'gc',
        folder: 'gc',
        currentContainer: '/current',
        fileExists: (p) =>
            p.startsWith('/current/') && !p.endsWith('/Missing.rvz'),
      );
      expect(result.relocated, 2);
      expect(result.ambiguous, hasLength(2));
      expect(await db.query('user_roms'), hasLength(9));
      final backups = await db.query('user_library_path_repair_v1');
      expect(backups, hasLength(2));
      expect(
        jsonDecode(backups.first['original_json'] as String)['is_favorite'],
        1,
      );
      expect(
        jsonDecode(backups.first['target_json'] as String)['is_favorite'],
        0,
      );
      expect(
        EmbeddedLibraryRecovery.reconcile(
          db,
          systemId: 'gc',
          folder: 'gc',
          currentContainer: '/current',
          fileExists: (p) =>
              p.startsWith('/current/') && !p.endsWith('/Missing.rvz'),
        ).relocated,
        0,
      );
    },
  );

  test('transaction failure rolls back both backup and relocation', () async {
    final helper = DatabaseTestHelper();
    final db = await helper.setUp();
    addTearDown(helper.tearDown);
    final row = {
      'app_system_id': 'gc',
      'filename': 'Game.rvz',
      'rom_path': '$oldContainer/$suffix/Game.rvz',
    };
    await db.insert('user_roms', row);
    await db.execute(
      "CREATE TRIGGER stop_repair BEFORE UPDATE ON user_roms BEGIN SELECT RAISE(ABORT,'injected failure'); END",
    );
    expect(
      () => EmbeddedLibraryRecovery.reconcile(
        db,
        systemId: 'gc',
        folder: 'gc',
        currentContainer: '/current',
        fileExists: (p) => p.startsWith('/current/'),
      ),
      throwsException,
    );
    expect((await db.query('user_roms')).single['rom_path'], row['rom_path']);
    expect(
      await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE name='user_library_path_repair_v1'",
      ),
      isEmpty,
    );
  });

  test(
    'identity retains complete relative path, archive and disc extensions',
    () {
      for (final relative in [
        'set/Game.m3u',
        'set/Game (Disc 1).chd',
        'set/Game (Disc 2).chd',
        'a/Game.zip',
        'b/Game.zip',
      ]) {
        expect(
          EmbeddedLibraryRecovery.target(
            '$oldContainer/$suffix/$relative',
            'gc',
            '/current',
          ),
          '/current/$suffix/$relative',
        );
      }
      expect(
        EmbeddedLibraryRecovery.target(
          '$oldContainer/Documents/RetroArch/Game.zip',
          'gc',
          '/current',
        ),
        isNull,
      );
      expect(
        EmbeddedLibraryRecovery.target(
          '$oldContainer/$suffix/../Game.rvz',
          'gc',
          '/current',
        ),
        isNull,
      );
    },
  );
}
