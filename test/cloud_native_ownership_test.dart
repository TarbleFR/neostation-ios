import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/cloud_saves/native_save_ownership.dart';
import 'package:neostation/services/cloud_saves/save_source_registry.dart';
import 'package:neostation/services/config_service.dart';

void main() {
  late Directory temp;
  setUp(() async { temp = await Directory.systemTemp.createTemp('native-save-scope-'); });
  tearDown(() async { ConfigService.linkedArmsx2FolderPath = null; ConfigService.linkedMelonxSaveFolderPath = null; await temp.delete(recursive: true); });
  test('Hobbit and DBZ states cannot be confused by a recent timestamp', () {
    expect(NativeSaveOwnership.ps2StateMatches('SLUS-00002.01.p2s',
      romName: 'Le Hobbit.iso', gameName: 'Le Hobbit', titleId: 'SLUS-00001'), isFalse);
    expect(NativeSaveOwnership.ps2StateMatches('SLUS-00001.01.p2s',
      romName: 'Le Hobbit.iso', gameName: 'Le Hobbit', titleId: 'SLUS-00001'), isTrue);
    expect(NativeSaveOwnership.ps2StateMatches('Game 10.01.p2s', romName: 'Game 1.iso', gameName: 'Game 1'), isFalse);
  });
  test('PS2 native registry separates shared card and independently named state', () async {
    ConfigService.linkedArmsx2FolderPath = temp.path;
    await Directory('${temp.path}/memcards').create();
    await File('${temp.path}/memcards/Mcd001.ps2').writeAsBytes([1,2,3]);
    await Directory('${temp.path}/sstates').create();
    await File('${temp.path}/sstates/SLUS-00002.01.p2s').writeAsBytes([4,5,6]);
    await Directory('${temp.path}/iso').create();
    await File('${temp.path}/iso/private.iso').writeAsBytes([7,8]);
    final found = await SaveSourceRegistry().discover();
    final ps2 = found.units.where((u) => u.emulator == 'ARMSX2').toList();
    expect(ps2.length, 2);
    expect(ps2.singleWhere((u) => u.kind == 'MemoryCards').owner, 'Shared');
    expect(ps2.singleWhere((u) => u.kind == 'States').owner, 'SLUS-00002');
    expect(ps2.any((u) => u.source.endsWith('.iso')), isFalse);
  });
  test('MeloNX registry keeps all three native titles with their actual IDs', () async {
    ConfigService.linkedMelonxSaveFolderPath = temp.path;
    final ids = ['010015100b514000', '01006a800016e000', '010028600ebda000'];
    for (var i=0; i<ids.length; i++) {
      final root = Directory('${temp.path}/bis/user/save/${(i+1).toRadixString(16).padLeft(16,'0')}');
      await Directory('${root.path}/0').create(recursive: true);
      final extra = Uint8List(0x200);
      final bytes = ByteData.sublistView(extra);
      bytes.setUint64(0, int.parse(ids[i], radix:16), Endian.little);
      bytes.setUint8(0x20, 1);
      bytes.setUint64(8, 1, Endian.little);
      await File('${root.path}/ExtraData0').writeAsBytes(extra);
      await File('${root.path}/0/main').writeAsBytes([i+1]);
    }
    final found = await SaveSourceRegistry().discover();
    final nx = found.units.where((u) => u.emulator == 'MeloNX').toList();
    expect(nx.map((u) => u.owner.toLowerCase()).toSet(), ids.toSet());
    for (final u in nx) { expect(NativeSaveOwnership.switchTitleMatches(ids[0],u.owner),u.owner.toLowerCase()==ids[0]); }
  });
  test('new emulator adapter is independently registered without guessing game names', () async {
    final registry = SaveSourceRegistry(builtIns:false);
    registry.register('Future',() async => [NativeSaveUnit(key:'Future/Handheld/Shared',emulator:'Future',system:'Handheld',owner:'Shared',title:'User folder',kind:'Saves',source:temp.path)]);
    expect((await registry.discover()).units.single.emulator,'Future');
    expect(() => registry.register('Future',() async => []), throwsStateError);
  });
}
