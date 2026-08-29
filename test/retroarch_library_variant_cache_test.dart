import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/retroarch_appstore_service.dart';
import 'package:neostation/services/retroarch_distribution_service.dart';
import 'package:neostation/services/retroarch_library_service.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ConfigService.linkedExternalFolderPath = null;
  });

  tearDown(() {
    ConfigService.linkedExternalFolderPath = null;
  });

  test('RetroArch distribution defaults to TestFlight for existing users', () async {
    expect(
      await RetroArchDistributionService.current(),
      RetroArchDistribution.testFlight,
    );
  });

  test('App Store selection is persisted independently', () async {
    await RetroArchDistributionService.useAppStore();
    expect(
      await RetroArchDistributionService.current(),
      RetroArchDistribution.appStore,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('retroarch_ios_distribution_v1'), 'appstore');
  });

  test('App Store backend only owns ROMs inside its linked folder', () async {
    final root = await Directory.systemTemp.createTemp('retroarch_appstore_');
    addTearDown(() => root.delete(recursive: true));
    final rom = File(path.join(root.path, 'Example Game.zip'));
    await rom.writeAsBytes(const <int>[1, 2, 3]);

    ConfigService.linkedExternalFolderPath = root.path;

    expect(RetroArchAppStoreService.ownsRomPath(rom.path), isTrue);
    expect(
      RetroArchAppStoreService.ownsRomPath('/tmp/Example Game.zip'),
      isFalse,
    );
  });

  test('App Store uses RetroArch archive-member basename from Playlist', () async {
    final root = await Directory.systemTemp.createTemp('retroarch_zip_');
    addTearDown(() => root.delete(recursive: true));
    final roms = Directory(path.join(root.path, 'roms'));
    final playlists = Directory(path.join(root.path, 'Playlist'));
    await roms.create(recursive: true);
    await playlists.create(recursive: true);

    final rom = File(
      path.join(
        roms.path,
        '36 Great Holes Starring Fred Couples (32X) (E) [!].zip',
      ),
    );
    await rom.writeAsBytes(const <int>[1, 2, 3]);

    await File(path.join(playlists.path, 'Sega - 32X.lpl')).writeAsString(
      jsonEncode({
        'version': '1.5',
        'items': [
          {
            'path': '${rom.path}#36 Great Holes Starring Fred Couples (32X) (E) [!].32x',
            'label': '36 Great Holes Starring Fred Couples',
            'core_name': 'PicoDrive',
            'db_name': 'Sega - 32X.lpl',
          },
        ],
      }),
    );

    ConfigService.linkedExternalFolderPath = root.path;
    expect(await RetroArchAppStoreService.syncLinkedLibrary(), isTrue);
    expect(
      await RetroArchAppStoreService.launchIdForRomPath(rom.path),
      '36 Great Holes Starring Fred Couples (32X) (E) [!].32x',
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('retroarch_appstore_launch_cache_v2');
    expect(raw, isNotNull);
    expect(raw, contains('.32x'));
    expect(
      prefs.getString('retroarch_testflight_library_cache_v1'),
      isNull,
    );
  });

  test('App Store keeps ZIP filename when RetroArch playlist points to ZIP', () async {
    final root = await Directory.systemTemp.createTemp('retroarch_zip_direct_');
    addTearDown(() => root.delete(recursive: true));
    final roms = Directory(path.join(root.path, 'roms'));
    final playlists = Directory(path.join(root.path, 'playlists'));
    await roms.create(recursive: true);
    await playlists.create(recursive: true);

    final rom = File(path.join(roms.path, 'Example Game.zip'));
    await rom.writeAsBytes(const <int>[1, 2, 3]);
    await File(path.join(playlists.path, 'Example System.lpl')).writeAsString(
      jsonEncode({
        'version': '1.5',
        'items': [
          {
            'path': rom.path,
            'label': 'Example Game',
            'core_name': 'Example Core',
          },
        ],
      }),
    );

    ConfigService.linkedExternalFolderPath = root.path;
    expect(await RetroArchAppStoreService.syncLinkedLibrary(), isTrue);
    expect(
      await RetroArchAppStoreService.launchIdForRomPath(rom.path),
      'Example Game.zip',
    );
  });

  test('App Store falls back to physical filename without accessible Playlist', () async {
    final root = await Directory.systemTemp.createTemp('retroarch_no_playlist_');
    addTearDown(() => root.delete(recursive: true));
    final roms = Directory(path.join(root.path, 'roms'));
    await roms.create(recursive: true);

    final rom = File(path.join(roms.path, 'Fallback Game.chd'));
    await rom.writeAsBytes(const <int>[1, 2, 3]);

    ConfigService.linkedExternalFolderPath = root.path;
    expect(
      await RetroArchAppStoreService.launchIdForRomPath(rom.path),
      'Fallback Game.chd',
    );
  });

  test('TestFlight callback keeps using its dedicated cache', () async {
    await RetroArchDistributionService.useTestFlight();
    final payload = base64Url
        .encode(
          utf8.encode(
            jsonEncode([
              {
                'titleId': 'TestFlight Game.gbc',
                'filename': 'TestFlight Game.gbc',
                'titleName': 'TestFlight Game',
                'system': 'Nintendo - Game Boy Color',
                'coreName': 'Gambatte',
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
      RetroArchLibraryService.hasGameForRomPath('/tmp/TestFlight Game.gbc'),
      isTrue,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('retroarch_testflight_library_cache_v1'),
      isNotNull,
    );
    expect(
      await RetroArchDistributionService.current(),
      RetroArchDistribution.testFlight,
    );
  });

  test('App Store folder cannot replace TestFlight export cache', () async {
    final payload = base64Url
        .encode(
          utf8.encode(
            jsonEncode([
              {
                'titleId': 'TF Only.gbc',
                'filename': 'TF Only.gbc',
                'titleName': 'TF Only',
              },
            ]),
          ),
        )
        .replaceAll('=', '');

    expect(
      await RetroArchLibraryService.handleIncomingUri(
        Uri.parse('neostation://retroarch?games=$payload'),
      ),
      isTrue,
    );

    final appStoreRoot =
        await Directory.systemTemp.createTemp('retroarch_appstore_split_');
    addTearDown(() => appStoreRoot.delete(recursive: true));
    ConfigService.linkedExternalFolderPath = appStoreRoot.path;
    await RetroArchDistributionService.useAppStore();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('retroarch_testflight_library_cache_v1'),
      isNotNull,
    );
    expect(
      await RetroArchDistributionService.current(),
      RetroArchDistribution.appStore,
    );
  });
}
