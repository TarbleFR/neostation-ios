import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/retroarch_library_importer.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed scan transaction cannot roll back a concurrent library import',
    () async {
      final helper = DatabaseTestHelper();
      final db = await helper.setUp();
      addTearDown(helper.tearDown);
      await db.insert('app_systems', {
        'id': 'gba',
        'folder_name': 'gba',
        'real_name': 'Game Boy Advance',
        'manufacturer': 'Nintendo',
      });
      final entered = Completer<void>();
      final release = Completer<void>();
      final failed = db.transaction((txn) async {
        await txn.insert('user_roms', {
          'rom_path': '/scan/unfinished.gba',
          'filename': 'unfinished.gba',
          'app_system_id': 'gba',
        });
        entered.complete();
        await release.future;
        throw StateError('scan failed');
      });
      final failure = expectLater(failed, throwsStateError);
      await entered.future;
      final imported = RetroArchLibraryImporter.restore(db, const [
        {'system': 'Nintendo - Game Boy Advance', 'filename': 'Kept.gba'},
      ]);
      // Let the import reach the active transaction. The old adapter silently
      // joined it and reported success before the scan rolled everything back.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      release.complete();
      await failure;
      expect(await imported, 1);
      final rows = await db.query('user_roms');
      expect(rows, hasLength(1));
      expect(rows.single['filename'], 'Kept.gba');
    },
  );

  test(
    'batch and independent adapters share isolation while nested work completes',
    () async {
      final helper = DatabaseTestHelper();
      final db = await helper.setUp();
      addTearDown(helper.tearDown);
      final other = DatabaseAdapter(db.rawDb);
      final entered = Completer<void>();
      final release = Completer<void>();
      final transaction = db.transaction((txn) async {
        await txn.transaction((nested) async {
          final batch = nested.batch();
          batch.insert('user_rom_folders', {'path': '/discarded'});
          await batch.commit();
        });
        entered.complete();
        await release.future;
        throw StateError('rollback');
      });
      final failure = expectLater(transaction, throwsStateError);
      await entered.future;
      final batch = other.batch();
      batch.insert('user_rom_folders', {'path': '/retained'});
      final committed = batch.commit();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      release.complete();
      await failure;
      await committed;
      expect((await db.query('user_rom_folders')).single['path'], '/retained');
    },
  );
}
