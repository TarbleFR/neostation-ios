import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/l10n/rpcs3_library_locale.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/services/rpcs3_launch_service.dart';
import 'package:neostation/services/screenscraper/media_downloader.dart';
import 'package:neostation/services/screenscraper_service.dart';

void main() {
  group('RPCS3 persistence, media and launch', () {
    test('ScreenScraper lookup carries the PS3 serial number', () {
      final params = ScreenScraperService.buildGameLookupParametersForTesting(
        systemId: '59',
        romName: 'BLES00113',
        serialNumber: ' BLES00113 ',
      );
      expect(params['systemeid'], '59');
      expect(params['romnom'], 'BLES00113');
      expect(params['serialnum'], 'BLES00113');
    });

    test('RPCS3 retries by title only when it is better than the serial', () {
      expect(
        ScreenScraperService.shouldRetryRpcs3ByNameForTesting(
          'The Lord of the Rings: Conquest',
          'BLES00412',
        ),
        isTrue,
      );
      expect(
        ScreenScraperService.shouldRetryRpcs3ByNameForTesting(
          'BLES00412',
          'BLES00412',
        ),
        isFalse,
      );
    });

    test('all URI-backed emulator rows survive physical scans', () {
      expect(
        SqliteDatabaseService.isPersistentExternalLibraryPath(
          'rpcs3-library://game?title-id=BLES00113',
        ),
        isTrue,
      );
      expect(
        SqliteDatabaseService.isPersistentExternalLibraryPath('melonx://game'),
        isTrue,
      );
      expect(
        SqliteDatabaseService.isPersistentExternalLibraryPath('armsx2://game'),
        isTrue,
      );
      expect(
        SqliteDatabaseService.isPersistentExternalLibraryPath('/roms/game.iso'),
        isFalse,
      );
    });

    test('ScreenScraper text statuses are rejected as media', () {
      for (final status in ['NOMEDIA', 'CRCOK', 'MD5OK', 'SHA1OK']) {
        expect(
          ScreenscraperMediaDownloader.isValidMediaPayload(
            status.codeUnits,
            mediaType: 'video',
          ),
          isFalse,
        );
      }
    });

    test('MP4 and PNG signatures are accepted', () {
      expect(
        ScreenscraperMediaDownloader.isValidMediaPayload(const [
          0,
          0,
          0,
          24,
          0x66,
          0x74,
          0x79,
          0x70,
          0x69,
          0x73,
          0x6f,
          0x6d,
        ], mediaType: 'video'),
        isTrue,
      );
      expect(
        ScreenscraperMediaDownloader.isValidMediaPayload(const [
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
        ], mediaType: 'box2D'),
        isTrue,
      );
    });

    test('RPCS3 launcher uses the stable Universal JIT handoff', () {
      final service = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();
      expect(service, contains('openJitRequest'));
      expect(service, contains("scriptName: 'universal.js'"));
      expect(service, contains('rpcs3_launch_debug.txt'));
    });

    test('invalid RPCS3 title IDs are rejected', () {
      expect(Rpcs3LaunchService.normalizeTitleId('../bad'), isNull);
      expect(Rpcs3LaunchService.normalizeTitleId('BLES00412'), 'BLES00412');
    });

    test('synthetic ScreenScraper serial falls back to PARAM.SFO title', () {
      final game = GameModel.fromDatabaseModel(
        DatabaseGameModel(
          filename: 'BLES00412',
          romPath: 'rpcs3-library://game?title-id=BLES00412',
          titleId: 'BLES00412',
          titleName: 'The Lord of the Rings: Conquest™',
          realName: 'BLES00412',
          screenscraperRealName: 'BLES00412',
        ),
      );
      expect(game.name, 'The Lord of the Rings: Conquest™');
      expect(game.realname, 'The Lord of the Rings: Conquest™');
    });

    test('scraped RPCS3 name replaces the local fallback title', () {
      final game = GameModel.fromDatabaseModel(
        DatabaseGameModel(
          filename: 'BLES00412',
          romPath: 'rpcs3-library://game?title-id=BLES00412',
          titleId: 'BLES00412',
          titleName: 'The Lord of the Rings: Conquest',
          screenscraperRealName:
              'Le Seigneur des Anneaux : L’Âge des conquêtes',
        ),
      );
      expect(game.name, 'Le Seigneur des Anneaux : L’Âge des conquêtes');
      expect(game.titleId, 'BLES00412');
    });

    test('French RPCS3 status uses natural singular and plural', () {
      expect(
        Rpcs3LibraryLocale.statusSyncedForLocale('fr', 1),
        'RPCS3 synchronisé — 1 jeu PS3.',
      );
      expect(
        Rpcs3LibraryLocale.statusSyncedForLocale('fr', 2),
        'RPCS3 synchronisé — 2 jeux PS3.',
      );
    });
  });
}
