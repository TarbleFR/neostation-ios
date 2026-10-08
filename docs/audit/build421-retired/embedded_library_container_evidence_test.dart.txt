// Audit evidence, not acceptance of the current duplicate behavior.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/models/system_model.dart';
import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final folder in ['gc', 'wii']) {
    test(
      'embedded $folder: a retained old container row survives the new-root scan',
      () async {
        final helper = DatabaseTestHelper();
        final db = await helper.setUp();
        addTearDown(helper.tearDown);
        final temp = await Directory.systemTemp.createTemp(
          'embedded-container-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final oldRoot =
            '${temp.path}/OLD/Library/Application Support/NeoStation/Dolphin/Library';
        final newRoot =
            '${temp.path}/NEW/Library/Application Support/NeoStation/Dolphin/Library';
        await Directory('$newRoot/$folder').create(recursive: true);
        await File('$newRoot/$folder/Game.rvz').writeAsString('game fixture');
        await db.insert('app_systems', {
          'id': folder,
          'folder_name': folder,
          'real_name': folder,
        });
        await db.insert('app_system_folders', {
          'system_id': folder,
          'folder_name': folder,
        });
        await db.insert('app_system_extensions', {
          'system_id': folder,
          'extension': 'rvz',
        });
        await db.insert('user_roms', {
          'app_system_id': folder,
          'filename': 'Game.rvz',
          'rom_path': '$oldRoot/$folder/Game.rvz',
          'is_favorite': 1,
          'play_time': 999,
        });
        final system = SystemModel(
          id: folder,
          realName: folder,
          folderName: folder,
          iconImage: '',
          color: '#000000',
          recursiveScan: true,
        );
        await SqliteDatabaseService.scanSystemRoms(system, [
          newRoot,
        ], preserveUnscannedSources: true);
        await SqliteDatabaseService.scanSystemRoms(system, [
          newRoot,
        ], preserveUnscannedSources: true);
        final rows = await db.query('user_roms');
        expect(rows, hasLength(2));
        expect(rows.where((r) => r['is_favorite'] == 1).length, 1);
        expect(await File('$newRoot/$folder/Game.rvz').exists(), isTrue);
      },
    );
  }
}
