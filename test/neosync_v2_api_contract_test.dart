import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/neo_sync_save_units.dart';
import 'package:neostation/services/neosync/neo_sync_save_policy.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/neosync/neo_sync_wire_contract.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// These fixtures encode the published client contract, not a captured account:
// https://github.com/misobadev/neostation-frontend/commit/11d3f7fdd127910e45a1b2759b96a02581ee6ae6
// syncFile sends file_path/type and checks that same relative path. The previous
// tests accepted only the app's obsolete file_name envelope, hiding this break.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = DatabaseTestHelper();
  late Directory directory;
  final bytes = [1, 2, 3, 4];
  final hash = md5.convert(bytes).toString();

  setUp(() async {
    await db.setUp();
    SharedPreferences.setMockInitialValues({'auth_token': 'account-one'});
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'account-one'});
    directory = await Directory.systemTemp.createTemp('neosync-wire-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
    await db.tearDown();
  });

  final cases = <({String key, String path, String type, String system, String emulator})>[
    (key: 'v2/saves/n64/retroarch.mupen64plus-next/game/Mario/Mario.srm',
      path: 'Mario.srm', type: 'save', system: 'n64', emulator: 'retroarch.mupen64plus-next'),
    (key: 'v2/states/n64/retroarch.mupen64plus-next/game/Mario/Mario.state1',
      path: 'Mario.state1', type: 'state', system: 'n64', emulator: 'retroarch.mupen64plus-next'),
    (key: 'v2/saves/gc/dolphinios/game/GMSE01/gci-USA-A.nsav',
      path: 'GMSE01/gci-USA-A.nsav', type: 'save', system: 'gc', emulator: 'dolphinios'),
    (key: 'v2/saves/wii/dolphinios/game/00010000524d4350/wii-data.nsav',
      path: '00010000524d4350/wii-data.nsav', type: 'save', system: 'wii', emulator: 'dolphinios'),
    (key: 'v2/states/wii/dolphinios/game/00010000524d4350/RMCP01.s01.nsav',
      path: '00010000524d4350/RMCP01.s01.nsav', type: 'state', system: 'wii', emulator: 'dolphinios'),
    (key: 'v2/saves/gc/dolphinios/shared/MemoryCardA.USA.raw.nsav',
      path: 'MemoryCardA.USA.raw.nsav', type: 'shared', system: 'gc', emulator: 'dolphinios'),
    (key: 'v2/saves/ps3/rpcs3/game/Game/00000001/BLUS12345-SAVE/PARAM.SFO',
      path: '00000001/BLUS12345-SAVE/PARAM.SFO', type: 'save', system: 'ps3', emulator: 'rpcs3'),
  ];

  for (final fixture in cases) {
    test('published v2 multipart/check identity: ${fixture.path}', () async {
      final file = await File('${directory.path}/${fixture.path.split('/').last}')
          .writeAsBytes(bytes);
      var checks = 0;
      var uploads = 0;
      final title = fixture.system == 'ps3' ? 'Game' : 'Human game title';
      final result = await http.runWithClient(() => NeoSyncService().syncFile(
          file, title, customFilename: fixture.key,
          systemId: 'stale-system', emulatorId: 'stale-emulator',
          isState: fixture.type != 'state', scope: 'stale-scope'),
        () => MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer account-one');
          if (request.url.path == '/api/v2/files/check') {
            checks++;
            final body = jsonDecode(request.body) as Map;
            expect(body['filename'], fixture.path);
            expect(body['hash'], hash);
            // The upstream client permits an absent optional needs_sync when
            // existence is explicitly false. It never means a verified match.
            return http.Response(jsonEncode(checks == 1
                ? {'exists': false} : {'exists': true, 'needs_sync': false}), 200);
          }
          expect(request.url.path, '/api/v2/upload');
          uploads++;
          for (final field in {
            'file_path': fixture.path, 'type': fixture.type,
            'system_id': fixture.system, 'emulator_id': fixture.emulator,
            'file_hash': hash, 'game_name': title,
          }.entries) {
            expect(request.body, contains('name="${field.key}"\r\n\r\n${field.value}\r\n'));
          }
          // No hash in the upload response: confirmation must query the same
          // *wire* identity, rather than the obsolete canonical filename.
          return http.Response(jsonEncode({'message': 'uploaded'}), 201);
        }));
      expect(checks, 2);
      expect(uploads, 1);
      expect(result['success'], isTrue);
      expect((await SyncRepository.getSyncState(file.path))?['file_hash'], hash);
      // Model the published listing response: no file_name envelope survives.
      // This is exactly the schema our previous tests never round-tripped.
      final listed = NeoSyncFile.fromJson({
        'id': 'listed-object', 'file_path': fixture.path, 'type': fixture.type,
        'system_name': fixture.system, 'emulator': fixture.emulator,
        'game_name': title, 'file_hash': hash, 'file_size': bytes.length,
        'user_id': 'account-one', 'created_at': '2026-09-06T00:00:00Z',
      });
      expect(listed.sourceSavePath, fixture.key);
      expect(listed.saveKind, NeoSyncSaveKind.save);
      expect(NeoSyncSaveUnits.cloud([listed]), hasLength(1));
    });
  }

  test('forced restore replacement uses the same v2 wire fields', () async {
    final fixture = cases.first;
    final file = await File('${directory.path}/Mario.srm').writeAsBytes(bytes);
    final result = await http.runWithClient(() => NeoSyncService().uploadFile(
        file, 'Mario', customFilename: fixture.key),
      () => MockClient((request) async {
        expect(request.url.path, '/api/v2/upload');
        expect(request.body, contains('name="file_path"\r\n\r\nMario.srm\r\n'));
        expect(request.body, contains('name="type"\r\n\r\nsave\r\n'));
        return http.Response(jsonEncode({'file_hash': hash}), 201);
      }));
    expect(result['success'], isTrue);
  });

  test('RetroArch uploads preserve the actual core folder from source proof', () async {
    final root = Directory('${directory.path}/saves');
    final file = File('${root.path}/Mupen64Plus-Next/Mario.srm');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    final source = NeoSyncSaveSource.resolve(filePath: file.path,
        rootPath: root.path, family: NeoSyncSaveFamily.retroArchSaves)!;
    final result = await http.runWithClient(() => NeoSyncService().syncFile(
        file, 'Mario', customFilename: cases.first.key, source: source),
      () => MockClient((request) async {
        if (request.url.path == '/api/v2/files/check') {
          expect((jsonDecode(request.body) as Map)['filename'],
              'Mupen64Plus-Next/Mario.srm');
          return http.Response(jsonEncode({'exists': false, 'needs_sync': true}), 200);
        }
        expect(request.body, contains('name="file_path"\r\n\r\nMupen64Plus-Next/Mario.srm\r\n'));
        return http.Response(jsonEncode({'file_hash': hash}), 201);
      }));
    expect(result['success'], isTrue);
  });

  test('shared nested paths keep their first directory', () {
    final wire = NeoSyncWireIdentity.fromCloudKey(
        'v2/saves/ps2/armsx2/shared/memcards/slot1/Mcd001.ps2');
    expect(wire.filePath, 'memcards/slot1/Mcd001.ps2');
    expect(wire.type, 'shared');
  });

  test('Dolphin games never collapse onto one shared snapshot filename', () {
    final first = NeoSyncWireIdentity.fromCloudKey(cases[2].key);
    final second = NeoSyncWireIdentity.fromCloudKey(
        cases[2].key.replaceFirst('GMSE01', 'GZLE01'));
    expect(first.filePath, isNot(second.filePath));
  });

  test('malformed existing-file checks remain blocked', () async {
    final result = await http.runWithClient(() => NeoSyncService()
        .checkFileExists('Mario.srm', hash, bytes.length),
      () => MockClient((request) async => http.Response('{"exists":true}', 200)));
    expect(result['success'], isFalse);
  });

  test('transport never creates unsafe native destinations', () {
    for (final key in ['saves/../game.srm', 'saves//game.srm',
        '/private/game.srm', 'states/C:/game.state']) {
      expect(() => NeoSyncWireIdentity.fromCloudKey(key), throwsFormatException);
    }
  });
}
