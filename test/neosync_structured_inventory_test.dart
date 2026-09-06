import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/neo_sync_save_units.dart';
import 'package:neostation/services/neosync/neo_sync_save_policy.dart';
import 'package:neostation/services/neosync/neo_sync_status_rules.dart';

// Shape taken from the official frontend contract change, not an assumption
// that file_name still contains a canonical v2 path:
// misobadev/neostation-frontend@11d3f7fdd127910e45a1b2759b96a02581ee6ae6.
NeoSyncFile structured(String system, String engine, String native, {
  String kind = 'save', String title = 'Readable game title',
  String id = 'save-1', String? filename, String? hash,
}) => NeoSyncFile.fromJson({
  'id': id, 'file_path': native, 'type': kind,
  'system_name': system, 'emulator': engine, 'game_name': title,
  'file_size': 4, 'file_hash': hash, 'game_hash': 'rom-hash',
  if (filename != null) 'file_name': filename,
});

void main() {
  test('structured Wii and GC native saves/states remain visible without file_name', () {
    final files = [
      structured('wii', 'dolphinios', '00010000524d4350/wii-data.nsav',
        title: 'Wii saves', id: 'wii'),
      structured('gc', 'dolphinios', 'GMSE01/gci-USA-A.nsav',
        title: 'GC Memory cards', id: 'gci'),
      structured('gc', 'dolphinios', 'MemoryCardA.USA.raw.nsav',
        kind: 'shared', title: 'GC Memory cards', id: 'raw'),
      structured('gc', 'dolphinios', 'GMSE01/GMSE01.s01.nsav',
        kind: 'state', title: 'Super Mario Sunshine', id: 'state'),
      structured('wii', 'dolphinios', '00010000524d4350/RMCP01.s02.nsav',
        kind: 'state', title: 'Mario Kart Wii', id: 'wii-state'),
    ];
    expect(files.map((file) => file.saveKind), everyElement(NeoSyncSaveKind.save));
    expect(NeoSyncSaveUnits.cloud(files), hasLength(5));
    expect(files[0].sourceSavePath,
      'v2/saves/wii/dolphinios/game/00010000524d4350/wii-data.nsav');
    expect(files[1].displayName, 'GC Memory cards');
    expect(files[2].displayName, 'GC Memory cards');
    expect(files[3].displayName, 'Super Mario Sunshine · Slot 1');
    expect(files[4].displayName, 'Mario Kart Wii · Slot 2');
    expect(files[0].fileName, isEmpty);
    expect(files[0].filePath, '00010000524d4350/wii-data.nsav');
  });

  test('RetroArch wire core directory maps to the same local basename key', () {
    final file = structured('n64', 'retroarch.mupen64plus-next',
      'Mupen64Plus-Next/Super Mario 64 (Europe).srm', title: 'Super Mario 64');
    expect(file.sourceSavePath,
      'v2/saves/n64/retroarch.mupen64plus-next/game/Super Mario 64 (Europe)/Super Mario 64 (Europe).srm');
    expect(file.saveKind, NeoSyncSaveKind.save);
    expect(NeoSyncSaveUnits.cloud([file]), hasLength(1));
    expect(file.filePath, 'Mupen64Plus-Next/Super Mario 64 (Europe).srm');
    expect(file.nativeRetroArchCoreFolder, 'Mupen64Plus-Next');
    final state = structured('n64', 'retroarch.mupen64plus-next',
      'Mupen64Plus-Next/Super Mario 64 (Europe).state1', kind: 'state');
    expect(state.sourceSavePath,
      'v2/states/n64/retroarch.mupen64plus-next/game/Super Mario 64 (Europe)/Super Mario 64 (Europe).state1');
    final automatic = structured('n64', 'retroarch.mupen64plus-next',
      'Mupen64Plus-Next/Mario.state.auto', kind: 'state');
    expect(automatic.sourceSavePath,
      'v2/states/n64/retroarch.mupen64plus-next/game/Mario.state/Mario.state.auto');
  });

  test('restored service inventory actually matches N64 bytes and becomes synchronized', () async {
    final directory = await Directory.systemTemp.createTemp('neosync-structured-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/Mario.srm').writeAsBytes([1, 2, 3, 4]);
    final remote = structured('n64', 'retroarch.mupen64plus-next',
      'Mupen64Plus-Next/Mario.srm', hash: md5.convert([1, 2, 3, 4]).toString());
    final local = LocalSaveFile(filePath: file.path, fileName: 'Mario.srm',
      fileSize: 4, lastModified: (await file.stat()).modified,
      gameName: 'Super Mario 64', isSynced: false,
      relativePath: 'v2/saves/n64/retroarch.mupen64plus-next/game/Mario/Mario.srm');
    expect(await NeoSyncStatusRules.aggregate([local], [remote]), GameSyncStatus.upToDate);
    await file.writeAsBytes([4, 3, 2, 1]);
    expect(await NeoSyncStatusRules.aggregate([local], [remote]), GameSyncStatus.localOnly);
  });

  test('PS3 PSP and MeloNX native components group by directory using structured metadata', () {
    final ps3 = [for (final name in ['PARAM.SFO', 'ICON0.PNG', 'PLAYDATA'])
      structured('ps3', 'rpcs3', '00000001/BLES00050/$name', id: 'ps3-$name')];
    final psp = [for (final name in ['PARAM.SFO', 'ICON0.PNG', 'SYSDATA'])
      structured('psp', 'retroarch.ppsspp', 'PPSSPP/PSP/SAVEDATA/ULES00151DATA/$name',
        id: 'psp-$name')];
    final melonx = [for (final name in ['main', 'config.json'])
      structured('switch', 'melonx',
        'profiles/11111111111111111111111111111111/01006A800016E000/0000000000000001/$name',
        id: 'switch-$name')];
    final units = NeoSyncSaveUnits.cloud([...ps3, ...psp, ...melonx]);
    expect(units, hasLength(3));
    expect(units.map((unit) => unit.members.length), unorderedEquals([3, 3, 2]));
    expect(ps3.first.exportSavePath, 'dev_hdd0/home/00000001/savedata/BLES00050/PARAM.SFO');
  });

  test('shared ARMSX2 cards and states retain native category and compression', () {
    final card = structured('ps2', 'armsx2', 'memcards/Mcd001.ps2.neosync.gz', kind: 'shared');
    final state = structured('ps2', 'armsx2', 'savestates/SLUS-20312.p2s', kind: 'state');
    expect(card.sourceSavePath, 'v2/saves/ps2/armsx2/shared/memcards/Mcd001.ps2.neosync.gz');
    expect(state.sourceSavePath, 'v2/states/ps2/armsx2/shared/savestates/SLUS-20312.p2s');
    expect(NeoSyncSaveUnits.cloud([card, state]), hasLength(2));
  });

  test('metadata does not bless DLC recordings or unrelated files as saves', () {
    final files = [
      structured('switch', 'melonx', 'DLC/Smash Costume.nsp', id: 'dlc'),
      structured('n64', 'retroarch.mupen64plus-next', 'Recordings/movie.mp4', id: 'video'),
      structured('n64', 'retroarch.mupen64plus-next', 'shaders/compile.log', id: 'log'),
    ];
    expect(files.map((file) => file.saveKind), everyElement(NeoSyncSaveKind.foreign));
    expect(NeoSyncSaveUnits.cloud(files), isEmpty);
  });

  test('missing Dolphin native identity and contradictory filenames stay unresolved', () {
    for (final file in [
      structured('wii', 'dolphinios', 'wii-data.nsav', title: 'Wii saves'),
      structured('gc', 'dolphinios', 'gci-USA-A.nsav', title: 'GC Memory cards'),
      structured('gc', 'dolphinios', 'GMSE01/gci-USA-A.nsav', filename: 'different.nsav'),
      structured('gc', 'dolphinios', 'GZLE01/GMSE01.s01.nsav', kind: 'state'),
      structured('gc', 'dolphinios', '../GMSE01/gci-USA-A.nsav'),
      structured('gc', 'dolphinios', 'Mario.sav'),
    ]) {
      expect(file.saveKind, NeoSyncSaveKind.unresolved);
      expect(file.dolphinTarget, isNull);
    }
  });

  test('historical custom folders need native save evidence', () {
    final card = structured('ps2', 'armsx2', 'memcards/Mcd001.ps2', kind: 'custom');
    final state = structured('ps2', 'armsx2', 'savestates/SLUS-20312.p2s', kind: 'custom');
    final unknown = structured('n64', 'retroarch.mupen64plus-next',
      'random/content.dat', kind: 'custom');
    expect(card.sourceSavePath, 'v2/saves/ps2/armsx2/shared/memcards/Mcd001.ps2');
    expect(state.sourceSavePath, 'v2/states/ps2/armsx2/shared/savestates/SLUS-20312.p2s');
    expect(unknown.saveKind, NeoSyncSaveKind.unresolved);
  });

  test('copies and JSON serialization preserve wire metadata and raw filenames', () {
    final original = structured('gc', 'dolphinios', 'GMSE01/GMSE01.s01.nsav',
      kind: 'state', title: 'Mario', id: 'server-id');
    for (final copy in [original, original.withDolphinDisplayTitle('Sunshine'),
      original.withVerifiedSourcePath(original.sourceSavePath),
      NeoSyncFile.fromJson(original.toJson())]) {
      expect(copy.id, 'server-id');
      expect(copy.fileName, isEmpty);
      expect(copy.filePath, original.filePath);
      expect(copy.systemName, 'gc');
      expect(copy.emulator, 'dolphinios');
      expect(copy.gameHash, 'rom-hash');
      expect(copy.type, 'state');
      expect(copy.sourceSavePath, original.sourceSavePath);
    }
  });

  test('fresh-device core folder recovery rejects unrelated paths or engines', () {
    const key = 'v2/saves/n64/retroarch.mupen64plus-next/game/Mario/Mario.srm';
    for (final native in ['Mupen64Plus-Next/Other.srm', '../Mupen64Plus-Next/Mario.srm',
      'Snes9x/Mario.srm', '/account/Mupen64Plus-Next/Mario.srm']) {
      final file = structured('n64', 'retroarch.mupen64plus-next', native, filename: key);
      expect(file.nativeRetroArchCoreFolder, isNull);
    }
    final flat = structured('n64', 'retroarch.mupen64plus-next', 'Mario.srm');
    expect(flat.nativeRetroArchCoreFolder, isNull);
    final exact = structured('n64', 'retroarch.mupen64plus-next',
      'Mupen64Plus-Next/Mario.srm', filename: key);
    expect(exact.nativeRetroArchCoreFolder, 'Mupen64Plus-Next');
  });
}
