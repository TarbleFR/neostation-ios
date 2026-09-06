import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/neo_sync_save_units.dart';
import 'package:neostation/services/neosync/neo_sync_game_scope.dart';
import 'package:neostation/services/neosync/neo_sync_save_policy.dart';

void main() {
  test('Hobbit session cannot collect unrelated DBZ state files', () {
    // Synthetic serial fixtures: no claim about a particular retail region.
    for (final state in ['sstates/SLUS-00002 (AABBCCDD).00.p2s',
      'savestates/Dragon Ball Z - Budokai 2.01.p2s']) {
      expect(NeoSyncGameScope.ps2StateMatches(state, romName: 'Le Hobbit.iso',
        gameName: 'Le Hobbit', titleId: 'SLUS-00001'), isFalse);
    }
    expect(NeoSyncGameScope.ps2StateMatches('sstates/SLUS-00001 (AABBCCDD).00.p2s',
      romName: 'Le Hobbit.iso', gameName: 'Le Hobbit', titleId: 'slus_000.01'), isTrue);
    expect(NeoSyncGameScope.ps2StateMatches('savestates/Le Hobbit.01.p2s',
      romName: 'Le Hobbit.iso', gameName: 'Le Hobbit'), isTrue);
  });

  test('an unknown or contradictory PS2 serial is not guessed from the title', () {
    for (final titleId in [null, 'SLES-00001', 'SLUS-00001 SLUS-00002']) {
      expect(NeoSyncGameScope.ps2StateMatches('Le Hobbit/SLUS-00001.00.p2s',
        romName: 'Le Hobbit.iso', gameName: 'Le Hobbit', titleId: titleId), isFalse);
    }
    expect(NeoSyncGameScope.ps2StateMatches('Game 10.01.p2s',
      romName: 'Game 1.iso', gameName: 'Game 1'), isFalse);
    expect(NeoSyncGameScope.ps2StateMatches('unknown.p2s',
      romName: '', gameName: ''), isFalse);
  });

  test('legacy wrongly labelled states remain separate and retain original remote metadata', () {
    const key = 'v2/states/ps2/armsx2/shared/sstates/SLUS-00002.00.p2s';
    final state = NeoSyncFile.fromJson({'id': 'existing-state', 'file_name': key,
      'game_name': 'Le Hobbit — Save State', 'file_size': 4});
    final card = NeoSyncFile.fromJson({'id': 'shared-card',
      'file_name': 'v2/saves/ps2/armsx2/shared/memcards/Mcd001.ps2.neosync.gz',
      'game_name': 'Le Hobbit — Memory Card', 'file_size': 4});
    final groups = NeoSyncSaveUnits.cloud([state, card]);
    expect(groups, hasLength(2));
    expect(groups.singleWhere((g) => g.descriptor.isState).displayName,
      'ARMSX2 · SLUS-00002.00.p2s');
    expect(groups.singleWhere((g) => !g.descriptor.isState).displayName, 'Mcd001.ps2');
    expect(state.toJson()['file_name'], key);
    expect(state.toJson()['game_name'], 'Le Hobbit — Save State');
    expect(state.id, 'existing-state');
  });

  test('three real native MeloNX directory fixtures select exactly one title', () async {
    final root = await Directory.systemTemp.createTemp('neosync207-melonx-');
    addTearDown(() => root.delete(recursive: true));
    const titles = ['010015100B514000', '01006A800016E000', '010028600EBDA000'];
    final locations = <MeloNXSaveLocation>[];
    for (var i = 0; i < titles.length; i++) {
      final save = Directory('${root.path}/bis/user/save/000000000000000${i + 1}');
      final committed = await Directory('${save.path}/0').create(recursive: true);
      final metadata = Uint8List(512);
      final data = ByteData.sublistView(metadata);
      data.setUint64(0, int.parse(titles[i], radix: 16), Endian.little);
      metadata[8] = 1; // Non-zero account profile.
      metadata[0x20] = 1;
      await File('${save.path}/ExtraData0').writeAsBytes(metadata);
      final payload = await File('${committed.path}/main').writeAsBytes([i, 1, 2]);
      final location = NeoSyncSavePolicy.melonxSaveLocation(payload.path, root.path);
      expect(location, isNotNull);
      locations.add(location!);
    }
    for (final selected in titles) {
      expect(locations.where((p) => NeoSyncGameScope.switchTitleMatches(selected, p.titleId))
          .map((p) => p.titleId), [selected]);
      expect(locations.where((p) => NeoSyncGameScope.switchCloudMatches(p.cloudFilePath,
          expectedTitleId: selected, legacyOwner: 'Untrusted display title',
          expectedNames: {'Untrusted display title'})).map((p) => p.titleId), [selected]);
    }
    expect(locations.any((p) => NeoSyncGameScope.switchTitleMatches(null, p.titleId)), isFalse);
  });

  test('legacy Switch matching is exact and native title mismatch is authoritative', () {
    expect(NeoSyncGameScope.switchCloudMatches('main', expectedTitleId: null,
      legacyOwner: 'Mario', expectedNames: {'Mario Kart'}), isFalse);
    expect(NeoSyncGameScope.switchCloudMatches('main', expectedTitleId: null,
      legacyOwner: '', expectedNames: {''}), isFalse);
    expect(NeoSyncGameScope.switchCloudMatches('main', expectedTitleId: null,
      legacyOwner: 'Super Mario Bros. Wonder', expectedNames: {'Super Mario Bros. Wonder'}), isTrue);
    expect(NeoSyncGameScope.switchCloudMatches('profiles/invalid/main',
      expectedTitleId: '010015100B514000', legacyOwner: 'Mario', expectedNames: {'Mario'}), isFalse);
  });
}
