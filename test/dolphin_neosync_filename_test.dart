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
      expect(file.displayName, cloudPath);
      expect(file.toJson()['file_name'], cloudPath);
    }
    expect(NeoSyncFile.fromJson({
      'file_name': 'saves/Été à Hyrule.srm', 'filename': 'wrong.srm',
    }).fileName, 'saves/Été à Hyrule.srm');
    expect(NeoSyncFile.fromJson({
      'file_name': ' ', 'filename': 'saves/Mario.srm',
    }).fileName, 'saves/Mario.srm');
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
