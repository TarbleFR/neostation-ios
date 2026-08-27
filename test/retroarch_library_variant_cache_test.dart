import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('changing RetroArch variant clears only NeoStation library cache', () async {
    SharedPreferences.setMockInitialValues({});
    final payload = base64Url.encode(
      utf8.encode(
        jsonEncode([
          {
            'filename': 'Game.zip',
            'titleName': 'Game',
          },
        ]),
      ),
    );

    expect(
      await RetroArchLibraryService.handleIncomingUri(
        Uri.parse('neostation://retroarch?games=$payload'),
      ),
      isTrue,
    );
    expect(RetroArchLibraryService.hasSyncedLibrary, isTrue);

    await RetroArchLibraryService.clearCachedLibrary();

    expect(RetroArchLibraryService.hasSyncedLibrary, isFalse);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('retroarch_library_cache_v1'), isNull);
  });
}
