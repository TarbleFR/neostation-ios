import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/ports_locale.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/game/game_list_service.dart';
import 'package:neostation/services/ports_display_title.dart';
import 'package:neostation/services/ports_game_identity.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:path/path.dart' as path;

import 'database_test_helper.dart';

const ports = SystemModel(
  id: 'ports',
  folderName: 'ports',
  realName: 'Ports',
  iconImage: '',
  color: '#D7A72E',
  extensions: ['iso'],
  recursiveScan: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const disc = MethodChannel('neostation/dolphin_internal');
  late Directory documents;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('kartpad-display-');
    messenger.setMockMethodCallHandler(paths, (_) async => documents.path);
    messenger.setMockMethodCallHandler(disc, (_) async => null);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(disc, null);
    await documents.delete(recursive: true);
  });

  Future<File> writeSourceDisc() async {
    final file = File(
      path.join(
        documents.path,
        'Ports',
        'KartPad',
        'Games',
        'Mario Kart Wii (Europe).iso',
      ),
    );
    await file.parent.create(recursive: true);
    final bytes = Uint8List(0x20);
    bytes.setRange(0, 6, 'RMCP01'.codeUnits);
    ByteData.sublistView(bytes).setUint32(0x18, 0x5D1C9EA3, Endian.big);
    return file.writeAsBytes(bytes);
  }

  Future<DatabaseAdapter> setUpDatabase() async {
    final helper = DatabaseTestHelper();
    final db = await helper.setUp();
    addTearDown(helper.tearDown);
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('ports', 'Ports', 'ports'), ('wii', 'Nintendo Wii', 'wii')",
    );
    await db.execute(
      "INSERT INTO app_system_extensions (system_id, extension) "
      "VALUES ('ports', 'iso'), ('wii', 'iso')",
    );
    return db;
  }

  test('Mario Kart Pad is the same product name in all twelve locales', () {
    expect(PortsLocale.values, hasLength(12));
    for (final locale in PortsLocale.values.entries) {
      expect(
        locale.value['kartpad'],
        PortsDisplayTitle.kartPad,
        reason: locale.key,
      );
    }
    expect(PortsDisplayTitle.kartPad, 'Mario Kart Pad');
    expect(PortsDisplayTitle.kartPadSourceGame, 'Mario Kart Wii');
  });

  test('existing imports and scraped rows show the port name without renaming identity', () {
    final gamePath = path.join(
      documents.path,
      'Ports',
      'KartPad',
      'Games',
      'Mario Kart Wii (Europe).iso',
    );
    for (final oldName in <String?>[null, 'Mario Kart Wii', 'マリオカートWii']) {
      final row = DatabaseGameModel(
        appSystemId: 'ports',
        systemFolderName: 'ports',
        filename: 'Mario Kart Wii (Europe).iso',
        romPath: gamePath,
        titleId: 'RMCP01',
        titleName: oldName,
        realName: oldName,
        screenscraperRealName: oldName,
        isFavorite: true,
        playTime: 42,
      );
      final game = GameModel.fromDatabaseModel(row);
      expect(game.name, 'Mario Kart Pad');
      expect(game.realname, 'Mario Kart Pad');
      expect(game.romPath, gamePath);
      expect(game.titleId, 'RMCP01');
      expect(game.titleName, oldName);
      expect(game.isFavorite, isTrue);
      expect(game.playTime, 42);
      expect(row.filename, 'Mario Kart Wii (Europe).iso');
      expect(row.screenscraperRealName, oldName);
    }
  });

  test('the Wii original and other Ports paths keep their source title', () {
    for (final entry in <({String folder, String location})>[
      (folder: 'wii', location: 'Ports/KartPad/Games/Mario Kart Wii.iso'),
      (folder: 'ports', location: 'Ports/Dusklight/Games/Mario Kart Wii.iso'),
      (
        folder: 'ports',
        location: 'Ports/KartPad/GamesExtra/Mario Kart Wii.iso',
      ),
      (
        folder: 'ports',
        location: 'Ports/KartPad/Games/../../Mario Kart Wii.iso',
      ),
    ]) {
      final row = DatabaseGameModel(
        filename: 'Mario Kart Wii.iso',
        romPath: path.join(documents.path, entry.location),
        systemFolderName: entry.folder,
        titleId: 'RMCP01',
        titleName: 'Mario Kart Wii',
        realName: 'Mario Kart Wii',
      );
      expect(
        GameModel.fromDatabaseModel(row).name,
        'Mario Kart Wii',
        reason: '${entry.folder}/${entry.location}',
      );
    }
  });

  test('the Ports scraper keeps Wii lookup title and RMCP01 independently from the display name', () async {
    final file = await writeSourceDisc();
    final identity = await PortGameIdentity.read(file.path);
    expect(identity, isNotNull);
    expect(identity!.displayTitle, 'Mario Kart Pad');
    expect(identity.title, 'Mario Kart Wii');
    expect(identity.discId, 'RMCP01');
    final parameters = ScreenScraperService.buildGameLookupParametersForTesting(
      systemId: identity.screenScraperSystemId.toString(),
      romName: identity.title,
      serialNumber: identity.discId,
    );
    expect(parameters['systemeid'], '16');
    expect(parameters['romnom'], 'Mario Kart Wii');
    expect(parameters['serialnum'], 'RMCP01');
  });

  test('Ports, All, Favorites and details correct an old scraped title even with filename preference', () async {
    final db = await setUpDatabase();
    final file = await writeSourceDisc();
    await db.execute(
      "INSERT INTO user_system_settings (app_system_id, prefer_file_name) "
      "VALUES ('ports', 1)",
    );
    await db.execute(
      '''
      INSERT INTO user_roms
        (app_system_id, filename, rom_path, title_id, title_name, is_favorite, play_time)
      VALUES ('ports', ?, ?, 'RMCP01', 'Mario Kart Wii', 1, 42)
    ''',
      [path.basename(file.path), file.path],
    );
    await db.execute(
      '''
      INSERT INTO user_screenscraper_metadata (app_system_id, filename, real_name)
      VALUES ('ports', ?, 'Mario Kart Wii')
    ''',
      [path.basename(file.path)],
    );
    for (final system in <SystemModel>[
      ports,
      ports.copyWith(folderName: 'all'),
      ports.copyWith(folderName: 'favorites'),
    ]) {
      final game = (await GameListService.loadGamesForSystem(system)).single;
      expect(game.name, 'Mario Kart Pad', reason: system.folderName);
      expect(game.realname, 'Mario Kart Pad');
      expect(game.romname, path.basename(file.path));
      expect(game.romPath, file.path);
      expect(game.titleId, 'RMCP01');
      expect(game.showRomFileNameSubtitle, isFalse);
    }
    final details = await GameListService.getGameDetails(
      ports,
      path.basename(file.path),
    );
    expect(details?.name, 'Mario Kart Pad');
    final stored = (await SqliteService.getGamesBySystem('ports')).single;
    expect(stored.titleName, 'Mario Kart Wii');
    expect(stored.screenscraperRealName, 'Mario Kart Wii');
    expect(stored.playTime, 42);
    expect(stored.isFavorite, isTrue);
  });

  test('new import and rescan store Mario Kart Pad while preserving files, saves and user preferences', () async {
    final db = await setUpDatabase();
    final file = await writeSourceDisc();
    final originalBytes = await file.readAsBytes();
    final save = File(
      path.join(documents.path, 'Ports', 'KartPad', 'Saves', 'fixture.dat'),
    );
    await save.parent.create(recursive: true);
    await save.writeAsString('existing user save');
    final libraryRoot = path.join(documents.path, 'Ports', 'KartPad');
    final folders = <String, Map<String, String>>{
      libraryRoot: {'ports': file.parent.path},
    };
    await SqliteDatabaseService.scanSystemRoms(ports, [
      libraryRoot,
    ], rootFoldersMap: folders);
    final imported = (await SqliteService.getGamesBySystem('ports')).single;
    expect(imported.titleName, 'Mario Kart Pad');
    expect(imported.titleId, 'RMCP01');
    expect(imported.romPath, file.path);
    await db.execute(
      "UPDATE user_roms SET title_name = 'Mario Kart Wii', is_favorite = 1, play_time = 42",
    );
    await SqliteDatabaseService.scanSystemRoms(ports, [
      libraryRoot,
    ], rootFoldersMap: folders);
    final rescanned = (await SqliteService.getGamesBySystem('ports')).single;
    expect(rescanned.titleName, 'Mario Kart Pad');
    expect(rescanned.titleId, 'RMCP01');
    expect(rescanned.filename, path.basename(file.path));
    expect(rescanned.romPath, file.path);
    expect(rescanned.isFavorite, isTrue);
    expect(rescanned.playTime, 42);
    expect(await file.readAsBytes(), originalBytes);
    expect(await save.readAsString(), 'existing user save');
  });
}
