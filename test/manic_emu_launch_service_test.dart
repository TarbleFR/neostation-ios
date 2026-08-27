import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/manic_emu_launch_service.dart';

void main() {
  test('persistent hash matches Manic EMU game identifier', () {
    const sha256OfAbc =
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

    expect(
      ManicEmuLaunchService.persistentHash(sha256OfAbc),
      '8957039215404510875',
    );
  });

  test('ZIP game identifier is calculated from the extracted ROM', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'manic_emu_launch_service_test_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));

    final archive = Archive()
      ..addFile(ArchiveFile('Adventure Island.nes', 3, <int>[97, 98, 99]));
    final zipPath = '${tempDirectory.path}/Adventure Island.zip';
    await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));

    expect(
      await ManicEmuLaunchService.gameIdForPath(zipPath),
      '8957039215404510875',
    );
  });

  test('plain ROM identifier is calculated by the background stream', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'manic_emu_plain_launch_test_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));

    final romPath = '${tempDirectory.path}/Adventure Island.nes';
    await File(romPath).writeAsBytes(<int>[97, 98, 99]);

    expect(
      await ManicEmuLaunchService.gameIdForPath(romPath),
      '8957039215404510875',
    );
  });
}
