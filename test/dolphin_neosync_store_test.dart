import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/dolphin_neosync_store.dart';
import 'package:path/path.dart' as p;

void main() {
  const gc = DolphinSaveIdentity(
    system: 'gc', gameId: 'GMSE01', region: 'USA');
  const wii = DolphinSaveIdentity(
    system: 'wii', gameId: 'RMGE01', region: 'USA',
    titleId: '00010000524d4745');
  late Directory temporary;
  late DolphinNeoSyncStore source;
  late DolphinNeoSyncStore destination;

  Future<File> put(
    DolphinNeoSyncStore store, String name, List<int> bytes) async {
    final file = File(p.join(store.userDirectory.path, name));
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes, flush: true);
  }

  Future<List<int>> payload(DolphinSaveSnapshot snapshot) =>
      snapshot.file.readAsBytes();

  Future<void> restore(
    DolphinSaveTarget target, List<int> bytes, {String? checksum}) =>
      destination.restore(target, bytes,
        checksum: checksum ?? md5.convert(bytes).toString());

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('dolphin-neosync-v1');
    source = DolphinNeoSyncStore(
      Directory(p.join(temporary.path, 'source/User')),
      Directory(p.join(temporary.path, 'source/cache')));
    destination = DolphinNeoSyncStore(
      Directory(p.join(temporary.path, 'destination/User')),
      Directory(p.join(temporary.path, 'destination/cache')));
    await source.userDirectory.create(recursive: true);
    await destination.userDirectory.create(recursive: true);
  });
  tearDown(() async => temporary.delete(recursive: true));

  test('native identities remain broader than the strict Wii V1 sync scope', () {
    expect(gc.isValid, isTrue);
    expect(wii.isValid, isTrue);
    const channel = DolphinSaveIdentity(
      system: 'wii', gameId: 'HABA', region: 'USA',
      titleId: '0001000148414241');
    const systemTitle = DolphinSaveIdentity(
      system: 'wii', gameId: 'RMGE01', region: 'USA',
      titleId: '00010004524d4745');
    expect(channel.isValid, isTrue);
    expect(systemTitle.isValid, isTrue);
    expect(DolphinSaveTarget.forGame(channel), isEmpty);
    expect(DolphinSaveTarget.forGame(systemTitle), isEmpty);

    const mismatched = DolphinSaveIdentity(
      system: 'wii', gameId: 'RMGP01', region: 'EUR',
      titleId: '00010000524d4745');
    expect(mismatched.isValid, isTrue);
    expect(DolphinSaveTarget.forGame(mismatched), isEmpty);
  });

  test('V1 targets are only regional raw cards and one Wii title data tree', () {
    final gcTargets = DolphinSaveTarget.forGame(gc);
    expect(gcTargets.map((target) => target.relativeNativePath), [
      'GC/MemoryCardA.USA.raw',
      'GC/MemoryCardB.USA.raw',
    ]);
    expect(gcTargets.map((target) => target.cloudPath), [
      'v2/saves/gc/dolphinios/shared/MemoryCardA.USA.raw.nsav',
      'v2/saves/gc/dolphinios/shared/MemoryCardB.USA.raw.nsav',
    ]);
    final wiiTarget = DolphinSaveTarget.forGame(wii).single;
    expect(wiiTarget.relativeNativePath,
      'Wii/title/00010000/524d4745/data');
    expect(wiiTarget.cloudPath,
      'v2/saves/wii/dolphinios/game/00010000524d4745/wii-data.nsav');
    expect(DolphinSaveTarget.statesForGame(gc), isEmpty);
    expect(DolphinSaveTarget.statesForGame(wii), isEmpty);
  });

  test('GCI, savestates, suffix cards and NAND keys are unsupported', () {
    for (final target in [
      ...DolphinSaveTarget.forGame(gc),
      ...DolphinSaveTarget.forGame(wii),
    ]) {
      expect(DolphinSaveTarget.parse(target.cloudPath)?.relativeNativePath,
        target.relativeNativePath);
    }
    for (final key in [
      'v2/saves/gc/dolphinios/game/GMSE01/gci-USA-A.nsav',
      'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s01.nsav',
      'v2/states/wii/dolphinios/game/00010000524d4745/RMGE01.s01.nsav',
      'v2/saves/gc/dolphinios/shared/MemoryCardA.USA.251.raw.nsav',
      'v2/saves/wii/dolphinios/game/00010001524d4745/wii-data.nsav',
      'v2/saves/wii/dolphinios/game/0000000100000002/wii-data.nsav',
      'v2/saves/wii/dolphinios/game/00010000524d4745/keys.bin',
      'v2/saves/gc/retroarch.dolphin/shared/MemoryCardA.USA.raw.nsav',
    ]) {
      expect(DolphinSaveTarget.parse(key), isNull, reason: key);
    }
    expect(DolphinSaveTarget.ownsCloudPath(
      'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s01.nsav'), isTrue);
  });

  test('native discovery yields RAW A/B only despite GCI and states', () async {
    await put(source, 'GC/USA/Card A/Mario.gci', [1]);
    await put(source, 'StateSaves/GMSE01.s01', [2]);
    final rawA = Uint8List(524288)..[0] = 3;
    final rawB = Uint8List(524288)..[0] = 4;
    await put(source, 'GC/MemoryCardA.USA.raw', rawA);
    await put(source, 'GC/MemoryCardB.USA.raw', rawB);
    final snapshots = <DolphinSaveSnapshot>[];
    for (final target in await source.targetsForGame(gc)) {
      final snapshot = await source.snapshot(target);
      if (snapshot != null) snapshots.add(snapshot);
    }
    expect(snapshots.map((snapshot) => snapshot.target.relativeNativePath), [
      'GC/MemoryCardA.USA.raw',
      'GC/MemoryCardB.USA.raw',
    ]);
  });

  test('numbered savestate slots stay dormant for every V1 game', () {
    expect(DolphinSaveTarget.statesForGame(gc), isEmpty);
    expect(DolphinSaveTarget.statesForGame(wii), isEmpty);
    for (final key in [
      'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s01.nsav',
      'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s10.nsav',
      'v2/states/wii/dolphinios/game/00010000524d4745/RMGE01.s01.nsav',
      'v2/states/wii/dolphinios/game/00010000524d4745/RMGE01.s10.nsav',
    ]) {
      expect(DolphinSaveTarget.parse(key), isNull, reason: key);
      expect(DolphinSaveTarget.ownsCloudPath(key), isTrue, reason: key);
    }
  });

  test('Wii channels keep a native identity but expose no NeoSync V1 target', () {
    const channel = DolphinSaveIdentity(
      system: 'wii',
      gameId: 'HABA',
      region: 'USA',
      titleId: '0001000148414241',
    );
    expect(channel.isValid, isTrue);
    expect(DolphinSaveTarget.forGame(channel), isEmpty);
    expect(DolphinSaveTarget.statesForGame(channel), isEmpty);
    expect(
      DolphinSaveTarget.parse(
        'v2/states/wii/dolphinios/game/0001000148414241/HABA.s01.nsav',
      ),
      isNull,
    );
  });

  test('state files alone never produce an active native snapshot', () async {
    final state = await put(source, 'StateSaves/GMSE01.s01', [1, 2, 3]);
    final targets = await source.targetsForGame(gc);
    expect(
      targets.map((target) => target.relativeNativePath),
      ['GC/MemoryCardA.USA.raw', 'GC/MemoryCardB.USA.raw'],
    );
    for (final target in targets) {
      expect(await source.snapshot(target), isNull);
    }
    expect(await state.readAsBytes(), [1, 2, 3]);
  });

  test('an oversized Wii state remains local and outside V1 payloads', () async {
    final state = File(p.join(
      source.userDirectory.path,
      'StateSaves',
      'RMGE01.s01',
    ));
    await state.parent.create(recursive: true);
    final handle = await state.open(mode: FileMode.write);
    try {
      await handle.truncate(DolphinNeoSyncStore.maxNativeBytes + 1);
    } finally {
      await handle.close();
    }
    for (final target in await source.targetsForGame(wii)) {
      expect(await source.snapshot(target), isNull);
    }
    expect(await state.length(), DolphinNeoSyncStore.maxNativeBytes + 1);
  });

  test('legacy compressed state bytes are never wrapped for upload', () async {
    final bytes = <int>[0x4e, 0x53, 0x44, 0x53, 0x56, 0x30, 0x30, 0x32];
    final state = await put(source, 'StateSaves/RMGE01.s10', bytes);
    expect(DolphinSaveTarget.statesForGame(wii), isEmpty);
    for (final target in await source.targetsForGame(wii)) {
      expect(await source.snapshot(target), isNull);
    }
    expect(await state.readAsBytes(), bytes);
  });

  test('malformed state slot and backup cloud names are all rejected', () {
    for (final name in [
      'GMSE01.s00',
      'GMSE01.s11',
      'GMSE01.s1',
      'GMSE01.s001',
      'GMSE01.s01.tmp',
      'GMSE01.s01.dtm',
      'GMSE01.s01.neosync-previous-1',
      'lastState.sav',
    ]) {
      final key = 'v2/states/gc/dolphinios/game/GMSE01/$name.nsav';
      expect(DolphinSaveTarget.parse(key), isNull, reason: key);
      expect(DolphinSaveTarget.ownsCloudPath(key), isTrue, reason: key);
    }
  });

  test('a StateSaves symlink remains outside active target discovery', () async {
    final outside = await File(p.join(temporary.path, 'outside-state'))
        .writeAsBytes([9, 8, 7]);
    final states = await Directory(
      p.join(source.userDirectory.path, 'StateSaves'),
    ).create(recursive: true);
    final link = Link(p.join(states.path, 'GMSE01.s01'));
    await link.create(outside.path);

    for (final target in await source.targetsForGame(gc)) {
      expect(await source.snapshot(target), isNull);
    }
    expect(await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link);
    expect(await outside.readAsBytes(), [9, 8, 7]);
  });

  test('GCI directory content stays local and produces no V1 snapshot', () async {
    final gci = await put(source, 'GC/USA/Card A/Mario.gci', [1, 2, 3]);
    for (final target in await source.targetsForGame(gc)) {
      expect(await source.snapshot(target), isNull);
    }
    expect(await gci.readAsBytes(), [1, 2, 3]);
  });

  test('all GCI cloud regions and slots stay reserved but unparseable', () {
    for (final region in ['USA', 'EUR', 'JAP']) {
      for (final slot in ['A', 'B']) {
        final key =
            'v2/saves/gc/dolphinios/game/GMSE01/gci-$region-$slot.nsav';
        expect(DolphinSaveTarget.parse(key), isNull, reason: key);
        expect(DolphinSaveTarget.ownsCloudPath(key), isTrue, reason: key);
      }
    }
  });

  test('a historical GCI key cannot select a live restore target', () async {
    const key = 'v2/saves/gc/dolphinios/game/GMSE01/gci-USA-A.nsav';
    final existing = await put(
      destination,
      'GC/USA/Card A/existing.gci',
      [4, 5, 6],
    );
    expect(DolphinSaveTarget.parse(key), isNull);
    expect(
      DolphinSaveTarget.forGame(gc)
          .map((target) => target.relativeNativePath),
      isNot(contains('GC/USA/Card A')),
    );
    expect(await existing.readAsBytes(), [4, 5, 6]);
  });

  test('truncated and colliding GCI files remain untouched outside V1', () async {
    final first = await put(
      source,
      'GC/USA/Card A/same-name.gci',
      [1],
    );
    final second = await put(
      source,
      'GC/USA/Card B/same-name.gci',
      [2],
    );
    for (final target in await source.targetsForGame(gc)) {
      expect(await source.snapshot(target), isNull);
    }
    expect(await first.readAsBytes(), [1]);
    expect(await second.readAsBytes(), [2]);
  });

  test('three-way comparison never overwrites independent changes', () {
    expect(dolphinSyncDecision(null, null, null), DolphinSyncDecision.empty);
    expect(dolphinSyncDecision('a', 'a', null), DolphinSyncDecision.equal);
    expect(dolphinSyncDecision('a', null, null), DolphinSyncDecision.upload);
    expect(dolphinSyncDecision(null, 'a', null), DolphinSyncDecision.download);
    expect(dolphinSyncDecision('a', 'b', null), DolphinSyncDecision.conflict);
    expect(dolphinSyncDecision('a', 'b', 'a'), DolphinSyncDecision.download);
    expect(dolphinSyncDecision('a', 'b', 'b'), DolphinSyncDecision.upload);
    expect(dolphinSyncDecision('a', 'b', 'c'), DolphinSyncDecision.conflict);
  });

  test('raw card round trip preserves bytes and a previous local copy', () async {
    final target = DolphinSaveTarget.forGame(gc).first;
    final incoming = Uint8List(524288)..[0] = 1;
    final previous = Uint8List(524288)..[0] = 2;
    await put(source, target.relativeNativePath, incoming);
    await put(destination, target.relativeNativePath, previous);
    final snapshot = (await source.snapshot(target))!;
    await restore(target, await payload(snapshot));
    expect(await File(p.join(destination.userDirectory.path,
      target.relativeNativePath)).readAsBytes(), incoming);
    final backups = await Directory(p.join(destination.userDirectory.path, 'GC'))
      .list()
      .where((entry) => p.basename(entry.path)
        .startsWith('${target.rawName}.neosync-previous-'))
      .toList();
    expect(backups, hasLength(1));
    expect(await File(backups.single.path).readAsBytes(), previous);
  });

  test('only exact standard raw-card names and sizes are accepted', () async {
    for (final name in [
      'MemoryCardA.USA.251.raw',
      'MemoryCardA.USA.raw.bak',
      'MemoryCardC.USA.raw',
      'MemoryCardA.PAL.raw',
    ]) {
      expect(DolphinSaveTarget.raw(name), isNull);
    }
    final target = DolphinSaveTarget.forGame(gc).first;
    await put(source, target.relativeNativePath, [1, 2, 3]);
    await expectLater(source.snapshot(target), throwsFormatException);
  });

  test('Wii restores only the matching title data tree atomically', () async {
    final target = DolphinSaveTarget.forGame(wii).single;
    await put(source, '${target.relativeNativePath}/banner.bin', [1, 2]);
    await put(source, '${target.relativeNativePath}/folder/save.dat', [3, 4]);
    await Directory(p.join(source.userDirectory.path,
      target.relativeNativePath, 'empty')).create();
    await put(source, 'Wii/keys.bin', [99]);
    await put(source,
      'Wii/title/00010000/524d4745/content/firmware.app', [98]);
    await put(destination, '${target.relativeNativePath}/old.bin', [7]);
    final neighbor = await put(destination,
      'Wii/title/00010000/524d4750/data/save.dat', [8]);
    final system = await put(destination,
      'Wii/title/00000001/00000002/content/menu.app', [9]);
    final snapshot = (await source.snapshot(target))!;
    await restore(target, await payload(snapshot));

    expect(await File(p.join(destination.userDirectory.path,
      target.relativeNativePath, 'folder/save.dat')).readAsBytes(), [3, 4]);
    expect(await File(p.join(destination.userDirectory.path,
      '${target.relativeNativePath}.previous/old.bin')).readAsBytes(), [7]);
    expect(await neighbor.readAsBytes(), [8]);
    expect(await system.readAsBytes(), [9]);
    expect(await File(p.join(destination.userDirectory.path,
      'Wii/keys.bin')).exists(), isFalse);
  });

  test('identical Wii data has an identical digest across dates', () async {
    final target = DolphinSaveTarget.forGame(wii).single;
    await put(source, '${target.relativeNativePath}/save.bin', [1, 4, 9]);
    final file = await put(destination,
      '${target.relativeNativePath}/save.bin', [1, 4, 9]);
    await file.setLastModified(DateTime(2000));
    expect((await source.snapshot(target))!.checksum,
      (await destination.snapshot(target))!.checksum);
  });

  test('manifest identity and hashes are checked before live writes', () async {
    final target = DolphinSaveTarget.forGame(wii).single;
    await put(source, '${target.relativeNativePath}/save.dat', [1]);
    final keep = await put(destination, '${target.relativeNativePath}/keep.dat', [9]);
    final snapshot = (await source.snapshot(target))!;
    final bytes = await payload(snapshot);
    await expectLater(restore(target, bytes,
      checksum: '00000000000000000000000000000000'),
      throwsFormatException);
    for (final change in <void Function(Map<String, dynamic>)>[
      (doc) => doc['version'] = 999,
      (doc) => doc['key'] =
        'v2/saves/wii/dolphinios/game/00010000524d4750/wii-data.nsav',
      (doc) => doc['files'][0]['sha256'] = 'bad',
      (doc) => doc['files'] = [],
    ]) {
      final doc = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(bytes)) as Map);
      change(doc);
      final changed = utf8.encode(jsonEncode(doc));
      await expectLater(restore(target, changed), throwsFormatException);
      expect(await keep.readAsBytes(), [9]);
    }
  });

  for (final name in [
    '../escape', '/escape', 'folder/../../escape', r'folder\escape',
    'C:escape', 'folder//escape', 'folder/./escape',
  ]) {
    test('restore rejects unsafe Wii path $name', () async {
      final target = DolphinSaveTarget.forGame(wii).single;
      final doc = {
        'format': 'neostation.dolphin.save', 'version': 1,
        'key': target.cloudPath, 'directories': [],
        'files': [{
          'path': name, 'data': 'AQ==',
          'sha256': sha256.convert([1]).toString(),
        }],
      };
      final bytes = utf8.encode(jsonEncode(doc));
      await expectLater(restore(target, bytes), throwsFormatException);
      expect(await Directory(p.join(destination.userDirectory.path,
        target.relativeNativePath)).exists(), isFalse);
    });
  }

  test('case-folded duplicates and file-directory conflicts are rejected', () async {
    final target = DolphinSaveTarget.forGame(wii).single;
    for (final names in [
      ['save', 'SAVE'],
      ['save', 'save/child'],
      ['SAVE', 'save/child'],
    ]) {
      final doc = {
        'format': 'neostation.dolphin.save',
        'version': 1,
        'key': target.cloudPath,
        'directories': [],
        'files': [
          for (final name in names)
            {
              'path': name,
              'data': 'AQ==',
              'sha256': sha256.convert([1]).toString(),
            },
        ],
      };
      final bytes = utf8.encode(jsonEncode(doc));
      await expectLater(restore(target, bytes), throwsFormatException);
    }
  });

  test('symlinked Wii data cannot redirect a snapshot', () async {
    final target = DolphinSaveTarget.forGame(wii).single;
    final outside = await Directory(p.join(temporary.path, 'outside')).create();
    await File(p.join(outside.path, 'save.dat')).writeAsBytes([1]);
    await Link(p.join(source.userDirectory.path, target.relativeNativePath))
      .create(outside.path, recursive: true);
    await expectLater(source.snapshot(target), throwsFormatException);
  });

  test('symlinked Wii parent cannot redirect a restore', () async {
    final target = DolphinSaveTarget.forGame(wii).single;
    await put(source, '${target.relativeNativePath}/save.dat', [1]);
    final snapshot = (await source.snapshot(target))!;
    final outside = await Directory(p.join(temporary.path, 'restore-outside'))
        .create();
    await Directory(p.join(destination.userDirectory.path, 'Wii', 'title'))
        .create(recursive: true);
    await Link(p.join(destination.userDirectory.path, 'Wii', 'title', '00010000'))
        .create(outside.path);
    await expectLater(
      restore(target, await payload(snapshot)),
      throwsFormatException,
    );
    expect(await outside.list().isEmpty, isTrue);
  });

  test('Wii transaction recovery ignores unsupported NAND namespaces', () async {
    final target = DolphinSaveTarget.forGame(wii).single;
    final root = p.join(destination.userDirectory.path,
      target.relativeNativePath);
    await put(destination,
      '${target.relativeNativePath}.previous/save.dat', [9]);
    await Directory('$root.incoming').create(recursive: true);
    final ignored = await put(destination,
      'Wii/title/00010001/524d4745/data.previous/channel.dat', [4]);
    await destination.recover();
    expect(await File(p.join(root, 'save.dat')).readAsBytes(), [9]);
    expect(await Directory('$root.incoming').exists(), isFalse);
    expect(await ignored.readAsBytes(), [4]);
  });

  test('history is scoped to account and exact regional card key', () async {
    final a = DolphinSaveTarget.forGame(gc).first;
    final b = DolphinSaveTarget.forGame(gc).last;
    const hash = '0123456789abcdef0123456789abcdef';
    await source.remember('account-one', a, hash);
    expect(await source.lastCommonHash('account-one', a), hash);
    expect(await source.lastCommonHash('account-two', a), isNull);
    expect(await source.lastCommonHash('account-one', b), isNull);
  });

  test('missing native data never creates a blank snapshot or live path', () async {
    for (final target in [
      ...DolphinSaveTarget.forGame(gc),
      ...DolphinSaveTarget.forGame(wii),
    ]) {
      expect(await source.snapshot(target), isNull);
      expect(
        await FileSystemEntity.type(
          p.join(source.userDirectory.path, target.relativeNativePath),
        ),
        FileSystemEntityType.notFound,
      );
    }
  });
}
