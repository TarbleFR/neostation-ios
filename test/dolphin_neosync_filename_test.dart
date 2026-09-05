import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';

void main() {
  test('NeoSync listings preserve current, alternate and historical filenames', () {
    const cloudPath = 'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s01.nsav';
    for (final field in ['file_name', 'filename', 'fileName']) {
      final file = NeoSyncFile.fromJson({
        'id': '42', field: cloudPath,
        'game_name': 'Super Mario Sunshine', 'file_size': 4096,
      });
      expect(file.fileName, cloudPath);
      expect(file.displayName, 'Super Mario Sunshine · GMSE01.s01.nsav');
      expect(file.toJson()['file_name'], cloudPath);
    }
    expect(NeoSyncFile.fromJson({
      'file_name': 'saves/Été à Hyrule.srm', 'filename': 'wrong.srm',
    }).fileName, 'saves/Été à Hyrule.srm');
    expect(NeoSyncFile.fromJson({
      'file_name': ' ', 'filename': 'saves/Mario.srm',
    }).fileName, 'saves/Mario.srm');
  });

  test('Dolphin display titles never change save identity or other engines', () {
    const paths = [
      'v2/states/gc/dolphinios/game/GMSE01/GMSE01.s01.nsav',
      'v2/states/wii/dolphinios/game/00010000524d4350/RMCP01.s10.nsav',
      'v2/saves/gc/dolphinios/game/GMSE01/USA-A.nsav',
      'v2/saves/wii/dolphinios/game/00010000524d4350/data.nsav',
    ];
    for (final cloudPath in paths) {
      final metadata = {
        'id': '42', 'file_name': cloudPath, 'file_path': '/account/$cloudPath',
        'game_name': '  Mario — Édition française  ', 'file_hash': 'abc123',
      };
      final file = NeoSyncFile.fromJson(metadata);
      expect(file.displayName, 'Mario — Édition française · ${cloudPath.split('/').last}');
      expect(file.toJson()['file_name'], cloudPath);
      expect(file.toJson()['file_path'], metadata['file_path']);
      expect(file.toJson()['game_name'], metadata['game_name']);
      expect(file.id, metadata['id']);
      expect(file.checksum, metadata['file_hash']);
      expect(NeoSyncFile.fromJson({...metadata, 'game_name': ' '}).displayName, cloudPath);
    }
    for (final path in [
      'Mario.srm',
      'v2/states/gc/retroarch/game/GMSE01/GMSE01.state',
      'v2/states/ps2/dolphinios/game/game/save.state',
    ]) {
      expect(NeoSyncFile.fromJson({'file_name': path, 'game_name': 'Mario'}).displayName, path);
    }
  });

  test('missing filename remains visible without changing restore identity', () {
    final file = NeoSyncFile.fromJson({
      'id': '123', 'file_name': null,
      'file_path': '/account/saves/Zelda.srm',
      'game_name': 'Zelda', 'file_size': 8192,
    });
    expect(file.displayName, 'Zelda.srm');
    expect(file.fileName, isEmpty);
    expect(file.filePath, '/account/saves/Zelda.srm');
    expect(file.id, '123');
    expect(file.fileSize, 8192);
    expect(NeoSyncFile.fromJson({
      'id': '1', 'file_path': r'C:\saves\Mario.srm',
    }).displayName, 'Mario.srm');
    expect(NeoSyncFile.fromJson({'game_name': 'Mario'}).displayName, 'Mario');
    expect(NeoSyncFile.fromJson({'id': '7'}).displayName, 'NeoSync · 7');
  });
}
