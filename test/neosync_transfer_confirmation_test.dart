import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = DatabaseTestHelper();
  late Directory directory;
  late File file;
  final bytes = [1, 2, 3, 4];
  final digest = md5.convert(bytes).toString();
  const key = 'v2/saves/snes/retroarch/game/Game/Game.srm';
  setUp(() async {
    await db.setUp();
    SharedPreferences.setMockInitialValues({'auth_token': 'account-one'});
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'account-one'});
    directory = await Directory.systemTemp.createTemp('neosync-transfer-');
    file = await File('${directory.path}/Game.srm').writeAsBytes(bytes);
  });
  tearDown(() async { await directory.delete(recursive: true); await db.tearDown(); });

  test('an unavailable or malformed check cannot overwrite an unverified cloud save', () async {
    for (final response in [http.Response('Unavailable', 503), http.Response('{}', 200)]) {
      var requests = 0;
      final service = NeoSyncService();
      final result = await http.runWithClient(() => service.syncFile(file, 'Game', customFilename: key),
        () => MockClient((request) async {
          requests++;
          expect(request.url.path, '/api/v2/files/check');
          return response;
        }));
      expect(requests, 1);
      expect(result['success'], isFalse);
      expect(service.lastError, isNotNull);
      expect(await SyncRepository.getSyncState(file.path), isNull);
    }
  });

  test('remote-newer is deferred download, not a confirmed successful sync', () async {
    for (final needsSync in [true, false]) {
      final result = await http.runWithClient(() => NeoSyncService().syncFile(file, 'Game', customFilename: key),
        () => MockClient((request) async {
          expect(request.url.path, '/api/v2/files/check');
          return http.Response(jsonEncode({'exists': true, 'needs_sync': needsSync, 'remote_newer': true}), 200);
        }));
      expect(result['success'], isTrue);
      expect(result['pending_download'], isTrue);
      expect(result['synced'], isFalse);
      expect(await SyncRepository.getSyncState(file.path), isNull);
    }
  });

  test('a confirmed hash skip records the actual synchronized content', () async {
    final result = await http.runWithClient(() => NeoSyncService().syncFile(file, 'Game', customFilename: key),
      () => MockClient((request) async {
        final check = jsonDecode(request.body) as Map;
        expect(check['hash'], digest);
        expect(check['filename'], 'Game.srm');
        return http.Response(jsonEncode({'exists': true, 'needs_sync': false}), 200);
      }));
    expect(result['synced'], isTrue);
    expect(result['skipped'], isTrue);
    expect((await SyncRepository.getSyncState(file.path))?['file_hash'], digest);
  });

  test('HTTP 201 alone cannot mark a save synced without matching remote bytes', () async {
    var checks = 0;
    var uploads = 0;
    final result = await http.runWithClient(() => NeoSyncService().syncFile(file, 'Game', customFilename: key),
      () => MockClient((request) async {
        if (request.url.path == '/api/v2/files/check') {
          checks++;
          return http.Response(jsonEncode({'exists': checks > 1, 'needs_sync': true}), 200);
        }
        expect(request.url.path, '/api/v2/upload');
        uploads++;
        return http.Response(jsonEncode({'message': 'uploaded'}), 201);
      }));
    expect(checks, 2);
    expect(uploads, 1);
    expect(result['success'], isFalse);
    expect(result['verification_pending'], isTrue);
    expect(await SyncRepository.getSyncState(file.path), isNull);
  });

  test('upload is recorded after a fresh checksum check confirms its key and bytes', () async {
    var checks = 0;
    final result = await http.runWithClient(() => NeoSyncService().syncFile(file, 'Game', customFilename: key),
      () => MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer account-one');
        if (request.url.path == '/api/v2/files/check') {
          checks++;
          expect((jsonDecode(request.body) as Map)['hash'], digest);
          return http.Response(jsonEncode({'exists': checks > 1, 'needs_sync': checks == 1}), 200);
        }
        return http.Response(jsonEncode({'message': 'uploaded'}), 201);
      }));
    expect(checks, 2);
    expect(result['success'], isTrue);
    expect((await SyncRepository.getSyncState(file.path))?['file_hash'], digest);
  });

  test('mismatching server hash rejects both normal and forced uploads', () async {
    for (final force in [false, true]) {
      final service = NeoSyncService();
      final result = await http.runWithClient(() => force
          ? service.uploadFile(file, 'Game', customFilename: key)
          : service.syncFile(file, 'Game', customFilename: key),
        () => MockClient((request) async {
          if (request.url.path == '/api/v2/files/check') {
            return http.Response(jsonEncode({'exists': false, 'needs_sync': true}), 200);
          }
          return http.Response(jsonEncode({'file_hash': md5.convert([9]).toString()}), 201);
        }));
      expect(result['success'], isFalse, reason: 'forced=$force');
      expect(result['verification_pending'], isTrue);
      expect(await SyncRepository.getSyncState(file.path), isNull);
    }
  });

  test('an account change between preflight and upload stops the transfer', () async {
    var requests = 0;
    final result = await http.runWithClient(() => NeoSyncService().syncFile(file, 'Game', customFilename: key),
      () => MockClient((request) async {
        requests++;
        expect(request.url.path, '/api/v2/files/check');
        await (await SharedPreferences.getInstance()).setString('auth_token', 'account-two');
        FlutterSecureStorage.setMockInitialValues({'auth_token': 'account-two'});
        return http.Response(jsonEncode({'exists': false, 'needs_sync': true}), 200);
      }));
    expect(requests, 1);
    expect(result['success'], isFalse);
    expect(await SyncRepository.getSyncState(file.path), isNull);
  });
}
