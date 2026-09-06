import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/dolphin_neosync_store.dart';
import 'package:neostation/services/neosync/neo_sync_cloud_cleanup.dart';
import 'package:neostation/services/neosync/neo_sync_save_policy.dart';
import 'package:path/path.dart' as path;

void main() {
  const gc = DolphinSaveIdentity(system: 'gc', gameId: 'GMSP01', region: 'EUR');
  const wii = DolphinSaveIdentity(system: 'wii', gameId: 'RMGP01', region: 'EUR',
      titleId: '00010000524d4750');
  late Directory temporary;
  late DolphinNeoSyncStore store;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('neosync-origin-recovery');
    store = DolphinNeoSyncStore(Directory(path.join(temporary.path, 'User')),
        Directory(path.join(temporary.path, 'cache')));
    await store.userDirectory.create(recursive: true);
  });
  tearDown(() async => temporary.delete(recursive: true));

  Future<File> put(String relative, List<int> bytes) async {
    final file = File(path.join(store.userDirectory.path, relative));
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes, flush: true);
  }

  Future<DolphinSaveSnapshot> fixture(DolphinSaveIdentity game) async {
    final target = DolphinSaveTarget.forGame(game).first;
    if (game.system == 'gc') {
      final bytes = Uint8List(64 + 8192);
      bytes.setRange(0, 6, ascii.encode(game.gameId));
      bytes[0x39] = 1;
      bytes[64] = 17;
      await put('${target.relativeNativePath}/Mario.gci', bytes);
    } else {
      await put('${target.relativeNativePath}/save.bin', [1, 2, 3, 4]);
    }
    return (await store.snapshot(target))!;
  }

  NeoSyncFile historical(DolphinSaveSnapshot snapshot, {Map<String, dynamic>? override}) =>
      NeoSyncFile.fromJson({
        'id': 'remote-save',
        // The deployed API may omit file_name. Its old file_path contains only
        // a basename: fixed UI game_name labels cannot recover the native ID.
        'file_path': snapshot.target.objectName,
        'file_size': snapshot.size,
        'file_hash': snapshot.checksum,
        'type': 'save',
        'system_name': snapshot.target.system,
        'emulator': 'dolphinios',
        'game_name': snapshot.target.system == 'gc' ? 'GC Memory cards' : 'Wii saves',
        ...?override,
      });

  NeoSyncOriginIndex indexOf(DolphinSaveSnapshot snapshot) => NeoSyncOriginIndex()
    ..add(path: snapshot.target.cloudPath, leaf: snapshot.target.objectName,
        size: snapshot.size, checksum: snapshot.checksum);

  for (final game in [gc, wii]) {
    test('${game.system} old typed object recovers only from exact native snapshot bytes', () async {
      final snapshot = await fixture(game);
      final old = historical(snapshot);
      expect(old.fileName, isEmpty);
      expect(old.dolphinTarget, isNull);
      expect(old.saveKind, NeoSyncSaveKind.unresolved);
      expect(NeoSyncOriginIndex.isDolphinCandidate(old), isTrue);
      final recovered = indexOf(snapshot).resolve(old);
      expect(recovered.sourceSavePath, snapshot.target.cloudPath);
      expect(recovered.dolphinTarget!.identity, snapshot.target.identity);
      expect(recovered.saveKind, NeoSyncSaveKind.save);
      expect(recovered.toJson(), old.toJson());

      for (final wrong in [
        historical(snapshot, override: {'file_size': snapshot.size + 1}),
        historical(snapshot, override: {'file_hash': '0' * 32}),
        historical(snapshot, override: {'type': 'state'}),
        historical(snapshot, override: {'scope': 'shared'}),
        historical(snapshot, override: {'emulator': 'rpcs3'}),
        historical(snapshot, override: {'system_name': game.system == 'gc' ? 'wii' : 'gc'}),
      ]) {
        expect(indexOf(snapshot).resolve(wrong).verifiedSourcePath, isNull);
      }
    });
  }

  test('repeated same object is unique but multiple native owners stay unresolved', () async {
    final snapshot = await fixture(gc);
    final old = historical(snapshot);
    final index = indexOf(snapshot)
      ..add(path: snapshot.target.cloudPath, leaf: snapshot.target.objectName,
          size: snapshot.size, checksum: snapshot.checksum.toUpperCase());
    expect(index.resolve(old).verifiedSourcePath, snapshot.target.cloudPath);
    final other = DolphinSaveTarget.forGame(const DolphinSaveIdentity(
        system: 'gc', gameId: 'GZLP01', region: 'EUR')).first;
    index.add(path: other.cloudPath, leaf: snapshot.target.objectName,
        size: snapshot.size, checksum: snapshot.checksum);
    expect(index.resolve(old).verifiedSourcePath, isNull);
  });

  test('known native game identity and console cannot be reassigned by matching hash', () async {
    final snapshot = await fixture(gc);
    final old = historical(snapshot, override: {
      'file_name': snapshot.target.cloudPath.replaceFirst('GMSP01', 'Different game'),
      'file_path': snapshot.target.cloudPath.replaceFirst('GMSP01', 'Different game'),
    });
    expect(old.saveKind, NeoSyncSaveKind.unresolved);
    expect(indexOf(snapshot).resolve(old).verifiedSourcePath, isNull);
    final conflictingConsole = historical(snapshot, override: {
      'file_name': snapshot.target.cloudPath.replaceFirst('GMSP01', 'GC Memory cards'),
      'system_name': 'ps3',
    });
    expect(indexOf(snapshot).resolve(conflictingConsole).verifiedSourcePath, isNull);
  });

  test('fixed historical metadata labels can recover without overwriting wire fields', () async {
    final snapshot = await fixture(wii);
    final old = historical(snapshot, override: {
      'file_name': snapshot.target.cloudPath.replaceFirst(snapshot.target.identity, 'Wii saves'),
      'file_path': snapshot.target.cloudPath.replaceFirst(snapshot.target.identity, 'Wii saves'),
    });
    final recovered = indexOf(snapshot).resolve(old);
    expect(recovered.sourceSavePath, snapshot.target.cloudPath);
    expect(recovered.toJson(), old.toJson());
  });

  test('untyped .nsav and unrelated emulator metadata do not trigger Dolphin reads', () async {
    final snapshot = await fixture(wii);
    for (final old in [
      historical(snapshot, override: {'emulator': null, 'system_name': null, 'game_name': 'Unknown'}),
      historical(snapshot, override: {'emulator': 'melonx', 'system_name': 'switch'}),
      historical(snapshot, override: {'file_hash': null}),
      historical(snapshot, override: {'file_path': 'Game.nsp'}),
    ]) {
      expect(NeoSyncOriginIndex.isDolphinCandidate(old), isFalse);
    }
  });

  test('recovery precedes cleanup and preserves every unresolved native snapshot', () async {
    final snapshot = await fixture(wii);
    final recovered = indexOf(snapshot).resolve(historical(snapshot));
    final unresolved = historical(snapshot, override: {'id': 'unknown', 'file_hash': '0' * 32});
    final dlc = NeoSyncFile.fromJson({'id': 'dlc', 'file_name': 'Costume.nsp'});
    final deleted = <String>[];
    final result = await NeoSyncCloudCleanup.run(inventory: [recovered, unresolved, dlc],
        isCurrentAccount: () async => true,
        delete: (file) async { deleted.add(file.id); return true; });
    expect(deleted, ['dlc']);
    expect(result.remaining.map((file) => file.id), ['remote-save', 'unknown']);
    expect(result.unresolved, 1);
    expect(await File(path.join(store.userDirectory.path,
        '${snapshot.target.relativeNativePath}/save.bin')).readAsBytes(), [1, 2, 3, 4]);
  });
}
