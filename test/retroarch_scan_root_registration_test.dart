import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/retroarch_library_report.dart';
import 'package:neostation/services/retroarch_scan_root_registration.dart';

import 'database_test_helper.dart';

const _old = '/private/var/mobile/Containers/Data/Application/'
    '11111111-1111-1111-1111-111111111111';
const _new = '/private/var/mobile/Containers/Data/Application/'
    '22222222-2222-2222-2222-222222222222';
const _neo = '/var/mobile/Containers/Data/Application/'
    '33333333-3333-3333-3333-333333333333';
const _linked = '$_new/Documents/Bibliothèques ';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('folder identity', () {
    test('only an unreachable copy of the linked folder is replaced', () async {
      const registered = [
        '$_neo/Documents/roms',
        '$_old/Documents/Old library',
        '$_old/Documents/Bibliothèques',
        '$_old/Documents/Bibliothèques ',
      ];
      final folders = await RetroArchScanRootRegistration.foldersAfterLink(
        registered,
        _linked,
        exists: (folder) async => !folder.startsWith(_old),
      );
      expect(folders, [
        '$_neo/Documents/roms',
        '$_old/Documents/Old library',
        _linked,
      ]);
    });

    test('a reachable copy is kept and the linked root is never doubled',
        () async {
      const previous = '$_old/Documents/Bibliothèques ';
      expect(
        await RetroArchScanRootRegistration.foldersAfterLink(
          [previous, _linked],
          _linked,
          exists: (_) async => true,
        ),
        [previous, _linked],
      );
    });

    test('paths outside app containers are never considered the same', () {
      expect(
        RetroArchScanRootRegistration.isSameFolder(
          '/tmp/Documents/Bibliothèques',
          '/tmp/Documents/Bibliothèques ',
        ),
        isFalse,
      );
      expect(
        RetroArchScanRootRegistration.isSameFolder(
          '$_old/Documents/Bibliothèques/gba',
          _linked,
        ),
        isFalse,
      );
    });

    test('startup writes nothing for a registered or unreadable root',
        () async {
      expect(
        await RetroArchScanRootRegistration.foldersAtStartup(
          [_linked],
          _linked,
          exists: (_) async => true,
        ),
        isNull,
      );
      expect(
        await RetroArchScanRootRegistration.foldersAtStartup(
          ['$_old/Documents/Bibliothèques '],
          _linked,
          exists: (_) async => false,
        ),
        isNull,
      );
    });
  });

  group('startup registration with the real resolver and SQLite', () {
    final helper = DatabaseTestHelper();
    late Directory temp;

    setUp(() async {
      final db = await helper.setUp();
      for (final id in ['snes', 'gba']) {
        await db.insert('app_systems', {
          'id': id,
          'real_name': id.toUpperCase(),
          'folder_name': id,
        });
      }
      temp = await Directory.systemTemp.createTemp('retroarch-startup-root-');
    });
    tearDown(() async {
      await helper.tearDown();
      await temp.delete(recursive: true);
    });

    test('a moved RetroArch library is registered once before any scan',
        () async {
      final retroArch = Directory('${temp.path}/RetroArch');
      final library = '${retroArch.path}/Bibliothèques ';
      await Directory('$library/snes').create(recursive: true);
      await Directory('$library/gba').create(recursive: true);
      await Directory('${retroArch.path}/playlists').create();
      final stale = '${temp.path}/old-container/Bibliothèques ';
      await SqliteService.saveUserRomFolders([stale]);

      await RetroArchScanRootRegistration.registerResolvedBookmark(
        retroArch.path,
      );
      expect(await SqliteService.getUserRomFolders(), [stale, library]);

      await RetroArchScanRootRegistration.registerResolvedBookmark(
        retroArch.path,
      );
      expect(await SqliteService.getUserRomFolders(), [stale, library]);
    });

    test('a bookmark that no longer opens registers nothing', () async {
      await SqliteService.saveUserRomFolders(['${temp.path}/kept']);
      await RetroArchScanRootRegistration.registerResolvedBookmark(
        '${temp.path}/missing',
      );
      expect(await SqliteService.getUserRomFolders(), ['${temp.path}/kept']);
    });
  });

  test('the report describes reachable system folders and missing roots',
      () async {
    final temp = await Directory.systemTemp.createTemp('retroarch-report-');
    addTearDown(() => temp.delete(recursive: true));
    await Directory('${temp.path}/snes').create();
    await Directory('${temp.path}/Saves').create();
    await File('${temp.path}/note.txt').writeAsString('x');

    expect(
      await RetroArchLibraryReport.describeFolder(
        '${temp.path}/missing',
        {'snes'},
      ),
      'exists=false',
    );
    expect(
      await RetroArchLibraryReport.describeFolder(temp.path, {'snes'}),
      'exists=true directories=2 files=1 systemFolders=[snes] '
      'otherFolders=[Saves]',
    );
  });
}
