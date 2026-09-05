import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/neosync/legacy_neo_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'auth_token': 'account-one'});
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'account-one'});
  });
  Future<void> switchAccount() async {
    await (await SharedPreferences.getInstance()).setString('auth_token', 'account-two');
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'account-two'});
  }
  final firstPage = List.generate(200, (i) => {'id': 'save-$i', 'file_name': 'Game-$i.sav'});

  test('complete v2 pagination precedes source lookup and any cloud deletion', () async {
    final calls = <String>[];
    final service = NeoSyncService();
    final result = await http.runWithClient(() => service.auditAndPurge(
      resolveOrigins: (files) async {
        expect(files, hasLength(201));
        calls.add('investigate');
        return files;
      }), () => MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer account-one');
      if (request.method == 'GET') {
        final offset = request.url.queryParameters['offset'];
        calls.add('list-$offset');
        return http.Response(jsonEncode({'files': offset == '0' ? firstPage :
          [{'id': 'dlc', 'file_name': 'Smash Costume.nsp'}]}), 200);
      }
      expect(request.method, 'DELETE');
      expect(request.url.path, '/api/v2/files/dlc');
      calls.add('delete');
      return http.Response('', 204);
    }));
    expect(calls, ['list-0', 'list-200', 'investigate', 'delete']);
    expect(result['success'], isTrue);
    expect(result['deleted'], 1);
    expect(result['files'], hasLength(200));
  });

  test('a missing page prevents every delete, even if page one contained DLC', () async {
    var deletes = 0;
    var investigated = false;
    final result = await http.runWithClient(() => NeoSyncService().auditAndPurge(
      resolveOrigins: (files) async { investigated = true; return files; }),
      () => MockClient((request) async {
        if (request.method == 'DELETE') deletes++;
        if (request.url.queryParameters['offset'] == '0') {
          return http.Response(jsonEncode({'files': [
            {'id': 'dlc', 'file_name': 'Spirit.nsp'}, ...firstPage.skip(1)]}), 200);
        }
        return http.Response('unavailable', 503);
      }));
    expect(result['success'], isFalse);
    expect(investigated, isFalse);
    expect(deletes, 0);
  });

  test('account switch after investigation never issues a delete', () async {
    var deletes = 0;
    final result = await http.runWithClient(() => NeoSyncService().auditAndPurge(
      resolveOrigins: (files) async { await switchAccount(); return files; }),
      () => MockClient((request) async {
        if (request.method == 'DELETE') deletes++;
        return http.Response(jsonEncode({'files': [{'id': 'dlc', 'file_name': 'Costume.nsp'}]}), 200);
      }));
    expect(result['success'], isFalse);
    expect(deletes, 0);
  });

  test('token changes during purge stop subsequent deletions', () async {
    var deletes = 0;
    final result = await http.runWithClient(() => NeoSyncService().auditAndPurge(
      resolveOrigins: (files) async => files), () => MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer account-one');
        if (request.method == 'DELETE') {
          deletes++;
          await switchAccount();
          return http.Response('', 204);
        }
        return http.Response(jsonEncode({'files': [
          {'id': 'one', 'file_name': 'Costume.nsp'},
          {'id': 'two', 'file_name': 'Spirit.nsp'}]}), 200);
      }));
    expect(result['success'], isFalse);
    expect(deletes, 1);
  });

  test('legacy malformed, paginated and dangerous-ID inventories never delete', () async {
    for (final payload in [
      {}, {'files': 'invalid'}, {'files': [123]},
      for (final id in ['', '.', '..', 'folder/file'])
        {'files': [{'id': id, 'file_name': 'Costume.nsp'}]},
      {'files': [{'id': 'valid', 'file_name': 'Costume.nsp'}], 'has_more': true},
      {'files': [{'id': 'valid', 'file_name': 'Costume.nsp'}], 'total': 2},
      {'files': [], 'pagination': {'next_cursor': 'next'}},
    ]) {
      var deletes = 0;
      final result = await http.runWithClient(() => LegacyNeoSyncService().auditAndPurge(
        resolveOrigins: (files) async => files), () => MockClient((request) async {
          if (request.method == 'DELETE') deletes++;
          return http.Response(jsonEncode(payload), 200);
        }));
      expect(result['success'], isFalse, reason: '$payload');
      expect(deletes, 0, reason: '$payload');
    }
  });

  test('legacy saves survive while an acknowledged DLC delete targets one object', () async {
    final calls = <String>[];
    final result = await http.runWithClient(() => LegacyNeoSyncService().auditAndPurge(
      resolveOrigins: (files) async => files), () => MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.method == 'DELETE') return http.Response('', 204);
        return http.Response(jsonEncode({'files': [
          {'id': 'ps3', 'file_name': 'dev_hdd0/home/00000001/savedata/BLES00050/ICON0.PNG'},
          {'id': 'dlc', 'file_name': 'Smash Spirit.nsp'}]}), 200);
      }));
    expect(result['success'], isTrue);
    expect(result['files'], hasLength(1));
    expect(calls, ['GET /api/v1/files', 'DELETE /api/v1/files/dlc']);
  });

  test('both upload APIs reject DLC before file reads or network requests', () async {
    var calls = 0;
    await http.runWithClient(() async {
      final service = NeoSyncService();
      final file = File('/Documents/MeloNX/DLC/Smash Costume.nsp');
      const key = 'v2/saves/switch/melonx/game/Smash/main';
      for (final result in [
        await service.syncFile(file, 'Smash', customFilename: key),
        await service.uploadFile(file, 'Smash', customFilename: key),
      ]) {
        expect(result['success'], isFalse);
        expect(result['excluded'], isTrue);
      }
    }, () => MockClient((request) async { calls++; return http.Response('', 500); }));
    expect(calls, 0);
  });
}
