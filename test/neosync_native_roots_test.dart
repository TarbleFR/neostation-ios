import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/neosync/neo_sync_save_policy.dart';

void main() {
  test('iOS PSP savedata support survives the older disabled system catalog', () {
    for (final system in ['psp', 'pspminis']) {
      expect(NeoSyncSavePolicy.supportsSystem(system, false, isIOS: true), isTrue);
      expect(NeoSyncSavePolicy.supportsSystem(system, false, isIOS: false), isFalse);
    }
    expect(NeoSyncSavePolicy.supportsSystem('other', false, isIOS: true), isFalse);
  });

  late Directory root;
  setUp(() { root = Directory.systemTemp.createTempSync('neosync-roots-'); });
  tearDown(() { root.deleteSync(recursive: true); });

  File member(String relative) {
    final file = File('${root.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync([1, 2, 3]);
    return file;
  }

  String switchSave({String saveId = '0000000000000003', int type = 1,
      int format = 0, String stage = '0', int profile = 1}) {
    final save = '${root.path}/MeloNX/bis/user/save/$saveId';
    Directory('$save/$stage').createSync(recursive: true);
    final bytes = Uint8List(0x200);
    final data = ByteData.sublistView(bytes);
    data.setUint64(0, 0x01006A800016E000, Endian.little);
    bytes[8] = profile;
    data.setUint8(0x20, type);
    data.setUint32(0x54, format, Endian.little);
    File('$save/ExtraData$stage').writeAsBytesSync(bytes);
    File('$save/$stage/main').writeAsBytesSync([4, 5, 6]);
    return save;
  }

  test('configured RetroArch roots admit core data but never neighbouring ROMs', () {
    final saves = '${root.path}/custom-user-data';
    final file = member('custom-user-data/Flycast/card-data.bin');
    final source = NeoSyncSaveSource.resolve(filePath: file.path, rootPath: saves,
        family: NeoSyncSaveFamily.retroArchSaves);
    expect(source, isNotNull);
    const cloud = 'v2/saves/dc/retroarch.flycast/shared/card-data.bin';
    expect(NeoSyncSavePolicy.allowsUpload(file.path, cloud, source: source), isTrue);
    expect(source!.matches(file.path, cloud.replaceFirst('flycast', 'snes9x')), isFalse);
    expect(source.matches('${root.path}/games/card-data.bin', cloud), isFalse);
    for (final relative in ['../games/Game.sav', 'Flycast/game.chd',
      'Flycast/card.state.png', '.neosync-restore-recovery/Flycast/card.sav']) {
      expect(NeoSyncSaveSource.resolve(filePath: '$saves/$relative', rootPath: saves,
          family: NeoSyncSaveFamily.retroArchSaves), isNull, reason: relative);
    }
  });

  test('Flycast system VMUs exclude BIOS and emulated machine configuration', () {
    final nativeRoot = '${root.path}/system/dc';
    final file = member('system/dc/vmu_save_A1.bin');
    final source = NeoSyncSaveSource.resolve(filePath: file.path, rootPath: nativeRoot,
        family: NeoSyncSaveFamily.retroArchFlycastSystem)!;
    expect(source.matches(file.path,
        'v2/saves/dc/retroarch.flycast/shared/system/dc/vmu_save_A1.bin'), isTrue);
    for (final leaf in ['dc_boot.bin', 'dc_nvmem.bin', 'naomi.zip', 'other/vmu_save_A1.bin']) {
      expect(NeoSyncSaveSource.resolve(filePath: '$nativeRoot/$leaf', rootPath: nativeRoot,
          family: NeoSyncSaveFamily.retroArchFlycastSystem), isNull);
    }
  });

  test('PPSSPP DLC, textures and caches remain excluded inside RetroArch saves', () {
    for (final relative in ['PSP/GAME/ULES00151/data.bin',
      'PPSSPP/PSP/TEXTURES/ULES00151/texture.bin',
      'PPSSPP/PSP/SYSTEM/CACHE/compiled.dat', 'PPSSPP/PSP/flash0/font.bin']) {
      final file = member('saves/$relative');
      expect(NeoSyncSaveSource.resolve(filePath: file.path, rootPath: '${root.path}/saves',
          family: NeoSyncSaveFamily.retroArchSaves), isNull);
      expect(NeoSyncSavePolicy.classify('v2/saves/psp/retroarch.ppsspp/game/Game/$relative'),
          NeoSyncSaveKind.foreign);
    }
  });

  test('PSP and PS3 native bundles retain metadata with their game payload', () {
    for (final leaf in ['PARAM.SFO', 'ICON0.PNG', 'SYSDATA', 'folder/custom.dat']) {
      final psp = member('saves/PPSSPP/PSP/SAVEDATA/ULES00151DATA/$leaf');
      final source = NeoSyncSaveSource.resolve(filePath: psp.path,
          rootPath: '${root.path}/saves', family: NeoSyncSaveFamily.retroArchSaves);
      expect(source, isNotNull, reason: leaf);
      expect(source!.matches(psp.path,
          'v2/saves/psp/retroarch.ppsspp/game/Game/PSP/SAVEDATA/ULES00151DATA/$leaf'), isTrue);
      final ps3 = member('RPCS3/dev_hdd0/home/00000001/savedata/BLES00050-SAVE/$leaf');
      final ps3Source = NeoSyncSaveSource.resolve(filePath: ps3.path,
          rootPath: '${root.path}/RPCS3', family: NeoSyncSaveFamily.rpcs3);
      expect(ps3Source!.matches(ps3.path,
          'v2/saves/ps3/rpcs3/game/Game/00000001/BLES00050-SAVE/$leaf'), isTrue);
    }
    expect(NeoSyncSaveSource.resolve(
        filePath: '${root.path}/RPCS3/dev_hdd0/game/BLES00050/PARAM.SFO',
        rootPath: '${root.path}/RPCS3', family: NeoSyncSaveFamily.rpcs3), isNull);
  });

  test('ARMSX2 accepts complete folder cards and excludes state thumbnails', () {
    for (final leaf in ['_pcsx2_superblock', '_pcsx2_index', 'BASLUS-20000/icon.sys']) {
      final file = member('ARMSX2/memcards/Card1/$leaf');
      final source = NeoSyncSaveSource.resolve(filePath: file.path,
          rootPath: '${root.path}/ARMSX2', family: NeoSyncSaveFamily.armsx2);
      expect(source!.matches(file.path,
          'v2/saves/ps2/armsx2/shared/memcards/Card1/$leaf'), isTrue);
    }
    for (final relative in ['bios/scph.bin', 'memcards/image.png',
      'savestates/Game.p2s.png', 'memcards/Card1/game.iso']) {
      expect(NeoSyncSaveSource.resolve(filePath: '${root.path}/ARMSX2/$relative',
          rootPath: '${root.path}/ARMSX2', family: NeoSyncSaveFamily.armsx2), isNull);
    }
  });

  test('MeloNX reads the game identity from committed ExtraData, not SaveDataId', () {
    final save = switchSave();
    final linked = '${root.path}/MeloNX';
    final location = NeoSyncSavePolicy.melonxSaveLocation('$save/0/main', linked)!;
    expect(location.titleId, '01006A800016E000');
    expect(location.saveId, '0000000000000003');
    expect(location.payloadRoot, '$save/0');
    expect(location.cloudFilePath,
        'profiles/01000000000000000000000000000000/01006A800016E000/0000000000000003/main');
    final source = NeoSyncSaveSource.resolve(filePath: '$save/0/main',
        rootPath: linked, family: NeoSyncSaveFamily.melonx)!;
    expect(source.matches('$save/0/main',
        'v2/saves/switch/melonx/game/Smash/${location.cloudFilePath}'), isTrue);
    for (final bad in ['$save/ExtraData0', '$save/1/main', '$save/_/main',
      '$linked/bis/user/Contents/registered/game.nca', '$linked/DLC/Costume.nsp']) {
      expect(NeoSyncSavePolicy.melonxSaveLocation(bad, linked), isNull, reason: bad);
    }
    Directory('$save/_').createSync();
    expect(NeoSyncSavePolicy.melonxSaveLocation('$save/0/main', linked), isNull,
        reason: 'an unfinished commit must not be published');
  });

  test('MeloNX excludes system/cache data and supports verified nonjournal payload', () {
    for (final type in [0, 2, 4, 5, 6]) {
      final save = switchSave(saveId: '00000000000000${type.toString().padLeft(2, '0')}', type: type);
      expect(NeoSyncSavePolicy.melonxSaveLocation('$save/0/main', root.path), isNull);
    }
    final noJournal = switchSave(saveId: '0000000000000088', type: 3, format: 1,
        stage: '1', profile: 0);
    expect(NeoSyncSavePolicy.melonxSaveLocation('$noJournal/1/main', root.path), isNotNull);
    final missingCommit = switchSave(saveId: '0000000000000089', stage: '1');
    expect(NeoSyncSavePolicy.melonxSaveLocation('$missingCommit/1/main', root.path), isNull);
  });
}
