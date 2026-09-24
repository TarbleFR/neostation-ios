import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/dusklight_locale.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/game_details_tabs_header.dart';
import 'package:neostation/services/dusklight_game_identity.dart';
import 'package:neostation/services/screenscraper_service.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neostation/dolphin_internal');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final id in DusklightGameIdentity.supportedIds) {
    test('recognizes $id from disc metadata, independent of filename', () async {
      final platform = id.startsWith('R') ? 'wii' : 'gc';
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'saveIdentity');
        return call.arguments['system'] == platform
            ? {'system': platform, 'gameId': id} : null;
      });
      final identity = await DusklightGameIdentity.read('/Games/renamed.rvz');
      expect(identity?.discId, id);
      final params = ScreenScraperService.buildGameLookupParametersForTesting(
        systemId: identity!.screenScraperSystemId.toString(),
        romName: DusklightGameIdentity.title, serialNumber: identity.discId,
      );
      expect(params['systemeid'], platform == 'wii' ? '16' : '13');
      expect(params['romnom'], DusklightGameIdentity.title);
      expect(params['serialnum'], id);
    });
  }

  test('rejects another game and inconsistent source platform', () async {
    for (final response in [
      {'system': 'gc', 'gameId': 'GMSE01'},
      {'system': 'wii', 'gameId': 'GZ2E01'},
      {'system': 'gc', 'gameId': 'RZDE01'},
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => response);
      expect(await DusklightGameIdentity.read('/Twilight Princess.iso'), isNull);
    }
  });

  test('unreadable disc does not fall back to its filename', () async {
    messenger.setMockMethodCallHandler(channel, (_) async =>
        throw PlatformException(code: 'unreadable'));
    expect(await DusklightGameIdentity.read('/Twilight Princess.rvz'), isNull);
  });

  test('Ports is selectable for batch scraping without a global console mapping', () async {
    final helper = DatabaseTestHelper();
    final db = await helper.setUp();
    addTearDown(helper.tearDown);
    await db.execute("INSERT INTO app_systems (id, real_name, folder_name) VALUES ('ports', 'Ports', 'ports')");
    await db.execute("INSERT INTO user_detected_systems (app_system_id, actual_folder_name) VALUES ('ports', 'ports')");
    await ScraperRepository.initializeScraperSystemConfig();
    expect((await ScraperRepository.getScraperSystems()).single['folder_name'], 'ports');
    expect((await ScraperRepository.getSystemMappings()).single['app_system_id'], 'ports');
    expect(await ScraperRepository.getScreenScraperIdByAppSystemId('ports'), isNull);
    expect(await ScraperRepository.getUnmappedSystemsCount(), 0);
  });

  test('scan registers a normal Ports game and preserves preferences on rescan', () async {
    final helper = DatabaseTestHelper();
    final db = await helper.setUp();
    addTearDown(helper.tearDown);
    await db.execute("INSERT INTO app_systems (id, real_name, folder_name) VALUES ('ports', 'Ports', 'ports')");
    await db.execute("INSERT INTO app_system_extensions (system_id, extension) VALUES ('ports', 'rvz')");
    final root = await Directory.systemTemp.createTemp('dusklight-library-');
    addTearDown(() => root.delete(recursive: true));
    final games = await Directory('${root.path}/ports').create();
    final disc = await File('${games.path}/renamed.rvz').writeAsBytes([1, 2, 3]);
    messenger.setMockMethodCallHandler(channel, (call) async =>
        call.arguments['system'] == 'gc' ? {'system': 'gc', 'gameId': 'GZ2P01'} : null);
    const system = SystemModel(id: 'ports', folderName: 'ports', realName: 'Ports',
      iconImage: '', color: '#D7A72E', extensions: ['rvz'], recursiveScan: false);
    await SqliteDatabaseService.scanSystemRoms(system, [root.path]);
    final first = (await SqliteService.getGamesBySystem('ports')).single;
    expect(first.romPath, disc.path);
    expect(first.realName, DusklightGameIdentity.displayTitle);
    expect(first.titleId, 'GZ2P01');
    await db.execute("UPDATE user_roms SET is_favorite = 1, play_time = 42");
    await SqliteDatabaseService.scanSystemRoms(system, [root.path]);
    final second = (await SqliteService.getGamesBySystem('ports')).single;
    expect(second.isFavorite, isTrue);
    expect(second.playTime, 42);
  });

  test('empty playlist instruction covers all twelve languages', () {
    expect(DusklightLocale.emptyLibrary.keys.toSet(),
      {'en', 'fr', 'es', 'pt', 'de', 'it', 'ru', 'zh', 'zh_Hant', 'id', 'ja', 'ko'});
    expect(DusklightLocale.emptyLibrary.values.every((s) => s.contains('Dusklight')), isTrue);
    final source = File('lib/screens/game_screen/my_games_list.dart').readAsStringSync();
    expect(source, contains('_isPortsLibrary ? _buildGamesList() : _buildEmptyState()'));
  });

  for (final width in [430.0, 220.0]) {
    testWidgets('Dusklight label remains separate from tabs at width $width', (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var tapped = false;
      await tester.pumpWidget(ScreenUtilInit(designSize: const Size(844, 390),
        builder: (context, child) => MaterialApp(home: Scaffold(body: SizedBox(
          width: width, child: GameDetailsTabsHeader(
            isScreenshotVideoHidden: false, hasRetroAchievements: true,
            currentTab: DetailTab.wheel, onTabChanged: (_) {}, trailingActionWidth: 100.r,
            trailingAction: TextButton.icon(onPressed: () => tapped = true,
              style: TextButton.styleFrom(padding: EdgeInsets.symmetric(horizontal: 8.r)),
              icon: Icon(Icons.file_upload_outlined, size: 18.r),
              label: Text('Dusklight', style: TextStyle(fontSize: 12.r))),
          ),
        ))),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Dusklight'), findsOneWidget);
      final labelRect = tester.getRect(find.text('Dusklight'));
      final importRect = tester.getRect(find.byIcon(Icons.file_upload_outlined));
      expect(labelRect.left, greaterThanOrEqualTo(importRect.right));
      await tester.tap(find.text('Dusklight'));
      expect(tapped, isTrue);
    });
  }
}
