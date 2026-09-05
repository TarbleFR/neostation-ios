import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/services/dolphin_neosync_store.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';

class _NoTransferNeoSyncService implements NeoSyncService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No API transfer should be attempted');
}

void main() {
  const gcState = 'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s01.nsav';
  const wiiState = 'v2/states/wii/dolphinios/game/00010000524d4350/RMCP01.s10.nsav';

  test('NeoSync listings preserve current, alternate and historical filenames', () {
    for (final field in ['file_name', 'filename', 'fileName']) {
      final file = NeoSyncFile.fromJson({
        'id': '42', field: gcState,
        'game_name': 'Super Mario Sunshine', 'file_size': 4096,
      });
      expect(file.fileName, gcState);
      expect(file.displayName, 'Super Mario Sunshine · Slot 1');
      expect(file.dolphinDetailName, 'GMSE01.s01');
      expect(file.toJson()['file_name'], gcState);
    }
    expect(NeoSyncFile.fromJson({
      'file_name': 'saves/Été à Hyrule.srm', 'filename': 'wrong.srm',
    }).fileName, 'saves/Été à Hyrule.srm');
    expect(NeoSyncFile.fromJson({
      'file_name': ' ', 'filename': 'saves/Mario.srm',
    }).fileName, 'saves/Mario.srm');
  });

  test('titles are shown only on numbered Dolphin states, including aliases', () {
    for (final path in [gcState, wiiState]) {
      for (final field in ['game_name', 'gameName']) {
        final file = NeoSyncFile.fromJson({
          'id': '42', 'file_name': path, field: ' Mario — Édition française ',
          'file_hash': 'abc123', 'file_path': '/account/$path',
        });
        final slot = path == gcState ? 1 : 10;
        expect(file.displayName, 'Mario — Édition française · Slot $slot');
        expect(file.id, '42');
        expect(file.checksum, 'abc123');
        expect(file.toJson()['file_name'], path);
        expect(file.toJson()['file_path'], '/account/$path');
        expect(file.toJson()['game_name'], ' Mario — Édition française ');
      }
    }
    for (final path in [
      'Mario.srm', 'v2/states/gc/retroarch/game/GMSE01/GMSE01.state',
      'v2/states/ps2/dolphinios/game/game/save.state',
      'v2/states/gc/dolphinios/game/GZLE01/GMSE01.s01.nsav',
    ]) {
      expect(NeoSyncFile.fromJson({'file_name': path, 'game_name': 'Mario'}).displayName, path);
    }
  });

  test('internal GC saves keep the exact card label, region and slot remain visible', () {
    for (final path in [
      'v2/saves/gc/dolphinios/game/GMSE01/gci-USA-A.nsav',
      'v2/saves/gc/dolphinios/game/GZLE01/gci-USA-B.nsav',
      'v2/saves/gc/dolphinios/shared/MemoryCardA.EUR.raw.nsav',
    ]) {
      final file = NeoSyncFile.fromJson({'file_name': path, 'game_name': 'Mario'});
      expect(file.displayName, 'GC Memory cards');
      expect(file.dolphinDetailName, isNotEmpty);
      expect(file.toJson()['file_name'], path);
      expect(file.withDolphinDisplayTitle('Zelda').displayName, 'GC Memory cards');
    }
    final wii = NeoSyncFile.fromJson({
      'file_name': 'v2/saves/wii/dolphinios/game/00010000524d4350/wii-data.nsav',
      'game_name': 'Mario Kart Wii',
    });
    expect(wii.displayName, 'Wii saves');
    expect(wii.dolphinDetailName, '00010000524d4350');
  });

  test('split basename and cloud path recover native identity and preserve transport data', () {
    for (final filename in ['GMSE01.s01.nsav', '']) {
      final data = {
        'id': 'file-1', 'file_name': filename, 'file_path': '/account/$gcState',
        'gameName': 'Super Mario Sunshine', 'file_hash': 'abc123',
      };
      final file = NeoSyncFile.fromJson(data);
      expect(file.presentationPath, gcState);
      expect(file.sourceSavePath, gcState);
      expect(file.dolphinTarget?.cloudPath, gcState);
      expect(file.displayName, 'Super Mario Sunshine · Slot 1');
      expect(file.fileName, filename);
      expect(file.filePath, data['file_path']);
      expect(file.id, 'file-1');
      expect(file.checksum, 'abc123');
    }
    for (final filename in ['GZLE01.s01.nsav', 'foreign/GMSE01.s01.nsav']) {
      final file = NeoSyncFile.fromJson({
        'file_name': filename, 'file_path': '/account/$gcState', 'game_name': 'Mario',
      });
      expect(file.dolphinTarget, isNull);
      expect(file.displayName, filename);
    }
  });

  test('split Dolphin saves cannot enter another emulator or generic restore', () async {
    final provider = NeoSyncProvider(_NoTransferNeoSyncService());
    addTearDown(provider.dispose);
    const unrelatedGame = GameModel(
      romname: 'GMSE01', realname: 'Another console', name: 'Another console',
      year: '', developer: '', publisher: '', genre: '', players: '', rating: 0,
      systemFolderName: 'ps2', systemId: 'ps2',
    );
    for (final key in [gcState, wiiState,
      'v2/saves/gc/dolphinios/shared/MemoryCardA.USA.raw.nsav',
      'v2/saves/gc/dolphinios/game/GMSE01/gci-USA-A.nsav',
      'v2/saves/wii/dolphinios/game/00010000524d4350/wii-data.nsav',
    ]) {
      for (final name in [key.split('/').last, '']) {
        final file = NeoSyncFile.fromJson({
          'id': 'unchanged-id', 'file_name': name,
          'file_path': '/storage/account/$key', 'file_hash': 'unchanged-hash',
        });
        final before = file.toJson();
        expect(file.dolphinTarget?.cloudPath, key);
        expect(await provider.resolveCloudFileToLocalPath(unrelatedGame, file), isEmpty);
        // The dedicated Dolphin restore refuses this unauthenticated request
        // before looking up RetroArch folders or contacting either API.
        await expectLater(provider.restoreCloudBackup(file), throwsA(
          isA<StateError>().having((error) => error.message, 'reason',
            'NeoSync authentication required'),
        ));
        expect(file.toJson(), before);
      }
    }
  });

  test('old unnamed states get native-identity playlist titles without modifying cloud metadata', () {
    final titles = DolphinSaveTitleCache();
    titles.remember(const DolphinSaveIdentity(system: 'gc', gameId: 'GMSE01', region: 'USA'),
      'Super Mario Sunshine');
    titles.remember(const DolphinSaveIdentity(system: 'wii', gameId: 'RMCP01', region: 'EUR',
      titleId: '00010000524d4350'), 'Mario Kart Wii');
    for (final path in [gcState, wiiState]) {
      for (final oldTitle in ['', path == gcState ? 'GMSE01' : '00010000524d4350']) {
        final original = NeoSyncFile.fromJson({'id': '12', 'file_name': path,
          'game_name': oldTitle, 'file_hash': 'abc'});
        expect(original.hasDolphinGameTitle, isFalse);
        final shown = original.withDolphinDisplayTitle(titles.titleFor(original.dolphinTarget!));
        expect(shown.displayName, path == gcState ? 'Super Mario Sunshine · Slot 1' : 'Mario Kart Wii · Slot 10');
        expect(shown.toJson(), original.toJson());
      }
    }
    final foreign = DolphinSaveTarget.statesForGame(
      const DolphinSaveIdentity(system: 'gc', gameId: 'GZLE01', region: 'USA')).first;
    expect(titles.titleFor(foreign), isNull);
    final card = DolphinSaveTarget.raw('MemoryCardA.USA.raw')!;
    expect(titles.titleFor(card), isNull);
    final unknown = NeoSyncFile.fromJson({'file_name': foreign.cloudPath});
    expect(unknown.displayName, 'GZLE01.s01');
  });

  test('PlayStation savedata components remain visible with proven console and game context', () {
    for (final component in ['SYSDATA', 'ICON0.PNG', 'PARAM.SFO', 'PIC1.PNG', 'PLAYDATA']) {
      final path = 'v2/saves/ps3/rpcs3/game/Bladestorm/00000001/BLES00050-SAVE/$component';
      final file = NeoSyncFile.fromJson({
        'id': component, 'file_name': component, 'file_path': '/account/$path',
      });
      expect(file.presentationPath, path);
      expect(file.displayName, 'PS3 · Bladestorm · $component');
      expect(file.fileName, component);
      expect(file.id, component);
      final psp = NeoSyncFile.fromJson({'file_name': component,
        'file_path': '/saves/PSP/SAVEDATA/ULES00151DATA/$component'});
      expect(psp.displayName, 'PSP · ULES00151DATA · $component');
    }
    final historical = NeoSyncFile.fromJson({
      'file_name': 'ICON0.PNG', 'game_name': 'Bladestorm',
    });
    expect(historical.displayName, 'Bladestorm · ICON0.PNG');
    expect(NeoSyncFile.fromJson({'file_name': 'ICON0.PNG', 'game_name': 'ICON0'}).displayName,
      'ICON0.PNG');
    final unrelated = NeoSyncFile.fromJson({
      'file_name': 'ICON0.PNG', 'file_path': '/unrelated/ICON0.PNG',
    });
    expect(unrelated.displayName, 'ICON0.PNG');
  });

  test('missing upload date uses the real source timestamp instead of today', () {
    final source = DateTime.utc(2024, 2, 3, 12, 30);
    for (final value in [source.millisecondsSinceEpoch,
      '${source.millisecondsSinceEpoch}', source.millisecondsSinceEpoch ~/ 1000]) {
      final file = NeoSyncFile.fromJson({
        'file_name': gcState, 'file_modified_at_timestamp': value,
      });
      expect(file.fileModifiedAt, source);
      expect(file.uploadedAt, source);
      expect(file.fileModifiedAtTimestamp, source.millisecondsSinceEpoch);
    }
    final upload = DateTime.utc(2025, 1, 2);
    final created = DateTime.utc(2025, 1, 3);
    expect(NeoSyncFile.fromJson({
      'file_name': gcState, 'created_at': 'invalid',
      'uploaded_at': upload.toIso8601String(),
      'file_modified_at_timestamp': source.millisecondsSinceEpoch,
    }).uploadedAt, upload);
    expect(NeoSyncFile.fromJson({
      'file_name': gcState, 'created_at': created.toIso8601String(),
      'uploaded_at': upload.toIso8601String(),
    }).uploadedAt, created);
    expect(NeoSyncFile.fromJson({'file_modified_at_timestamp': 0}).fileModifiedAt,
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
  });

  test('missing filename remains visible without changing restore identity', () {
    final file = NeoSyncFile.fromJson({
      'id': '123', 'file_name': null, 'file_path': '/account/saves/Zelda.srm',
      'game_name': 'Zelda', 'file_size': 8192,
    });
    expect(file.displayName, 'Zelda.srm');
    expect(file.fileName, isEmpty);
    expect(file.filePath, '/account/saves/Zelda.srm');
    expect(file.id, '123');
    expect(file.fileSize, 8192);
    expect(NeoSyncFile.fromJson({'id': '1', 'file_path': r'C:\saves\Mario.srm'}).displayName, 'Mario.srm');
    expect(NeoSyncFile.fromJson({'game_name': 'Mario'}).displayName, 'Mario');
    expect(NeoSyncFile.fromJson({'id': '7'}).displayName, 'NeoSync · 7');
  });
}
