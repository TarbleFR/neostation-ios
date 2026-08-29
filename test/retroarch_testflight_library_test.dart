import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('RetroArch is TestFlight-only and ZIP stems resolve from exported library', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'retroarch_ios_distribution_v1': 'appstore',
      'retroarch_appstore_launch_cache_v3': '{}',
      'retroarch_appstore_launch_root_v3': '/legacy/appstore/path',
    });

    await RetroArchLibraryService.loadCachedLibrary();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('retroarch_ios_distribution_v1'), isFalse);
    expect(prefs.containsKey('retroarch_appstore_launch_cache_v3'), isFalse);
    expect(prefs.containsKey('retroarch_appstore_launch_root_v3'), isFalse);

    final payload = base64Url
        .encode(
          utf8.encode(
            jsonEncode([
              {
                'titleId': 'Virtua Racing Deluxe (Europe).32x',
                'filename': 'Virtua Racing Deluxe (Europe).32x',
                'titleName': 'Virtua Racing Deluxe (Europe)',
                'system': 'Sega - 32X',
                'coreName': 'PicoDrive',
              },
            ]),
          ),
        )
        .replaceAll('=', '');

    final handled = await RetroArchLibraryService.handleIncomingUri(
      Uri.parse('neostation://retroarch?games=$payload'),
    );

    expect(handled, isTrue);
    expect(
      RetroArchLibraryService.hasGameForRomPath(
        '/roms/32x/Virtua Racing Deluxe (Europe).zip',
      ),
      isTrue,
    );
    expect(
      prefs.getString('retroarch_testflight_library_cache_v1'),
      isNotNull,
    );
  });
}
