import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS launcher is RetroArch TestFlight only for general ROMs', () {
    final launcher = File('lib/services/game/game_launch_service.dart')
        .readAsStringSync();
    expect(launcher, contains('RetroArchLibraryService.launchGameByRomPath'));
    expect(launcher, contains('RetroArchLibraryService.hasGameForRomPath'));
    expect(launcher, isNot(contains('ExternalFolderAccess.openInMenu(')));
    expect(launcher, isNot(contains('SharePlus.instance.share(')));
    expect(launcher, isNot(contains('ResumeNeoStation')));
    expect(launcher.toLowerCase(), isNot(contains('manicemu')));
  });

  test(
    'rollback migrates TestFlight cache before purging experimental state',
    () {
      final service = File('lib/services/retroarch_library_service.dart')
          .readAsStringSync();
      expect(service, contains("_prefsKey = 'retroarch_library_cache_v1'"));
      expect(service, contains('retroarch_testflight_library_cache_v1'));
      expect(service, contains('retroarch_testflight_library_cache_v2'));
      expect(service, contains("clearBookmark(key: 'manicemu')"));
      expect(service, contains("key.startsWith('retroarch_appstore_')"));
      expect(service, contains("key.startsWith('ios_game_emulator_v1:')"));
    },
  );

  test('only approved post-backup feature surfaces are present', () {
    final library = File('lib/screens/library_screen/library_screen.dart')
        .readAsStringSync();
    expect(library, isNot(contains('LibraryMangaDexService')));

    final assets = File('lib/services/neo_assets_service.dart')
        .readAsStringSync();
    expect(assets, contains('mult1v4c/RiiSU'));

    for (final path in [
      'lib/screens/game_screen/my_games_carousel.dart',
      'lib/screens/game_screen/my_games_grid.dart',
      'lib/screens/game_screen/my_games_list.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('Platform.isIOS'));
      expect(source, contains('padding'));
    }
  });
}
