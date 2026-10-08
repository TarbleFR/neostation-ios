import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      SharedPreferences.setMockInitialValues({});
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
      final prefs = await SharedPreferences.getInstance();
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
        expect(prefs.getString('retroarch_library_cache_v1'), original);
        expect(
          await RetroArchLibraryService.hasGameForRomPath(
            '/new/roms/gba/A Game.gba',
          ),
          isTrue,
        );
      }
      expect(
        await RetroArchLibraryService.handleIncomingUri(
          Uri.parse('neostation://melonx'),
        ),
        isFalse,
      );
    },
  );
}
