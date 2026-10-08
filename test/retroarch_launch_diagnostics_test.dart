import 'dart:convert';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_library_service.dart';
import 'package:neostation/services/retroarch_library_importer.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cache miss, rejected handoff and native error remain distinguishable',
    () async {
      final helper = DatabaseTestHelper();
      final db = await helper.setUp();
      addTearDown(helper.tearDown);
      var sends = 0;
      Future<bool> accepted(String url) async {
        sends++;
        return true;
      }

      final empty = await RetroArchLibraryService.launchGameWithDiagnostics(
        '/gba/a.gba',
        openUrl: accepted,
      );
      expect(empty.stage, RetroArchLaunchStage.cacheEmpty);
      expect(sends, 0);
      await db.insert('app_systems', {
        'id': 'gba',
        'folder_name': 'gba',
        'real_name': 'Game Boy Advance',
        'manufacturer': 'Nintendo',
      });
      const filename = 'Épreuve (Europe).zip#Épreuve.gba';
      const system = 'Nintendo - Game Boy Advance';
      await RetroArchLibraryService.handleIncomingUri(
        Uri(
          scheme: 'neostation',
          host: 'retroarch',
          queryParameters: {
            'games': base64Url.encode(
              utf8.encode(
                jsonEncode([
                  {'filename': filename, 'system': system, 'coreName': 'mGBA'},
                ]),
              ),
            ),
          },
        ),
      );
      final romPath = RetroArchLibraryImporter.libraryPath(system, filename);
      final missing = await RetroArchLibraryService.launchGameWithDiagnostics(
        '/gba/absent.gba',
        openUrl: accepted,
      );
      expect(missing.stage, RetroArchLaunchStage.entryMissing);
      expect(sends, 0);
      final rejected = await RetroArchLibraryService.launchGameWithDiagnostics(
        romPath,
        openUrl: (_) async => false,
      );
      expect(rejected.stage, RetroArchLaunchStage.handoffRejected);
      expect(rejected.accepted, isFalse);
      final error = await RetroArchLibraryService.launchGameWithDiagnostics(
        romPath,
        openUrl: (_) async => throw PlatformException(
          code: 'TEST_NATIVE_FAILURE',
          message: 'native detail',
        ),
      );
      expect(error.stage, RetroArchLaunchStage.handoffError);
      expect(error.details, contains('TEST_NATIVE_FAILURE'));
      final result = await RetroArchLibraryService.launchGameWithDiagnostics(
        romPath,
        openUrl: (url) async {
          final uri = Uri.parse(url);
          expect(uri.host, 'game');
          expect(uri.pathSegments, [filename]);
          return accepted(url);
        },
      );
      expect(result.stage, RetroArchLaunchStage.handoffAccepted);
      expect(sends, 1);
      expect(result.details, contains('no game-start acknowledgement'));
    },
  );
  test(
    'same launch filename from two playlist records is retained and rejected before handoff',
    () async {
      final helper = DatabaseTestHelper();
      final db = await helper.setUp();
      addTearDown(helper.tearDown);
      await db.insert('app_systems', {
        'id': 'gbc',
        'folder_name': 'gbc',
        'real_name': 'Game Boy Color',
        'manufacturer': 'Nintendo',
      });
      const system = 'Nintendo - Game Boy Color';
      const filename = 'Karate Joe (Europe) (Unl).gbc';
      final entries = [
        {'system': system, 'filename': filename, 'gameId': '$system.lpl:194'},
        {'system': system, 'filename': filename, 'gameId': '$system.lpl:195'},
      ];
      await RetroArchLibraryService.handleIncomingUri(
        Uri(
          scheme: 'neostation',
          host: 'retroarch',
          queryParameters: {
            'games': base64Url.encode(utf8.encode(jsonEncode(entries))),
          },
        ),
      );
      var sends = 0;
      final attempt = await RetroArchLibraryService.launchGameWithDiagnostics(
        RetroArchLibraryImporter.libraryPath(system, filename),
        openUrl: (_) async {
          sends++;
          return true;
        },
      );
      expect(attempt.stage, RetroArchLaunchStage.ambiguousEntry);
      expect(attempt.details, contains('exportRecords=2'));
      expect(attempt.accepted, isFalse);
      expect(sends, 0);
    },
  );
  test(
    'cached launch sends once without a sync; double taps stay serialized',
    () async {
      final helper = DatabaseTestHelper();
      final db = await helper.setUp();
      addTearDown(helper.tearDown);
      await db.insert('app_systems', {
        'id': 'n64',
        'folder_name': 'n64',
        'real_name': 'Nintendo 64',
        'manufacturer': 'Nintendo',
      });
      const filename = '007 - The World Is Not Enough (Europe) (En,Fr,De).n64';
      const system = 'Nintendo - Nintendo 64';
      await RetroArchLibraryService.handleIncomingUri(
        Uri(
          scheme: 'neostation',
          host: 'retroarch',
          queryParameters: {
            'games': base64Url.encode(
              utf8.encode(
                jsonEncode([
                  {
                    'filename': filename,
                    'system': system,
                    'gameId': '$system.lpl:0',
                  },
                ]),
              ),
            ),
          },
        ),
      );
      final pending = Completer<bool>();
      final sent = <String>[];
      Future<bool> open(String url) {
        sent.add(url);
        return pending.future;
      }

      final romPath = RetroArchLibraryImporter.libraryPath(system, filename);
      final first = RetroArchLibraryService.launchGameWithDiagnostics(
        romPath,
        openUrl: open,
      );
      await Future<void>.delayed(Duration.zero);
      expect(sent.length, 1);
      expect(Uri.parse(sent.single).host, 'game');
      final second = await RetroArchLibraryService.launchGameWithDiagnostics(
        romPath,
        openUrl: open,
      );
      expect(second.stage, RetroArchLaunchStage.launchBusy);
      expect(sent.length, 1);
      pending.complete(true);
      expect((await first).stage, RetroArchLaunchStage.handoffAccepted);
      final retry = await RetroArchLibraryService.launchGameWithDiagnostics(
        romPath,
        openUrl: (_) async => false,
      );
      expect(retry.stage, RetroArchLaunchStage.handoffRejected);
    },
  );
}
