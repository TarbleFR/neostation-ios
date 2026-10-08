import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'sync metadata survives repeated same-game requests and a rejected handoff',
    () async {
      final helper = DatabaseTestHelper();
      final db = await helper.setUp();
      addTearDown(helper.tearDown);
      const filename =
          '007 - Everything or Nothing (USA, Europe) (En,Fr,De).zip#007 - Everything or Nothing (USA, Europe) (En,Fr,De).gba';
      const romPath =
          '/roms/007 - Everything or Nothing (USA, Europe) (En,Fr,De).zip';
      final payload = Uri(
        scheme: 'neostation',
        host: 'retroarch',
        queryParameters: {
          'games': base64Url
              .encode(
                utf8.encode(
                  jsonEncode([
                    {
                      'filename': filename,
                      'titleId': filename,
                      'system': 'Nintendo - Game Boy Advance',
                      'gameId': 'Nintendo - Game Boy Advance.lpl:0',
                      'coreName': 'mGBA',
                    },
                  ]),
                ),
              )
              .replaceAll('=', ''),
        },
      );
      await RetroArchLibraryService.handleIncomingUri(payload);
      final prefs = await SharedPreferences.getInstance();
      final cache = prefs.getString('retroarch_library_cache_v1');
      final rows = await db.query('user_roms');
      final sent = <String>[];
      for (final accepted in [true, true, false, true]) {
        final attempt = await RetroArchLibraryService.launchGameWithDiagnostics(
          romPath,
          openUrl: (url) async {
            sent.add(url);
            expect(Uri.parse(url).pathSegments, [filename]);
            expect(Uri.parse(url).queryParameters, isEmpty);
            return accepted;
          },
        );
        expect(attempt.accepted, accepted);
        expect(prefs.getString('retroarch_library_cache_v1'), cache);
        expect(await db.query('user_roms'), rows);
        expect(
          await RetroArchLibraryService.hasGameForRomPath(romPath),
          isTrue,
        );
      }
      expect(sent.length, 4);
      expect(sent.toSet().length, 1);
      expect(sent.every((url) => Uri.parse(url).host == 'game'), isTrue);
      await RetroArchLibraryService.handleIncomingUri(payload);
      expect(prefs.getString('retroarch_library_cache_v1'), cache);
      expect(await db.query('user_roms'), rows);
    },
  );
}
