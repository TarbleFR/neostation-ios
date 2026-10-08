// Audit reproductions of the existing mixed-source defect, not acceptance
// tests for a fix. A count of two below confirms the problem is still present.
// Neither title matching nor hiding rows in the UI is a valid fix.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/retroarch_library_importer.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory root;
  const system = SystemModel(
    id: 'gba',
    realName: 'Game Boy Advance',
    folderName: 'gba',
    iconImage: '',
    color: '#000000',
    recursiveScan: true,
  );
  const entries = [
    {'filename': 'Same.gba', 'system': 'Nintendo - Game Boy Advance'},
  ];
  setUp(() async {
    db = await helper.setUp();
    root = await Directory.systemTemp.createTemp('library-identity-');
    await Directory('${root.path}/gba').create();
    await File('${root.path}/gba/Same.gba').writeAsString('fixture');
    await db.insert('app_systems', {
      'id': 'gba',
      'folder_name': 'gba',
      'real_name': 'Game Boy Advance',
      'manufacturer': 'Nintendo',
    });
    await db.insert('app_system_extensions', {
      'system_id': 'gba',
      'extension': 'gba',
    });
    await db.insert('app_system_folders', {
      'system_id': 'gba',
      'folder_name': 'gba',
    });
  });
  tearDown(() async {
    await helper.tearDown();
    await root.delete(recursive: true);
  });

  test(
    'evidence: scan then export without ownership produces two stored paths',
    () async {
      await SqliteDatabaseService.scanSystemRoms(system, [
        root.path,
      ], preserveUnscannedSources: true);
      // Startup restoration can precede bookmark reconciliation. The current
      // export protocol lacks the full path needed to prove this association.
      await RetroArchLibraryImporter.restore(db, entries);
      expect(await db.query('user_roms'), hasLength(2));
    },
  );

  test(
    'evidence: export then scan produces two stored paths',
    () async {
      await RetroArchLibraryImporter.restore(
        db,
        entries,
        ownedRoots: [root.path],
      );
      await SqliteDatabaseService.scanSystemRoms(system, [
        root.path,
      ], preserveUnscannedSources: true);
      expect(await db.query('user_roms'), hasLength(2));
    },
  );

  test(
    'two scans and concurrent copies of the same export remain idempotent separately',
    () async {
      await SqliteDatabaseService.scanSystemRoms(system, [
        root.path,
      ], preserveUnscannedSources: true);
      await SqliteDatabaseService.scanSystemRoms(system, [
        root.path,
      ], preserveUnscannedSources: true);
      expect(await db.query('user_roms'), hasLength(1));
      await Future.wait([
        RetroArchLibraryImporter.restore(db, entries, ownedRoots: [root.path]),
        RetroArchLibraryImporter.restore(db, entries, ownedRoots: [root.path]),
      ]);
      expect(await db.query('user_roms'), hasLength(1));
    },
  );
}
