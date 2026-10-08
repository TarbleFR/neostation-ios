import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

String cachePath(String system, String filename) => Uri(
  scheme: 'retroarch-library',
  host: 'game',
  pathSegments: [system, filename],
).toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'repeated callbacks update launch cache without creating virtual library rows',
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
      await db.insert('user_roms', {
        'app_system_id': 'gba',
        'filename': 'A Game.gba',
        'rom_path': '/old/roms/gba/A Game.gba',
        'is_favorite': 1,
        'play_time': 999,
      });
      final initialRows = await db.query('user_roms');
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
          cachePath('Nintendo - Game Boy Advance', 'Same.bin'),
        ),
        isTrue,
      );
      expect(
        await RetroArchLibraryService.hasGameForRomPath(
          cachePath(
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
      expect(rows, initialRows);
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
        expect(await db.query('user_roms'), initialRows);
        expect(prefs.getString('retroarch_library_cache_v1'), original);
        expect(
          await RetroArchLibraryService.hasGameForRomPath(
            '/new/roms/gba/A Game.gba',
          ),
          isTrue,
        );
      }
      final valid = callback([
        {
          'filename': 'A Game.gba',
          'titleId': 'A Game.gba',
          'system': 'Nintendo - Game Boy Advance',
        },
      ]);
      await Future.wait([
        RetroArchLibraryService.handleIncomingUri(valid),
        RetroArchLibraryService.handleIncomingUri(valid),
      ]);
      expect(await db.query('user_roms'), initialRows);
      expect(await db.query('user_detected_systems'), isEmpty);
      // Startup cache loading also remains a read of launch metadata.
      await RetroArchLibraryService.loadCachedLibrary();
      expect(await db.query('user_roms'), initialRows);
      expect(
        await RetroArchLibraryService.handleIncomingUri(
          Uri.parse('neostation://melonx'),
        ),
        isFalse,
      );
    },
  );
}
