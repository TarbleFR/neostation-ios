import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/neosync/neo_sync_save_policy.dart';
import 'package:neostation/services/neosync/neo_sync_cloud_cleanup.dart';

NeoSyncFile cloud(String id, String name, {String stored = '', String? hash,
    int size = 100}) => NeoSyncFile.fromJson({'id': id, 'file_name': name,
  'file_path': stored, 'file_hash': hash, 'file_size': size});

void main() {
  const ps3 = 'v2/saves/ps3/rpcs3/game/Bladestorm/00000001/BLES00050-SAVE';
  const nx = 'v2/saves/switch/melonx/game/Super Smash Bros Ultimate';
  const root = '/Documents/MeloNX';
  const native = '$root/bis/user/save/0000000000000000/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/01006A800016E000';

  test('MeloNX source requires the real save tree, including a narrowly linked root', () {
    for (final selected in [root, '$root/bis', '$root/bis/user/save', native]) {
      final location = NeoSyncSavePolicy.melonxLocation('$native/slot/main', selected);
      expect(location?.titleId, '01006A800016E000');
      expect(location?.internalPath, 'slot/main');
    }
    for (final bad in [
      '$root/games/01006A800016E000/save.dat',
      '$root/DLC/01006A800016E000/Costume.nsp',
      '$root/cache/01006A800016E000/main',
      '$root/bis/user/Contents/registered/01006A800016E000/save.dat',
      '$native/../save.dat', '$native/Costume.nsp', '$native/content.nca',
      '$root/bis/user/save/0000000000000000/01006A800016F001/main',
      '/Elsewhere/bis/user/save/0000000000000000/01006A800016E000/main',
    ]) {
      expect(NeoSyncSavePolicy.melonxLocation(bad, root), isNull, reason: bad);
    }
  });

  test('a claimed saves namespace cannot disguise an installed MeloNX DLC', () {
    for (final extension in ['nsp', 'NCA', 'xci', 'nsz', 'xcz', 'nro']) {
      final name = 'Super Smash Bros Ultimate [Costume].$extension';
      expect(NeoSyncSavePolicy.classify('$nx/$name'), NeoSyncSaveKind.foreign);
      expect(NeoSyncSavePolicy.allowsUpload('$root/DLC/$name', '$nx/main'), isFalse);
      expect(NeoSyncSavePolicy.allowsUpload('$native/$name', '$nx/$name'), isFalse);
    }
    expect(NeoSyncSavePolicy.allowsUpload('$native/main', '$nx/main'), isTrue);
    expect(NeoSyncSavePolicy.classify('$nx/dlc.json'), NeoSyncSaveKind.unresolved);
    expect(NeoSyncSavePolicy.classify('$nx/main'), NeoSyncSaveKind.save);
  });

  test('all original PS3/PSP savedata members survive, including game-specific formats', () {
    for (final leaf in ['PARAM.SFO', 'PARAM.PFD', 'ICON0.PNG', 'PIC1.PNG',
      'SYSDATA', 'PLAYDATA', 'custom/records.json', 'custom/texture.png']) {
      expect(NeoSyncSavePolicy.classify('$ps3/$leaf'), NeoSyncSaveKind.save);
      expect(NeoSyncSavePolicy.classify('/RPCS3/dev_hdd0/home/00000001/savedata/BLES00050-SAVE/$leaf'), NeoSyncSaveKind.save);
      expect(NeoSyncSavePolicy.classify('/PPSSPP/PSP/SAVEDATA/ULES00151DATA/$leaf'), NeoSyncSaveKind.save);
      expect(NeoSyncSavePolicy.rpcs3NativePath('$ps3/$leaf'),
        'dev_hdd0/home/00000001/savedata/BLES00050-SAVE/$leaf');
    }
    for (final leaf in ['PARAM.SFO', 'ICON0.PNG', 'SYSDATA', 'PLAYDATA', 'unusual.png']) {
      expect(NeoSyncSavePolicy.classify(leaf), NeoSyncSaveKind.unresolved);
      expect(NeoSyncSavePolicy.allowsUpload('/unknown/$leaf', leaf), isFalse);
    }
    expect(NeoSyncSavePolicy.classify('$ps3/.DS_Store'), NeoSyncSaveKind.foreign);
    expect(NeoSyncSavePolicy.classify('$ps3/../ICON0.PNG'), NeoSyncSaveKind.unresolved);
  });

  test('native saves, memory cards and actual savestates pass the common gate', () {
    for (final leaf in ['Mario.srm', 'Mario.sav', 'Mario.rtc', 'Mario.state',
      'Mario.state3', 'Mario.state.auto', 'Mario.state.1', 'Mario.s01',
      'MemoryCardA.USA.raw', 'Saturn.bkr', 'Saturn.smpc', 'vmu_save_A1.bin', 'card.mcr', 'card.ps2.neosync.gz', 'Mario.p2s', 'Mario.ppst']) {
      expect(NeoSyncSavePolicy.allowsUpload('/saves/$leaf', 'v2/saves/ps2/retroarch/game/Game/$leaf'), isTrue, reason: leaf);
    }
    for (final key in [
      'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s01.nsav',
      'v2/saves/gc/dolphinios/shared/MemoryCardA.USA.raw.nsav',
      'v2/saves/wii/dolphinios/game/00010000524d4350/wii-data.nsav',
    ]) {
      expect(NeoSyncSavePolicy.allowsUpload('/snapshot/save.nsav', key), isTrue);
    }
    for (final leaf in ['game.iso', 'settings.cfg', 'image.png', 'unknown.bin']) {
      expect(NeoSyncSavePolicy.allowsUpload('/folder/$leaf', 'v2/saves/nes/retroarch/game/Game/$leaf'), isFalse);
    }
  });

  test('split listing paths restore PS3 native directories and preserve API identity', () {
    final file = cloud('server-id', 'PARAM.SFO', stored: '/account/$ps3/PARAM.SFO');
    expect(file.sourceSavePath, '$ps3/PARAM.SFO');
    expect(file.exportSavePath, 'dev_hdd0/home/00000001/savedata/BLES00050-SAVE/PARAM.SFO');
    expect(file.ps3BundleKey, 'Bladestorm/00000001/BLES00050-SAVE');
    expect(file.id, 'server-id');
    expect(file.toJson()['file_name'], 'PARAM.SFO');
    final other = cloud('other', '$ps3/PARAM.SFO'.replaceFirst('00000001', '00000002'));
    expect(other.ps3BundleKey, isNot(file.ps3BundleKey));
    final dlc = cloud('dlc', 'Costume.nsp', stored: '/account/$nx/Costume.nsp');
    expect(NeoSyncSavePolicy.classify(dlc.sourceSavePath), NeoSyncSaveKind.foreign);
  });

  test('PS3 origin recovery requires exact size/hash and a unique native destination', () {
    const hash = '0123456789abcdef0123456789abcdef';
    final file = cloud('flat', 'ICON0.PNG', hash: hash);
    final index = NeoSyncOriginIndex();
    index.add(path: '$ps3/ICON0.PNG', leaf: 'ICON0.PNG', size: 100, checksum: hash.toUpperCase());
    final recovered = index.resolve(file);
    expect(recovered.sourceSavePath, '$ps3/ICON0.PNG');
    expect(recovered.toJson(), file.toJson());
    expect(index.resolve(cloud('wrong-size', 'ICON0.PNG', hash: hash, size: 99)).verifiedSourcePath, isNull);
    expect(index.resolve(cloud('wrong-hash', 'ICON0.PNG', hash: '0' * 32)).verifiedSourcePath, isNull);
    index.add(path: '$ps3/ICON0.PNG'.replaceFirst('00000001', '00000002'),
      leaf: 'ICON0.PNG', size: 100, checksum: hash);
    expect(index.resolve(file).verifiedSourcePath, isNull);
  });

  test('cleanup deletes only proven non-saves after investigation and acknowledgement', () async {
    final files = [cloud('save', '$ps3/ICON0.PNG'), cloud('dlc', '$nx/Costume.nsp'),
      cloud('unknown', 'ICON0.PNG'), cloud('failed', '$nx/Spirit.nsp'), cloud('local', 'Mario.srm')];
    final requests = <String>[];
    final result = await NeoSyncCloudCleanup.run(inventory: files,
      isCurrentAccount: () async => true,
      delete: (file) async { requests.add(file.id); return file.id != 'failed'; });
    expect(requests, ['dlc', 'failed']);
    expect(result.deletedIds, ['dlc']);
    expect(result.failedIds, ['failed']);
    expect(result.unresolved, 1);
    expect(result.remaining.map((f) => f.id), ['save', 'unknown', 'failed', 'local']);
  });

  test('cleanup stops on account switch and validates inventory before any deletion', () async {
    final files = [cloud('one', 'Costume.nsp'), cloud('two', 'Spirit.nsp')];
    var account = 'original';
    final removed = <String>[];
    await expectLater(NeoSyncCloudCleanup.run(inventory: files,
      isCurrentAccount: () async => account == 'original',
      delete: (file) async { removed.add(file.id); account = 'other'; return true; }),
      throwsStateError);
    expect(removed, ['one']);
    removed.clear();
    await expectLater(NeoSyncCloudCleanup.run(inventory: [files.first, files.first],
      isCurrentAccount: () async => true,
      delete: (file) async { removed.add(file.id); return true; }), throwsStateError);
    expect(removed, isEmpty);
  });
  test('unsafe raw cloud identifiers can never target a collection or parent route', () async {
    for (final id in ['', '.', '..', 'v1:', 'v1:.', 'v1:..', 'folder/file']) {
      var requests = 0;
      await expectLater(NeoSyncCloudCleanup.run(inventory: [cloud(id, 'Costume.nsp')],
        isCurrentAccount: () async => true,
        delete: (_) async { requests++; return true; }), throwsStateError);
      expect(requests, 0);
    }
  });

  test('Switch game metadata is investigated instead of purged by its name', () {
    const hash = '0123456789abcdef0123456789abcdef';
    for (final leaf in ['config.json', 'dlc.json', 'config/settings.dat', 'content/data.bin']) {
      final file = cloud('meta', '$nx/$leaf', hash: hash);
      expect(file.saveKind, NeoSyncSaveKind.unresolved);
      expect(NeoSyncSavePolicy.allowsUpload('$native/$leaf', '$nx/$leaf'), isTrue);
      final index = NeoSyncOriginIndex();
      index.add(path: '$nx/$leaf', leaf: leaf.split('/').last, size: 100, checksum: hash);
      expect(index.resolve(file).saveKind, NeoSyncSaveKind.save);
      expect(index.resolve(file).toJson(), file.toJson());
    }
    final otherGame = cloud('other-game', '$nx/config.json', hash: hash);
    final otherIndex = NeoSyncOriginIndex();
    otherIndex.add(path: 'v2/saves/switch/melonx/game/Other Game/config.json',
      leaf: 'config.json', size: 100, checksum: hash);
    expect(otherIndex.resolve(otherGame).verifiedSourcePath, isNull);
    expect(NeoSyncSavePolicy.classify('cache/Game.sav'), NeoSyncSaveKind.save);
  });

}
