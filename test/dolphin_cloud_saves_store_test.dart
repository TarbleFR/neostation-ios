import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/services/dolphin_save_store.dart';

void main() {
  const gc = DolphinSaveIdentity(system: 'gc', gameId: 'GMSE01', region: 'USA');
  const wii = DolphinSaveIdentity(system: 'wii', gameId: 'RMGE01', region: 'USA', titleId: '00010000524d4745');
  late Directory temporary;
  late DolphinSaveStore source;
  late DolphinSaveStore destination;

  Uint8List gci(String id, int marker) {
    final bytes = Uint8List(64 + 8192);
    bytes.setRange(0, 6, ascii.encode(id));
    bytes[0x39] = 1;
    bytes[64] = marker;
    return bytes;
  }

  Uint8List state(String id, int marker, {int payloadSize = 128}) {
    const revision = 'fixture1';
    final bytes = Uint8List(48 + revision.length + payloadSize);
    bytes.setRange(0, id.length, ascii.encode(id));
    final data = ByteData.sublistView(bytes);
    data.setUint32(24, 0xBAADBABE + 175, Endian.little);
    data.setUint32(28, revision.length, Endian.little);
    bytes.setRange(32, 32 + revision.length, ascii.encode(revision));
    final extended = 32 + revision.length;
    data.setUint16(extended, 1, Endian.little);
    data.setUint64(extended + 8, payloadSize, Endian.little);
    bytes[extended + 16] = marker;
    return bytes;
  }

  Future<File> put(DolphinSaveStore store, String name, List<int> bytes) async {
    final file = File(p.join(store.userDirectory.path, name));
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes, flush: true);
  }

  Future<List<int>> payload(DolphinSaveSnapshot snapshot) => snapshot.file.readAsBytes();

  Future<void> restore(DolphinSaveTarget target, List<int> bytes, {String? checksum}) =>
      destination.restore(target, bytes, checksum: checksum ?? md5.convert(bytes).toString());

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('dolphin-cloud-saves');
    source = DolphinSaveStore(Directory(p.join(temporary.path, 'source/User')), Directory(p.join(temporary.path, 'source/cache')));
    destination = DolphinSaveStore(Directory(p.join(temporary.path, 'destination/User')), Directory(p.join(temporary.path, 'destination/cache')));
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

  test('savestate keys bind native console and identity to each of ten numbered slots', () {
    final gcStates = DolphinSaveTarget.statesForGame(gc);
    final wiiStates = DolphinSaveTarget.statesForGame(wii);
    expect(gcStates.length, 10);
    expect(wiiStates.length, 10);
    expect(gcStates.first.cloudPath, 'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s01.nsav');
    expect(wiiStates.last.cloudPath, 'v2/states/wii/dolphinios/game/00010000524d4745/RMGE01.s10.nsav');
    for (final target in [...gcStates, ...wiiStates]) {
      expect(target.isState, isTrue);
      expect(target.shared, isFalse);
      expect(target.relativeNativePath, 'StateSaves/${target.rawName}');
      expect(DolphinSaveTarget.parse(target.cloudPath)?.relativeNativePath, target.relativeNativePath);
      expect(target.matches(target.system == 'gc' ? gc : wii), isTrue);
      expect(target.matches(target.system == 'gc' ? wii : gc), isFalse);
    }
    for (final key in [
      'v2/saves/gc/dolphinios/game/GMSE01/GMSE01.s01.nsav',
      'v2/states/gc/dolphinios/game/GZLE01/GMSE01.s01.nsav',
      'v2/states/wii/dolphinios/game/00010000524d4750/RMGE01.s01.nsav',
      'v2/states/gc/dolphinios/shared/GMSE01.s01.nsav',
      'v2/states/gc/retroarch.dolphin/game/GMSE01/GMSE01.s01.nsav',
      for (final name in ['GMSE01.s00', 'GMSE01.s11', 'GMSE01.s1', 'GMSE01.s001',
        'GMSE01.s01.tmp', 'GMSE01.s01.dtm', 'lastState.sav', '../GMSE01.s01'])
        'v2/states/gc/dolphinios/game/GMSE01/$name.nsav',
    ]) { expect(DolphinSaveTarget.parse(key), isNull, reason: key); }
  });

  test('four-character Wii channel state IDs must match the native title bytes', () {
    const channel = DolphinSaveIdentity(system: 'wii', gameId: 'HABA', region: 'USA', titleId: '0001000148414241');
    final targets = DolphinSaveTarget.statesForGame(channel);
    expect(targets.length, 10);
    expect(targets.first.relativeNativePath, 'StateSaves/HABA.s01');
    expect(DolphinSaveTarget.parse(targets.first.cloudPath)?.matches(channel), isTrue);
    const mismatched = DolphinSaveIdentity(system: 'wii', gameId: 'HABB', region: 'USA', titleId: '0001000148414241');
    expect(DolphinSaveTarget.statesForGame(mismatched), isEmpty);
  });

  test('native scan includes only this games exact state slots, excluding temp undo and backups', () async {
    final target = DolphinSaveTarget.statesForGame(gc).first;
    await put(source, target.relativeNativePath, state('GMSE01', 1));
    for (final name in ['GMSE01.s11', 'GMSE01.s00', 'GMSE01.s01.tmp',
      'GMSE01.s01.dtm', 'GMSE01.s01.neostation-previous-1', 'GMSE01.s01.incoming-1',
      'lastState.sav', 'GZLE01.s01', 'RMGE01.s01']) {
      await put(source, 'StateSaves/$name', state('GMSE01', 99));
    }
    final snapshots = <DolphinSaveSnapshot>[];
    for (final candidate in await source.targetsForGame(gc)) {
      final snapshot = await source.snapshot(candidate);
      if (snapshot != null) snapshots.add(snapshot);
    }
    expect(snapshots.map((snapshot) => snapshot.target.cloudPath), [target.cloudPath]);
  });

  for (final game in [gc, wii,
    const DolphinSaveIdentity(system: 'wii', gameId: 'HABA', region: 'USA', titleId: '0001000148414241')]) {
    test('${game.gameId} states round-trip exactly, preserve other slots and keep previous bytes', () async {
      final targets = DolphinSaveTarget.statesForGame(game);
      final target = targets.first;
      final content = state(game.gameId, 1);
      final previous = state(game.gameId, 2);
      await put(source, target.relativeNativePath, content);
      await put(destination, target.relativeNativePath, previous);
      final otherSlot = await put(destination, targets.last.relativeNativePath, state(game.gameId, 3));
      final neighbor = await put(destination, 'StateSaves/OTHER1.s01', [77]);
      final snapshot = (await source.snapshot(target))!;
      await restore(target, await payload(snapshot));
      expect(await File(p.join(destination.userDirectory.path, target.relativeNativePath)).readAsBytes(), content);
      expect(await otherSlot.readAsBytes(), state(game.gameId, 3));
      expect(await neighbor.readAsBytes(), [77]);
      final backups = await Directory(p.join(destination.userDirectory.path, 'StateSaves')).list()
          .where((file) => p.basename(file.path).startsWith('${target.rawName}.neostation-previous-')).toList();
      expect(backups.length, 1);
      expect(await File(backups.single.path).readAsBytes(), previous);
      expect((await destination.snapshot(target))!.checksum, snapshot.checksum);
      expect(snapshot.size, lessThan(content.length + 4096));
    });
  }

  test('Wii state larger than the ordinary-save limit survives an exact binary round trip', () async {
    final target = DolphinSaveTarget.statesForGame(wii).first;
    final bytes = state(wii.gameId, 8, payloadSize: 41 * 1024 * 1024);
    bytes[bytes.length - 1] = 9;
    await put(source, target.relativeNativePath, bytes);
    final snapshot = (await source.snapshot(target))!;
    expect(snapshot.size, greaterThan(DolphinSaveStore.maxNativeBytes));
    expect(snapshot.size, lessThan(bytes.length + 4096));
    await restore(target, await payload(snapshot));
    final restored = File(p.join(destination.userDirectory.path, target.relativeNativePath));
    expect(await restored.length(), bytes.length);
    expect(await sha256.bind(restored.openRead()).single, sha256.convert(bytes));
  });

  test('native LZ4-compressed Wii checkpoints retain their exact compressed bytes', () async {
    final target = DolphinSaveTarget.statesForGame(wii).last;
    final bytes = state(wii.gameId, 0, payloadSize: 6);
    final data = ByteData.sublistView(bytes);
    data.setUint16(42, 1, Endian.little); // LZ4 in the extended header.
    data.setUint64(48, 1, Endian.little); // One uncompressed byte.
    data.setUint32(56, 2, Endian.little); // Two-byte compressed block.
    bytes[60] = 0x10; // One literal.
    bytes[61] = 0x42;
    await put(source, target.relativeNativePath, bytes);
    final snapshot = (await source.snapshot(target))!;
    await restore(target, await payload(snapshot));
    expect(await File(p.join(destination.userDirectory.path, target.relativeNativePath)).readAsBytes(), bytes);
  });

  test('oversized and malformed native state headers are rejected before upload', () async {
    final target = DolphinSaveTarget.statesForGame(gc).first;
    for (final corrupt in <void Function(ByteData)>[
      (header) => header.setUint32(8, 12, Endian.little), // Legacy LZO.
      (header) => header.setUint32(24, 0, Endian.little),
      (header) => header.setUint32(28, 2048, Endian.little),
      (header) => header.setUint16(40, 99, Endian.little),
      (header) => header.setUint16(42, 99, Endian.little),
      (header) => header.setUint64(48, DolphinSaveStore.maxStateNativeBytes + 1, Endian.little),
    ]) {
      final bytes = state(gc.gameId, 1);
      corrupt(ByteData.sublistView(bytes));
      await put(source, target.relativeNativePath, bytes);
      await expectLater(source.snapshot(target), throwsFormatException);
    }
    final file = await File(p.join(source.userDirectory.path, target.relativeNativePath)).open(mode: FileMode.write);
    try { await file.truncate(DolphinSaveStore.maxStateNativeBytes + 1); }
    finally { await file.close(); }
    await expectLater(source.snapshot(target), throwsFormatException);
  });

  test('state corruption, slot substitution and wrong-game headers never replace a live slot', () async {
    final target = DolphinSaveTarget.statesForGame(gc).first;
    final second = DolphinSaveTarget.statesForGame(gc)[1];
    final keep = await put(destination, second.relativeNativePath, state(gc.gameId, 9));
    await put(source, target.relativeNativePath, state(gc.gameId, 1));
    final snapshot = (await source.snapshot(target))!;
    await expectLater(restore(second, await payload(snapshot)), throwsFormatException);
    expect(await keep.readAsBytes(), state(gc.gameId, 9));
    final corrupted = Uint8List.fromList(await payload(snapshot));
    corrupted[corrupted.length - 1] ^= 0xff;
    await expectLater(restore(target, corrupted), throwsFormatException);
    expect(await File(p.join(destination.userDirectory.path, target.relativeNativePath)).exists(), isFalse);
    await put(source, target.relativeNativePath, state('GZLE01', 2));
    await expectLater(source.snapshot(target), throwsFormatException);
    await put(source, target.relativeNativePath, [1, 2, 3]);
    await expectLater(source.snapshot(target), throwsFormatException);
  });

  test('state restore rejects a symlinked StateSaves directory before any live write', () async {
    final target = DolphinSaveTarget.statesForGame(gc).first;
    await put(source, target.relativeNativePath, state(gc.gameId, 1));
    final snapshot = (await source.snapshot(target))!;
    final outside = await Directory(p.join(temporary.path, 'outside-states')).create();
    await Link(p.join(destination.userDirectory.path, 'StateSaves')).create(outside.path);
    await expectLater(restore(target, await payload(snapshot)), throwsFormatException);
    expect(await outside.list().isEmpty, isTrue);
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
