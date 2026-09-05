import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/neo_sync_save_units.dart';

NeoSyncFile cloud(String id, String source, {String title = '',
    String hash = '0123456789abcdef0123456789abcdef', bool split = false}) =>
  NeoSyncFile.fromJson({
    'id': id, 'file_name': split ? source.split('/').last : source,
    'file_path': '/account/$source', 'game_name': title,
    'file_hash': hash, 'file_size': 100,
    'uploaded_at': '2026-09-05T12:00:00Z',
  });

LocalSaveFile local(String key, {bool synced = true}) => LocalSaveFile(
  filePath: '/native/${key.split('/').last}', fileName: key.split('/').last,
  fileSize: 100, lastModified: DateTime.utc(2026, 9, 5), gameName: 'Game',
  isSynced: synced, relativePath: key,
);

void main() {
  const ps3 = 'v2/saves/ps3/rpcs3/game/Été à Hyrule/00000001/BLES00050-SAVE';
  const nx = 'v2/saves/switch/melonx/game/Super Smash Bros Ultimate';
  const profile = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const title = '01006A800016E000';

  test('fifteen PS3 native members make one action without losing any member', () {
    final paths = ['PARAM.SFO', 'PARAM.PFD', 'ICON0.PNG', 'PIC1.PNG',
      'SYSDATA', 'PLAYDATA', 'Progression été.bin',
      for (var i = 0; i < 8; i++) 'slots/slot$i'];
    final files = [for (var i = 0; i < paths.length; i++)
      cloud('$i', '$ps3/${paths[i]}', title: paths[i], split: i.isEven)];
    final original = files.map((file) => file.toJson()).toList();
    final units = NeoSyncSaveUnits.cloud(files);
    expect(units, hasLength(1));
    expect(units.single.displayName, 'Été à Hyrule');
    expect(units.single.members, orderedEquals(files));
    expect(units.single.totalBytes, 1500);
    expect(units.single.hasConflictingMembers, isFalse);
    expect(files.map((file) => file.toJson()).toList(), original);
    expect(NeoSyncSaveUnits.describe('$ps3/Progression été.bin').nativePath,
      'dev_hdd0/home/00000001/savedata/BLES00050-SAVE/Progression été.bin');
  });

  test('PS3 profile and save slots never merge even when game labels match', () {
    final files = [
      cloud('one', '$ps3/PARAM.SFO', title: 'Same game'),
      cloud('two', '$ps3/PLAYDATA', title: 'different metadata'),
      cloud('profile2', '$ps3/PARAM.SFO'.replaceFirst('00000001', '00000002'), title: 'Same game'),
      cloud('slot2', '$ps3/PARAM.SFO'.replaceFirst('BLES00050-SAVE', 'BLES00050-SAVE2'), title: 'Same game'),
    ];
    final units = NeoSyncSaveUnits.cloud(files);
    expect(units, hasLength(3));
    expect(units.map((unit) => unit.members.length), containsAll([2, 1, 1]));
    expect(units.map((unit) => unit.key).toSet(), hasLength(3));
  });

  test('duplicate cloud objects remain visible to whole-save conflict checks', () {
    final files = [cloud('a', '$ps3/PLAYDATA'),
      cloud('b', '$ps3/PLAYDATA', hash: 'ffffffffffffffffffffffffffffffff')];
    final unit = NeoSyncSaveUnits.cloud(files).single;
    expect(unit.members.map((file) => file.id), ['a', 'b']);
    expect(unit.hasConflictingMembers, isTrue);
    expect(NeoSyncSaveUnits.cloud([files.first, cloud('copy', '$ps3/PLAYDATA')])
      .single.members, hasLength(2));
  });

  test('MeloNX uses profile, title and SaveDataId rather than game label', () {
    final root = '$nx/profiles/$profile/$title/8000000000000001';
    final files = [
      cloud('main', '$root/main', title: 'Wrong server metadata'),
      cloud('settings', '$root/slot/config.json'),
      cloud('profile2', '$root/main'.replaceFirst(profile, 'b' * 32)),
      cloud('save2', '$root/main'.replaceFirst('8000000000000001', '8000000000000002')),
    ];
    final units = NeoSyncSaveUnits.cloud(files);
    expect(units, hasLength(3));
    final unit = units.singleWhere((unit) => unit.members.length == 2);
    expect(unit.displayName, 'Super Smash Bros Ultimate');
    expect(NeoSyncSaveUnits.describe('$root/slot/config.json').nativePath,
      'bis/user/save/8000000000000001/0/slot/config.json');
    expect(NeoSyncSaveUnits.cloud([
      cloud('legacy1', '$nx/main', title: 'Metadata one'),
      cloud('legacy2', '$nx/backup', title: 'Metadata two'),
    ]), hasLength(1));
  });

  test('PSP native savedata metadata stays with its own save directory', () {
    for (final prefix in ['PSP/SAVEDATA/', 'SAVEDATA/', '']) {
      final root = 'v2/saves/psp/retroarch.ppsspp/game/Game/${prefix}ULES00151DATA';
      final members = [cloud('sfo', '$root/PARAM.SFO'), cloud('icon', '$root/ICON0.PNG'),
        cloud('data', '$root/DATA.BIN')];
      final units = NeoSyncSaveUnits.cloud(members);
      expect(units, hasLength(1), reason: prefix);
      expect(units.single.members, hasLength(3));
      expect(NeoSyncSaveUnits.describe('$root/DATA.BIN').nativePath,
        'PSP/SAVEDATA/ULES00151DATA/DATA.BIN');
    }
  });

  test('PS2 directory cards group native members but cards and states stay separate', () {
    const root = 'v2/saves/ps2/armsx2/shared/memcards';
    final files = [
      cloud('super', '$root/Folder Card/_pcsx2_superblock'),
      cloud('index', '$root/Folder Card/_pcsx2_index'),
      cloud('data', '$root/Folder Card/BASLUS-00000/data'),
      cloud('card1', '$root/Mcd001.ps2.neosync.gz'),
      cloud('card2', '$root/Mcd002.ps2.neosync.gz'),
      cloud('state1', 'v2/states/ps2/armsx2/shared/sstates/SLUS-00000.00.p2s'),
      cloud('state2', 'v2/states/ps2/armsx2/shared/sstates/SLUS-00000.01.p2s'),
    ];
    final units = NeoSyncSaveUnits.cloud(files);
    expect(units, hasLength(5));
    expect(units.singleWhere((unit) => unit.descriptor.isDirectory).members,
      hasLength(3));
    expect(units.where((unit) => unit.descriptor.isState), hasLength(2));
  });

  test('Dolphin keeps game names on states and the requested shared GC card label', () {
    final paths = [
      'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s01.nsav',
      'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s02.nsav',
      'v2/saves/gc/dolphinios/shared/MemoryCardA.USA.raw.nsav',
      'v2/saves/gc/dolphinios/shared/MemoryCardB.USA.raw.nsav',
    ];
    final units = NeoSyncSaveUnits.cloud([
      for (var i = 0; i < paths.length; i++) cloud('$i', paths[i], title: 'Super Mario Sunshine'),
    ]);
    expect(units, hasLength(4));
    expect(units.map((unit) => unit.displayName), containsAll([
      'Super Mario Sunshine · Slot 1', 'Super Mario Sunshine · Slot 2',
      'GC Memory cards', 'GC Memory cards',
    ]));
  });

  test('foreign objects and unresolved flat components are not presented as saves', () {
    final files = [cloud('dlc', '$nx/Costume.nsp'), cloud('icon', 'ICON0.PNG'),
      cloud('sfo', 'PARAM.SFO'), cloud('real', '$ps3/ICON0.PNG')];
    expect(NeoSyncSaveUnits.cloud(files).single.members.single.id, 'real');
    expect(files, hasLength(4), reason: 'Display filtering never deletes cloud objects');
  });

  test('one failed local member prevents a whole directory from appearing synchronized', () {
    final units = NeoSyncSaveUnits.local([
      local('$ps3/PARAM.SFO'), local('$ps3/PLAYDATA', synced: false),
      local('$ps3/ICON0.PNG'),
    ]);
    expect(units, hasLength(1));
    expect(units.single.members, hasLength(3));
    expect(units.single.isSynced, isFalse);
    expect(NeoSyncSaveUnits.local([
      local('$ps3/PARAM.SFO'), local('$ps3/PLAYDATA'), local('$ps3/ICON0.PNG'),
    ]).single.isSynced, isTrue);
  });

  test('RetroArch clock companions travel with exactly one matching battery save', () {
    const root = 'v2/saves/gbc/retroarch.gambatte/game/Pokémon Cristal';
    for (final extension in ['srm', 'sav']) {
      final files = [cloud('save', '$root/Pokémon Cristal.$extension'),
        cloud('clock', '$root/Pokémon Cristal.rtc'),
        cloud('other', '$root/Another.rtc'),
        cloud('state', 'v2/states/gbc/retroarch.gambatte/game/Pokémon Cristal/Pokémon Cristal.state')];
      final units = NeoSyncSaveUnits.cloud(files);
      expect(units, hasLength(3));
      final battery = units.singleWhere((unit) => unit.members.length == 2);
      expect(battery.members.map((file) => file.id), ['save', 'clock']);
      expect(battery.displayName, 'Pokémon Cristal');
      final locals = NeoSyncSaveUnits.local([
        local('$root/Pokémon Cristal.$extension'),
        local('$root/Pokémon Cristal.rtc', synced: false),
      ]);
      expect(locals, hasLength(1));
      expect(locals.single.key, battery.key);
      expect(locals.single.isSynced, isFalse);
    }
    expect(NeoSyncSaveUnits.cloud([
      cloud('srm', '$root/Pokémon Cristal.srm'),
      cloud('sav', '$root/Pokémon Cristal.sav'),
      cloud('clock', '$root/Pokémon Cristal.rtc'),
    ]), hasLength(3), reason: 'An ambiguous clock cannot select either save format');
    expect(NeoSyncSaveUnits.cloud([
      cloud('save', '$root/Pokémon Cristal.srm'),
      cloud('clock', '$root/Pokémon Cristal.rtc'.replaceFirst('gambatte', 'mgba')),
    ]), hasLength(2), reason: 'Two different cores never share a save unit');
  });
}
