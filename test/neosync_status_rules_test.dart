import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/neosync/neo_sync_status_rules.dart';

void main() {
  late Directory directory;
  final modified = DateTime.utc(2026, 9, 5, 12);
  setUp(() async { directory = await Directory.systemTemp.createTemp('neosync-status-'); });
  tearDown(() async { await directory.delete(recursive: true); });

  Future<LocalSaveFile> local(String name, List<int> bytes, {String? key}) async {
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(bytes);
    await file.setLastModified(modified);
    return LocalSaveFile(filePath: file.path, fileName: name, fileSize: bytes.length,
      lastModified: modified, gameName: 'Game', isSynced: false,
      relativePath: key ?? 'v2/saves/snes/retroarch/game/Game/$name');
  }
  NeoSyncFile remote(String key, List<int> bytes, {bool compress = false, String? hash}) =>
      NeoSyncFile.fromJson({'id': key, 'file_name': '$key${compress ? '.neosync.gz' : ''}',
        'file_size': bytes.length, 'file_hash': hash ?? md5.convert(compress ? gzip.encode(bytes) : bytes).toString(),
        'file_modified_at_timestamp': modified.millisecondsSinceEpoch});

  test('all native saves and states must match regardless of cloud listing order', () async {
    final save = await local('Game.srm', [1, 2, 3]);
    final state = await local('Game.state1', [4, 5, 6], key: 'v2/states/snes/retroarch/game/Game/Game.state1');
    final clouds = [remote(state.relativePath, [4, 5, 6]), remote(save.relativePath, [1, 2, 3])];
    expect(await NeoSyncStatusRules.aggregate([save, state], clouds), GameSyncStatus.upToDate);
    await File(state.filePath).writeAsBytes([7, 8, 9]);
    await File(state.filePath).setLastModified(modified);
    expect(await NeoSyncStatusRules.aggregate([save, state], clouds), GameSyncStatus.localOnly,
        reason: 'one matching SRAM must not hide a changed state with identical size and mtime');
  });

  test('one missing state remains pending even if the first save is confirmed', () async {
    final save = await local('Game.srm', [1]);
    final state = await local('Game.state1', [2]);
    final cloudSave = remote(save.relativePath, [1]);
    expect(await NeoSyncStatusRules.aggregate([save, state], [cloudSave]), GameSyncStatus.localOnly);
    expect(await NeoSyncStatusRules.aggregate([save], [cloudSave, remote(state.relativePath, [2])]),
      GameSyncStatus.cloudOnly);
    expect(await NeoSyncStatusRules.aggregate([], []), GameSyncStatus.noSaveFound);
  });

  test('compressed transport keys still compare native bytes for each emulator', () async {
    for (final key in [
      'v2/saves/ps2/armsx2/shared/MemoryCard1.ps2',
      'v2/states/psp/ppsspp/game/Game/Game.ppst',
      'v2/saves/snes/retroarch/game/Game/Game.srm',
    ]) {
      final save = await local('${key.hashCode}.sav', [1, 2, 3], key: key);
      expect(await NeoSyncStatusRules.aggregate([save], [remote(key, [1, 2, 3], compress: true)]),
        GameSyncStatus.upToDate, reason: key);
    }
  });

  test('missing or different checksums never become synced through equal size/date', () async {
    final save = await local('Game.srm', [1, 2]);
    for (final hash in ['', 'not-an-md5', md5.convert([3, 4]).toString()]) {
      expect(await NeoSyncStatusRules.compare(save, remote(save.relativePath, [1, 2], hash: hash)),
        GameSyncStatus.localOnly, reason: hash);
    }
    expect(await NeoSyncStatusRules.compare(save, remote(save.relativePath, [1, 2],
        hash: md5.convert([1, 2]).toString().toUpperCase())), GameSyncStatus.upToDate);
  });

  test('same timestamp does not hide local writes since last confirmed checksum', () async {
    final save = await local('Game.srm', [9, 9]);
    final cloud = remote(save.relativePath, [8, 8]);
    expect(await NeoSyncStatusRules.compare(save, cloud, readSyncState: (_) async => {
      'file_hash': md5.convert([1, 1]).toString(),
      'local_modified_at': modified.millisecondsSinceEpoch,
      'cloud_updated_at': modified.millisecondsSinceEpoch,
    }), GameSyncStatus.localOnly);
  });

  test('a vanished local copy needs a download and a directory is a real error', () async {
    final save = await local('Game.srm', [1]);
    final cloud = remote(save.relativePath, [1]);
    await File(save.filePath).delete();
    expect(await NeoSyncStatusRules.compare(save, cloud), GameSyncStatus.cloudOnly);
    await Directory(save.filePath).create();
    expect(await NeoSyncStatusRules.compare(save, cloud), GameSyncStatus.error);
  });

  test('distinct save roots or conflicting cloud versions cannot certify one object', () async {
    final first = await local('one.sav', [1], key: 'v2/saves/snes/retroarch/game/Game/Game.srm');
    final second = await local('two.sav', [1], key: first.relativePath);
    final cloud = remote(first.relativePath, [1]);
    expect(await NeoSyncStatusRules.aggregate([first, second], [cloud]), GameSyncStatus.error);
    expect(await NeoSyncStatusRules.aggregate([first], [cloud, remote(first.relativePath, [2])]),
      GameSyncStatus.error);
  });
}
