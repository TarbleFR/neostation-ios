import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/services/dolphin_neosync_store.dart';

void main() {
  const gc = DolphinSaveIdentity(system: 'gc', gameId: 'GMSE01', region: 'USA');
  const wii = DolphinSaveIdentity(system: 'wii', gameId: 'RMGE01', region: 'USA', titleId: '00010000524d4745');
  late Directory temporary;
  late DolphinNeoSyncStore source;
  late DolphinNeoSyncStore destination;

  Uint8List gci(String id, int marker) {
    final bytes = Uint8List(64 + 8192);
    bytes.setRange(0, 6, ascii.encode(id));
    bytes[0x39] = 1;
    bytes[64] = marker;
    return bytes;
  }

  Future<File> put(DolphinNeoSyncStore store, String name, List<int> bytes) async {
    final file = File(p.join(store.userDirectory.path, name));
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes, flush: true);
  }

  Future<List<int>> payload(DolphinSaveSnapshot snapshot) => snapshot.file.readAsBytes();

  Future<void> restore(DolphinSaveTarget target, List<int> bytes, {String? checksum}) =>
      destination.restore(target, bytes, checksum: checksum ?? md5.convert(bytes).toString());

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('dolphin-neosync');
    source = DolphinNeoSyncStore(Directory(p.join(temporary.path, 'source/User')), Directory(p.join(temporary.path, 'source/cache')));
    destination = DolphinNeoSyncStore(Directory(p.join(temporary.path, 'destination/User')), Directory(p.join(temporary.path, 'destination/cache')));
    await source.userDirectory.create(recursive: true);
    await destination.userDirectory.create(recursive: true);
  });
  tearDown(() async => temporary.delete(recursive: true));

  test('strict native identities reject filename guesses, other consoles and system titles', () {
    expect(gc.isValid, isTrue);
    expect(wii.isValid, isTrue);
    for (final identity in [
      const DolphinSaveIdentity(system: 'ps2', gameId: 'GMSE01', region: 'USA'),
      const DolphinSaveIdentity(system: 'gc', gameId: 'Mario.iso', region: 'USA'),
      const DolphinSaveIdentity(system: 'gc', gameId: 'GMSE01', region: 'UNKNOWN'),
      const DolphinSaveIdentity(system: 'wii', gameId: '', region: '', titleId: '0000000100000002'),
    ]) { expect(identity.isValid, isFalse); }
  });

  test('cloud keys separate console, native title, region and memory-card slot', () {
    final gcTargets = DolphinSaveTarget.forGame(gc);
    expect(gcTargets.first.cloudPath, 'v2/saves/gc/dolphinios/game/GMSE01/gci-USA-A.nsav');
    expect(gcTargets.last.cloudPath, 'v2/saves/gc/dolphinios/game/GMSE01/gci-USA-B.nsav');
    expect(DolphinSaveTarget.forGame(wii).single.cloudPath, 'v2/saves/wii/dolphinios/game/00010000524d4745/wii-data.nsav');
    expect(DolphinSaveTarget.raw('MemoryCardA.USA.251.raw')!.shared, isTrue);
    for (final target in [...gcTargets, ...DolphinSaveTarget.forGame(wii), DolphinSaveTarget.raw('MemoryCardB.EUR.raw')!]) {
      expect(DolphinSaveTarget.parse(target.cloudPath)?.relativeNativePath, target.relativeNativePath);
    }
  });

  test('malformed and unsupported cloud keys cannot resolve as a native save', () {
    for (final key in [
      'v2/saves/ps2/dolphinios/game/GMSE01/gci-USA-A.nsav',
      'v2/states/gc/dolphinios/game/GMSE01/gci-USA-A.nsav',
      'v2/saves/gc/retroarch.dolphin/game/GMSE01/gci-USA-A.nsav',
      'v2/saves/gc/dolphinios/game/GMSE01/../gci-USA-A.nsav',
      'v2/saves/gc/dolphinios/game/GMSE01/gci-USA-A.nsav/extra',
      'v2/saves/wii/dolphinios/game/0000000100000002/wii-data.nsav',
      'v2/saves/wii/dolphinios/game/00010000524d4745/keys.bin',
    ]) { expect(DolphinSaveTarget.parse(key), isNull, reason: key); }
    expect(DolphinSaveTarget.ownsCloudPath('v2/saves/gc/dolphinios/invalid'), isTrue);
    expect(DolphinSaveTarget.ownsCloudPath('v2/saves/ps2/armsx2/shared/card.ps2'), isFalse);
  });

  test('first sync with different data is a conflict; common history resolves one-sided changes', () {
    expect(dolphinSyncDecision(null, null, null), DolphinSyncDecision.empty);
    expect(dolphinSyncDecision('a', 'a', null), DolphinSyncDecision.equal);
    expect(dolphinSyncDecision('a', null, null), DolphinSyncDecision.upload);
    expect(dolphinSyncDecision(null, 'a', null), DolphinSyncDecision.download);
    expect(dolphinSyncDecision('a', 'b', null), DolphinSyncDecision.conflict);
    expect(dolphinSyncDecision('a', 'b', 'a'), DolphinSyncDecision.download);
    expect(dolphinSyncDecision('a', 'b', 'b'), DolphinSyncDecision.upload);
    expect(dolphinSyncDecision('a', 'b', 'c'), DolphinSyncDecision.conflict);
  });

  test('GCI snapshot uses header ownership and ignores unrelated files and IPL', () async {
    final target = DolphinSaveTarget.forGame(gc).first;
    await put(source, '${target.relativeNativePath}/unrelated-name.gci', gci('GMSE01', 10));
    await put(source, '${target.relativeNativePath}/GMSE01-not-this-game.gci', gci('GZLE01', 20));
    await put(source, 'GC/USA/ipl.bin', [1, 2, 3]);
    await put(source, 'Config/Dolphin.ini', [4]);
    await put(source, 'StateSaves/GMSE01.s01', [5]);
    final snapshot = (await source.snapshot(target))!;
    final doc = jsonDecode(utf8.decode(await payload(snapshot))) as Map;
    expect((doc['files'] as List).length, 1);
    expect(doc['files'][0]['path'], 'unrelated-name.gci');
    expect(doc.toString(), isNot(contains('ipl.bin')));
  });

  test('GCI restore preserves other games, replaces all files of this title and keeps old snapshot', () async {
    final target = DolphinSaveTarget.forGame(gc).first;
    await put(source, '${target.relativeNativePath}/save.gci', gci('GMSE01', 1));
    await put(destination, '${target.relativeNativePath}/old-name.gci', gci('GMSE01', 2));
    final other = await put(destination, '${target.relativeNativePath}/other.gci', gci('GZLE01', 3));
    final snapshot = (await source.snapshot(target))!;
    await restore(target, await payload(snapshot));
    expect((await File(p.join(destination.userDirectory.path, target.relativeNativePath, 'save.gci')).readAsBytes())[64], 1);
    expect((await other.readAsBytes())[64], 3);
    expect(await File(p.join(destination.userDirectory.path, target.relativeNativePath, 'old-name.gci')).exists(), isFalse);
    expect(await File(p.join(destination.userDirectory.path, '${target.relativeNativePath}.previous', 'old-name.gci')).exists(), isTrue);
    expect((await destination.snapshot(target))!.checksum, snapshot.checksum);
  });

  test('GCI filename collision with a different title rejects the entire restore', () async {
    final target = DolphinSaveTarget.forGame(gc).first;
    await put(source, '${target.relativeNativePath}/same-name.gci', gci('GMSE01', 1));
    final other = await put(destination, '${target.relativeNativePath}/same-name.gci', gci('GZLE01', 3));
    final snapshot = (await source.snapshot(target))!;
    await expectLater(restore(target, await payload(snapshot)), throwsFormatException);
    expect((await other.readAsBytes())[64], 3);
  });

  test('Wii restores a complete title data tree but not NAND contents or adjacent titles', () async {
    final target = DolphinSaveTarget.forGame(wii).single;
    await put(source, '${target.relativeNativePath}/banner.bin', [1, 2]);
    await put(source, '${target.relativeNativePath}/folder/save.dat', [3, 4]);
    await Directory(p.join(source.userDirectory.path, target.relativeNativePath, 'empty')).create();
    await put(source, 'Wii/keys.bin', [99]);
    await put(source, 'Wii/title/00010000524d4745/content/firmware.app', [98]);
    await put(destination, '${target.relativeNativePath}/old.bin', [7]);
    final neighbor = await put(destination, 'Wii/title/00010000/524d4750/data/save.dat', [8]);
    final system = await put(destination, 'Wii/title/00000001/00000002/content/menu.app', [9]);
    final snapshot = (await source.snapshot(target))!;
    await restore(target, await payload(snapshot));
    expect(await File(p.join(destination.userDirectory.path, target.relativeNativePath, 'folder/save.dat')).readAsBytes(), [3, 4]);
    expect(await Directory(p.join(destination.userDirectory.path, target.relativeNativePath, 'empty')).exists(), isTrue);
    expect(await File(p.join(destination.userDirectory.path, target.relativeNativePath, 'old.bin')).exists(), isFalse);
    expect(await File(p.join(destination.userDirectory.path, '${target.relativeNativePath}.previous/old.bin')).readAsBytes(), [7]);
    expect(await neighbor.readAsBytes(), [8]);
    expect(await system.readAsBytes(), [9]);
    expect(await File(p.join(destination.userDirectory.path, 'Wii/keys.bin')).exists(), isFalse);
    expect((await destination.snapshot(target))!.checksum, snapshot.checksum);
  });

  test('identical data has an identical cloud digest on another device and different modification date', () async {
    final target = DolphinSaveTarget.forGame(wii).single;
    await put(source, '${target.relativeNativePath}/save.bin', [1, 4, 9]);
    final file = await put(destination, '${target.relativeNativePath}/save.bin', [1, 4, 9]);
    await file.setLastModified(DateTime(2000));
    expect((await source.snapshot(target))!.checksum, (await destination.snapshot(target))!.checksum);
  });

  test('raw cards are shared, preserve their original size and keep a previous local copy', () async {
    final target = DolphinSaveTarget.raw('MemoryCardA.USA.raw')!;
    await put(source, target.relativeNativePath, Uint8List(524288)..[0] = 1);
    await put(destination, target.relativeNativePath, Uint8List(524288)..[0] = 2);
    final snapshot = (await source.snapshot(target))!;
    await restore(target, await payload(snapshot));
    expect((await File(p.join(destination.userDirectory.path, target.relativeNativePath)).readAsBytes())[0], 1);
    expect((await Directory(p.join(destination.userDirectory.path, 'GC')).list().toList()).length, 2);
    expect(target.cloudPath, contains('/shared/'));
  });

  test('raw cards with nonstandard size and truncated GCI files are refused', () async {
    final raw = DolphinSaveTarget.raw('MemoryCardA.USA.raw')!;
    await put(source, raw.relativeNativePath, [1, 2, 3]);
    await expectLater(source.snapshot(raw), throwsFormatException);
    final target = DolphinSaveTarget.forGame(gc).first;
    await put(source, '${target.relativeNativePath}/bad.gci', ascii.encode('GMSE01'));
    await expectLater(source.snapshot(target), throwsFormatException);
  });

  test('payload hash, key, version and per-file integrity are validated before changing a save', () async {
    final target = DolphinSaveTarget.forGame(wii).single;
    await put(source, '${target.relativeNativePath}/save.dat', [1]);
    final keep = await put(destination, '${target.relativeNativePath}/keep.dat', [9]);
    final snapshot = (await source.snapshot(target))!;
    final bytes = await payload(snapshot);
    await expectLater(restore(target, bytes, checksum: '00000000000000000000000000000000'), throwsFormatException);
    for (final change in <void Function(Map<String, dynamic>)>[
      (d) => d['version'] = 999,
      (d) => d['key'] = 'v2/saves/gc/dolphinios/shared/MemoryCardA.USA.raw.nsav',
      (d) => d['files'][0]['sha256'] = 'bad',
      (d) => d['files'] = [],
    ]) {
      final doc = Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
      change(doc);
      await expectLater(restore(target, utf8.encode(jsonEncode(doc))), throwsFormatException);
      expect(await keep.readAsBytes(), [9]);
    }
  });

  for (final name in ['../escape', '/escape', 'folder/../../escape', r'folder\escape', 'C:escape', 'folder//escape', 'folder/./escape']) {
    test('restore rejects unsafe manifest path $name', () async {
      final target = DolphinSaveTarget.forGame(wii).single;
      final doc = {'format': 'neostation.dolphin.save', 'version': 1, 'key': target.cloudPath,
        'directories': [], 'files': [{'path': name, 'data': base64Encode([1]), 'sha256': sha256.convert([1]).toString()}]};
      await expectLater(restore(target, utf8.encode(jsonEncode(doc))), throwsFormatException);
      expect(await Directory(p.join(destination.userDirectory.path, target.relativeNativePath)).exists(), isFalse);
    });
  }

  test('case-folded duplicates and file-directory conflicts are rejected', () async {
    final target = DolphinSaveTarget.forGame(wii).single;
    for (final names in [['save', 'SAVE'], ['save', 'save/child'], ['SAVE', 'save/child']]) {
      final doc = {'format': 'neostation.dolphin.save', 'version': 1, 'key': target.cloudPath,
        'directories': [], 'files': [for (final name in names) {'path': name, 'data': 'AQ==', 'sha256': sha256.convert([1]).toString()}]};
      await expectLater(restore(target, utf8.encode(jsonEncode(doc))), throwsFormatException);
    }
  });

  test('a symlink in a parent directory cannot redirect restore outside Dolphin', () async {
    final target = DolphinSaveTarget.forGame(gc).first;
    await put(source, '${target.relativeNativePath}/save.gci', gci('GMSE01', 1));
    final outside = await Directory(p.join(temporary.path, 'outside')).create();
    await Link(p.join(destination.userDirectory.path, 'GC')).create(outside.path);
    final snapshot = (await source.snapshot(target))!;
    await expectLater(restore(target, await payload(snapshot)), throwsFormatException);
    expect(await outside.list().isEmpty, isTrue);
  });

  test('snapshot refuses links instead of including another games or device secrets', () async {
    final target = DolphinSaveTarget.forGame(wii).single;
    await put(source, '${target.relativeNativePath}/save.dat', [1]);
    final outside = await File(p.join(temporary.path, 'pairing.plist')).writeAsString('not uploadable');
    await Link(p.join(source.userDirectory.path, target.relativeNativePath, 'escape')).create(outside.path);
    await expectLater(source.snapshot(target), throwsFormatException);
  });

  test('interrupted GC and Wii directory swap recovers the previous save at startup', () async {
    for (final target in [DolphinSaveTarget.forGame(gc).first, DolphinSaveTarget.forGame(wii).single]) {
      final root = p.join(destination.userDirectory.path, target.relativeNativePath);
      await put(destination, '${target.relativeNativePath}.previous/save.dat', [9]);
      await Directory('$root.incoming').create(recursive: true);
      await destination.recover();
      expect(await File(p.join(root, 'save.dat')).readAsBytes(), [9]);
      expect(await Directory('$root.incoming').exists(), isFalse);
    }
  });

  test('common-sync history is scoped to account and native cloud key', () async {
    final a = DolphinSaveTarget.forGame(gc).first;
    final b = DolphinSaveTarget.forGame(gc).last;
    const hash = '0123456789abcdef0123456789abcdef';
    await source.remember('account-one', a, hash);
    expect(await source.lastCommonHash('account-one', a), hash);
    expect(await source.lastCommonHash('account-two', a), isNull);
    expect(await source.lastCommonHash('account-one', b), isNull);
  });

  test('no native save is not a blank upload and does not create live save files', () async {
    for (final target in [...DolphinSaveTarget.forGame(gc), ...DolphinSaveTarget.forGame(wii)]) {
      expect(await source.snapshot(target), isNull);
      expect(await FileSystemEntity.type(p.join(source.userDirectory.path, target.relativeNativePath)), FileSystemEntityType.notFound);
    }
  });
}
