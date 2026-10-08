import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/services/retroarch_library_importer.dart';
import 'database_test_helper.dart';

Uri callback(Object value) => Uri(
  scheme: 'neostation',
  host: 'retroarch',
  queryParameters: {
    'games': base64Url
        .encode(utf8.encode(jsonEncode(value)))
        .replaceAll('=', ''),
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'production callback keeps persisted launch cache on empty/invalid export',
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
      await RetroArchLibraryService.loadCachedLibrary();
      expect(
        await RetroArchLibraryService.handleIncomingUri(
          callback([
            {
              'filename': 'A Game.gba',
              'titleId': 'A Game.gba',
              'system': 'Nintendo - Game Boy Advance',
            },
          ]),
        ),
        isTrue,
      );
      await db.insert('app_systems', {
        'id': 'snes',
        'folder_name': 'snes',
        'real_name': 'Super Nintendo Entertainment System',
        'manufacturer': 'Nintendo',
      });
      await RetroArchLibraryService.handleIncomingUri(
        callback([
          {
            'filename': 'A Game.gba',
            'titleId': 'A Game.gba',
            'system': 'Nintendo - Game Boy Advance',
          },
          {
            'filename': 'Same.bin',
            'titleId': 'Same.bin',
            'system': 'Nintendo - Game Boy Advance',
          },
          {
            'filename': 'Same.bin',
            'titleId': 'Same.bin',
            'system': 'Nintendo - Super Nintendo Entertainment System',
          },
        ]),
      );
      expect(
        await RetroArchLibraryService.hasGameForRomPath(
          RetroArchLibraryImporter.libraryPath(
            'Nintendo - Game Boy Advance',
            'Same.bin',
          ),
        ),
        isTrue,
      );
      expect(
        await RetroArchLibraryService.hasGameForRomPath(
          RetroArchLibraryImporter.libraryPath(
            'Nintendo - Super Nintendo Entertainment System',
            'Same.bin',
          ),
        ),
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      final rows = await db.query(
        'user_roms',
        where: 'filename = ?',
        whereArgs: ['A Game.gba'],
      );
      expect(
        rows.single['rom_path'],
        RetroArchLibraryImporter.libraryPath(
          'Nintendo - Game Boy Advance',
          'A Game.gba',
        ),
      );
      expect(
        await RetroArchLibraryService.hasGameForRomPath(
          rows.single['rom_path'] as String,
        ),
        isTrue,
      );
      final original = prefs.getString('retroarch_library_cache_v1');
      expect(original, isNotNull);
      expect(
        await RetroArchLibraryService.hasGameForRomPath(
          '/old/roms/gba/A Game.gba',
        ),
        isTrue,
      );
      for (final uri in [
        callback([]),
        callback([
          {'filename': 123},
        ]),
        Uri.parse('neostation://retroarch'),
      ]) {
        expect(await RetroArchLibraryService.handleIncomingUri(uri), isTrue);
        expect((await db.query('user_roms')).length, 3);
        expect(prefs.getString('retroarch_library_cache_v1'), original);
        expect(
          await RetroArchLibraryService.hasGameForRomPath(
            '/new/roms/gba/A Game.gba',
          ),
          isTrue,
        );
      }
      await db.delete('user_roms');
      await db.delete('user_detected_systems');
      await RetroArchLibraryService.restoreCachedLibrary();
      expect((await db.query('user_roms')).length, 3);
      expect(
        (await db.query(
          'user_detected_systems',
        )).map((row) => row['app_system_id']).toSet(),
        {'gba', 'snes'},
      );
      expect(
        await RetroArchLibraryService.handleIncomingUri(
          Uri.parse('neostation://melonx'),
        ),
        isFalse,
      );
    },
  );
}
