import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/retroarch_library_importer.dart';
import 'package:neostation/services/retroarch_folder_recovery.dart';
import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'verified archive binding prevents restoration/scan reinsertion and follows bookmark relocation',
    () async {
      final helper = DatabaseTestHelper();
      final db = await helper.setUp();
      addTearDown(helper.tearDown);
      final temp = await Directory.systemTemp.createTemp('ra-binding-');
      addTearDown(() => temp.delete(recursive: true));
      final root = '${temp.path}/old';
      final next = '${temp.path}/new';
      await Directory('$root/gba').create(recursive: true);
      await File('$root/gba/Game.zip').writeAsString('scanner fixture');
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
        'extension': 'zip',
      });
      const name = 'Nintendo - Game Boy Advance';
      final virtual = RetroArchLibraryImporter.libraryPath(name, 'Game.gba');
      await db.insert('user_roms', {
        'rom_path': '$root/gba/Game.zip',
        'app_system_id': 'gba',
        'filename': 'Game.zip',
        'is_favorite': 1,
        'play_time': 35,
      });
      await db.execute(
        'CREATE TABLE user_retroarch_repair_v1 (source_path TEXT PRIMARY KEY,target_path TEXT)',
      );
      await db.insert('user_retroarch_repair_v1', {
        'source_path': virtual,
        'target_path': '$root/gba/Game.zip',
      });
      const entries = [
        {'system': name, 'filename': 'Game.gba'},
      ];
      const system = SystemModel(
        id: 'gba',
        folderName: 'gba',
        realName: 'GBA',
        iconImage: '',
        color: '#000000',
        recursiveScan: true,
      );
      Future<void> restore() =>
          RetroArchLibraryImporter.restore(db, entries).then((_) {});
      Future<void> scan() => SqliteDatabaseService.scanSystemRoms(system, [
        root,
      ], preserveUnscannedSources: true).then((_) {});
      await restore();
      await restore();
      await scan();
      await scan();
      await Future.wait([restore(), restore(), scan()]);
      final row = (await db.query('user_roms')).single;
      expect(row['rom_path'], '$root/gba/Game.zip');
      expect(row['is_favorite'], 1);
      expect(row['play_time'], 35);
      await Directory(root).rename(next);
      await RetroArchFolderRecovery.relocate(db, root, next);
      await restore();
      expect(
        (await db.query('user_roms')).single['rom_path'],
        '$next/gba/Game.zip',
      );
      expect(
        (await db.query('user_retroarch_repair_v1')).single['target_path'],
        '$next/gba/Game.zip',
      );
    },
  );
}
