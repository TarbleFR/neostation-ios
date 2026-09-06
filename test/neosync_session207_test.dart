import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/user.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/services/dolphin_neosync_store.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/neosync/neo_sync_wire_contract.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

class _SignedIn207 extends AuthService {
  @override bool get isLoggedIn => true;
  @override User get currentUser => User.fromJson({'id': 'account-one'});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final database = DatabaseTestHelper();
  late Directory root;
  setUp(() async {
    await database.setUp();
    SharedPreferences.setMockInitialValues({'auth_token': 'account-one'});
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'account-one'});
    root = await Directory.systemTemp.createTemp('neosync-session207-');
  });
  tearDown(() async { await root.delete(recursive: true); await database.tearDown(); });

  test('hash-only upload preserves native save time instead of making an old state look new', () async {
    final file = await File('${root.path}/Game.p2s').writeAsBytes([1, 2, 3, 4]);
    await file.setLastModified(DateTime.utc(2026, 8, 20, 12));
    final timestamp = (await file.lastModified()).millisecondsSinceEpoch;
    var uploads = 0;
    final service = NeoSyncService();
    final result = await http.runWithClient(() => service.syncFile(file, 'Game',
      customFilename: 'v2/states/ps2/armsx2/shared/sstates/Game.p2s', contentHashOnly: true),
      () => MockClient((request) async {
        if (request.url.path == '/api/v2/files/check') {
          expect(jsonDecode(request.body), isNot(contains('local_modified_at_timestamp')));
          return http.Response('{"exists":false,"needs_sync":true}', 200);
        }
        uploads++;
        final body = latin1.decode(request.bodyBytes);
        expect(body, contains('name="file_modified_at_timestamp"\r\n\r\n$timestamp\r\n'));
        return http.Response(jsonEncode({'file_hash': md5.convert([1,2,3,4]).toString()}), 201);
      }));
    expect(result['success'], isTrue);
    expect(uploads, 1);
  });

  test('unchanged hash produces no upload and leaves native mtime untouched', () async {
    final file = await File('${root.path}/Game.p2s').writeAsBytes([1,2,3,4]);
    await file.setLastModified(DateTime.utc(2026, 8, 20));
    final original = await file.lastModified();
    final result = await http.runWithClient(() => NeoSyncService().syncFile(file, 'Game',
      customFilename: 'v2/states/ps2/armsx2/shared/sstates/Game.p2s', contentHashOnly: true),
      () => MockClient((request) async {
        expect(request.url.path, '/api/v2/files/check');
        return http.Response('{"exists":true,"needs_sync":false}', 200);
      }));
    expect(result['synced'], isTrue);
    expect(result['skipped'], isTrue);
    expect(await file.lastModified(), original);
  });

  test('actual GC and Wii native snapshots upload through typed API and reach the account view', () async {
    final user = await Directory('${root.path}/User').create();
    final store = DolphinNeoSyncStore(user, Directory('${root.path}/NeoSync'));
    const gc = DolphinSaveIdentity(system: 'gc', gameId: 'GMSE01', region: 'USA');
    const wii = DolphinSaveIdentity(system: 'wii', gameId: 'RMGP01', region: 'EUR',
      titleId: '00010000524d4750');
    final gcDir = await Directory('${user.path}/GC/USA/Card A').create(recursive: true);
    final gci = Uint8List(64 + 8192)..setRange(0, 6, ascii.encode('GMSE01'));
    gci[0x39] = 1;
    await File('${gcDir.path}/native.gci').writeAsBytes(gci);
    final wiiDir = await Directory('${user.path}/Wii/title/00010000/524d4750/data').create(recursive: true);
    await File('${wiiDir.path}/GameData.bin').writeAsBytes([1,2,3,4]);
    final service = NeoSyncService();
    final provider = NeoSyncProvider(service)..setAuthService(_SignedIn207());
    addTearDown(provider.dispose);
    final remote = <Map<String, dynamic>>[];
    for (final identity in [gc, wii]) {
      final target = DolphinSaveTarget.forGame(identity).first;
      final snapshot = await store.snapshot(target);
      expect(snapshot, isNotNull);
      final wire = NeoSyncWireIdentity.fromCloudKey(target.cloudPath);
      final result = await http.runWithClient(() => service.syncFile(snapshot!.file, 'Native save',
        customFilename: target.cloudPath, systemId: target.system,
        emulatorId: 'dolphinios', scope: 'game', isState: false),
        () => MockClient((request) async {
          if (request.url.path == '/api/v2/files/check') {
            expect((jsonDecode(request.body) as Map)['filename'], wire.filePath);
            return http.Response('{"exists":false,"needs_sync":true}', 200);
          }
          final body = latin1.decode(request.bodyBytes);
          expect(body, contains('name="file_path"\r\n\r\n${wire.filePath}\r\n'));
          remote.add({'id': identity.system, 'file_path': wire.filePath,
            'type': 'save', 'system_name': target.system, 'emulator': 'dolphinios',
            'file_size': snapshot!.size, 'file_hash': snapshot.checksum});
          return http.Response(jsonEncode({'file_hash': snapshot.checksum}), 201);
        }));
      expect(result['success'], isTrue);
      await http.runWithClient(() => provider.loadFiles(),
        () => MockClient((_) async => http.Response(jsonEncode({'files': remote}), 200)));
      expect(provider.onlineFiles, hasLength(remote.length));
      expect(provider.onlineFiles.any((file) => file.dolphinTarget?.cloudPath == target.cloudPath), isTrue);
    }
    final before = provider.onlineFiles.map((file) => file.id).toList();
    await http.runWithClient(() => provider.loadFiles(),
      () => MockClient((_) async => http.Response('Unavailable', 503)));
    expect(provider.onlineFiles.map((file) => file.id), before);
    expect(provider.error, contains('503'));
  });

  test('waiting for native files is neither a confirmed sync nor an error', () {
    final state = GameSyncState(gameId: 'wii', gameName: 'Wii game',
      status: GameSyncStatus.pending, cloudEnabled: true);
    expect(state.lastSync, isNull);
    expect(state.errorMessage, isNull);
    expect(state.statusDisplayText, 'Waiting for emulator files');
  });
}
