import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/fin_library_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('neostation_fin_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('classifies RVZ prefix returned by native iOS scan', () {
    final bytes = Uint8List(0x100);
    bytes.setRange(0, 4, const <int>[0x52, 0x56, 0x5a, 0x01]);
    ByteData.sublistView(bytes).setUint32(0x48, 2, Endian.big);
    bytes.setRange(0x58, 0x5e, 'RMCE01'.codeUnits);

    final info = FinLibraryService.detectDiscInfoFromPrefix(
      bytes,
      extension: '.rvz',
      pathHint: 'Mario Kart Wii (Europe).rvz',
    );
    expect(info?.systemFolder, 'wii');
    expect(info?.gameId, 'RMCE01');
  });

  test('reads GameCube disc_type from RVZ header', () async {
    final bytes = Uint8List(0x100);
    bytes.setRange(0, 4, const <int>[0x52, 0x56, 0x5a, 0x01]);
    ByteData.sublistView(bytes).setUint32(0x48, 1, Endian.big);
    bytes.setRange(0x58, 0x5e, 'GFZE01'.codeUnits);
    final file = File('${tempDir.path}/F-Zero GX.rvz');
    await file.writeAsBytes(bytes);

    final info = await FinLibraryService.detectDiscInfo(file);
    expect(info?.systemFolder, 'gc');
    expect(info?.gameId, 'GFZE01');
  });

  test('reads Wii disc_type from RVZ header', () async {
    final bytes = Uint8List(0x100);
    bytes.setRange(0, 4, const <int>[0x52, 0x56, 0x5a, 0x01]);
    ByteData.sublistView(bytes).setUint32(0x48, 2, Endian.big);
    bytes.setRange(0x58, 0x5e, 'RMCE01'.codeUnits);
    final file = File('${tempDir.path}/Mario Kart Wii.rvz');
    await file.writeAsBytes(bytes);

    final info = await FinLibraryService.detectDiscInfo(file);
    expect(info?.systemFolder, 'wii');
    expect(info?.gameId, 'RMCE01');
  });

  test('recognizes standard GameCube ISO header magic', () async {
    final bytes = Uint8List(0x100);
    bytes.setRange(0, 6, 'GMSE01'.codeUnits);
    ByteData.sublistView(bytes).setUint32(0x1c, 0xc2339f3d, Endian.big);
    final file = File('${tempDir.path}/Sunshine.iso');
    await file.writeAsBytes(bytes);

    final info = await FinLibraryService.detectDiscInfo(file);
    expect(info?.systemFolder, 'gc');
    expect(info?.gameId, 'GMSE01');
  });

  test('recognizes standard Wii ISO header magic', () async {
    final bytes = Uint8List(0x100);
    bytes.setRange(0, 6, 'RZDE01'.codeUnits);
    ByteData.sublistView(bytes).setUint32(0x18, 0x5d1c9ea3, Endian.big);
    final file = File('${tempDir.path}/Twilight Princess.iso');
    await file.writeAsBytes(bytes);

    final info = await FinLibraryService.detectDiscInfo(file);
    expect(info?.systemFolder, 'wii');
    expect(info?.gameId, 'RZDE01');
  });

  test('uses unambiguous Fin extension families', () async {
    final gameCube = File('${tempDir.path}/game.gcz');
    final wii = File('${tempDir.path}/game.wbfs');
    await gameCube.writeAsBytes(const <int>[0]);
    await wii.writeAsBytes(const <int>[0]);

    expect(
      (await FinLibraryService.detectDiscInfo(gameCube))?.systemFolder,
      'gc',
    );
    expect((await FinLibraryService.detectDiscInfo(wii))?.systemFolder, 'wii');
  });
}
