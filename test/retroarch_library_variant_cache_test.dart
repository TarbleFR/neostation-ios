import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/retroarch_library_service.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ConfigService.linkedExternalFolderPath = null;
    await RetroArchLibraryService.clearCachedLibrary();
  });

  tearDown(() {
    ConfigService.linkedExternalFolderPath = null;
  });

  test('App Store sync builds an isolated index from RetroArch playlists', () async {
    final root = await Directory.systemTemp.createTemp('retroarch_appstore_');
    addTearDown(() => root.delete(recursive: true));

    final playlists = Directory(path.join(root.path, 'playlists'));
    final roms = Directory(path.join(root.path, 'roms'));
    await playlists.create(recursive: true);
    await roms.create(recursive: true);

    final rom = File(path.join(roms.path, 'Example Game.zip'));
    await rom.writeAsBytes(const <int>[1, 2, 3]);

    final playlist = File(
      path.join(playlists.path, 'Nintendo - Game Boy Color.lpl'),
    );
    await playlist.writeAsString(
      jsonEncode({
        'version': '1.5',
        'items': [
          {
            'path': '${rom.path}#Example Game.gbc',
            'label': 'Example Game',
            'core_name': 'Gambatte',
            'db_name': 'Nintendo - Game Boy Color.lpl',
          },
        ],
      }),
    );

    ConfigService.linkedExternalFolderPath = root.path;
    final count = await RetroArchLibraryService.syncLinkedLibraryFromDisk(
      updateNeoStation: false,
    );

    expect(count, 1);
    expect(RetroArchLibraryService.hasSyncedLibrary, isTrue);
    expect(RetroArchLibraryService.hasGameForRomPath(rom.path), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('retroarch_linked_library_cache_v2'), isNotNull);
    expect(prefs.getString('retroarch_linked_library_root_v2'), root.path);
    expect(prefs.getString('retroarch_testflight_library_cache_v2'), isNull);
  });

  test('TestFlight callback persists only the TestFlight export cache', () async {
    final payload = base64Url.encode(
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
    ).replaceAll('=', '');

    final handled = await RetroArchLibraryService.handleIncomingUri(
      Uri.parse('neostation://retroarch?games=$payload'),
    );

    expect(handled, isTrue);
    expect(
      RetroArchLibraryService.hasGameForRomPath('/tmp/TestFlight Game.gbc'),
      isTrue,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('retroarch_testflight_library_cache_v2'), isNotNull);
    expect(prefs.getString('retroarch_linked_library_cache_v2'), isNull);
  });

  test('linked cache is ignored after switching to another RetroArch folder', () async {
    final rootA = await Directory.systemTemp.createTemp('retroarch_a_');
    final rootB = await Directory.systemTemp.createTemp('retroarch_b_');
    addTearDown(() => rootA.delete(recursive: true));
    addTearDown(() => rootB.delete(recursive: true));

    final playlists = Directory(path.join(rootA.path, 'playlists'));
    final roms = Directory(path.join(rootA.path, 'roms'));
    await playlists.create(recursive: true);
    await roms.create(recursive: true);

    final romA = File(path.join(roms.path, 'Same Name.gbc'));
    await romA.writeAsBytes(const <int>[1]);
    await File(path.join(playlists.path, 'Nintendo - Game Boy Color.lpl'))
        .writeAsString(
      jsonEncode({
        'items': [
          {
            'path': romA.path,
            'label': 'Same Name',
            'db_name': 'Nintendo - Game Boy Color.lpl',
          },
        ],
      }),
    );

    ConfigService.linkedExternalFolderPath = rootA.path;
    await RetroArchLibraryService.syncLinkedLibraryFromDisk(
      updateNeoStation: false,
    );
    expect(RetroArchLibraryService.hasGameForRomPath(romA.path), isTrue);

    ConfigService.linkedExternalFolderPath = rootB.path;
    await RetroArchLibraryService.loadCachedLibrary(forceReload: true);

    final nonexistentInB = path.join(rootB.path, 'Same Name.gbc');
    expect(File(nonexistentInB).existsSync(), isFalse);
    expect(
      RetroArchLibraryService.hasGameForRomPath(nonexistentInB),
      isFalse,
    );
  });

  test('TestFlight cache cannot leak into a different linked installation', () async {
    final rootA = await Directory.systemTemp.createTemp('retroarch_tf_a_');
    final rootB = await Directory.systemTemp.createTemp('retroarch_tf_b_');
    addTearDown(() => rootA.delete(recursive: true));
    addTearDown(() => rootB.delete(recursive: true));

    ConfigService.linkedExternalFolderPath = rootA.path;
    final payload = base64Url.encode(
      utf8.encode(
        jsonEncode([
          {
            'titleId': 'Variant Only.gbc',
            'filename': 'Variant Only.gbc',
            'titleName': 'Variant Only',
            'system': 'Nintendo - Game Boy Color',
          },
        ]),
      ),
    ).replaceAll('=', '');

    expect(
      await RetroArchLibraryService.handleIncomingUri(
        Uri.parse('neostation://retroarch?games=$payload'),
      ),
      isTrue,
    );

    ConfigService.linkedExternalFolderPath = rootB.path;
    await RetroArchLibraryService.loadCachedLibrary(forceReload: true);

    final nonexistentInB = path.join(rootB.path, 'Variant Only.gbc');
    expect(File(nonexistentInB).existsSync(), isFalse);
    expect(
      RetroArchLibraryService.hasGameForRomPath(nonexistentInB),
      isFalse,
    );
  });
}
