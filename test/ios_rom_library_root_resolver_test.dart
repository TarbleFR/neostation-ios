import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:neostation/services/ios_rom_library_root_resolver.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('neostation-ra-root-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('finds a custom nested library regardless of its name', () async {
    await Directory(path.join(temp.path, 'saves')).create();
    await Directory(path.join(temp.path, 'states')).create();
    final library = Directory(path.join(temp.path, 'Bibliothèque'));
    await Directory(path.join(library.path, 'psx')).create(recursive: true);
    await Directory(path.join(library.path, 'snes')).create(recursive: true);

    final resolved = await IosRomLibraryRootResolver.resolveRetroArchScanRoot(
      linkedRoot: temp.path,
      systemFolderNames: const ['psx', 'snes', 'gba'],
    );

    expect(path.normalize(resolved), path.normalize(library.path));
  });

  test('keeps the RetroArch root when systems live directly inside it', () async {
    await Directory(path.join(temp.path, 'psx')).create();
    await Directory(path.join(temp.path, 'gba')).create();

    final resolved = await IosRomLibraryRootResolver.resolveRetroArchScanRoot(
      linkedRoot: temp.path,
      systemFolderNames: const ['psx', 'snes', 'gba'],
    );

    expect(path.normalize(resolved), path.normalize(temp.path));
  });

  test('ignores saves and states as library candidates', () async {
    await Directory(path.join(temp.path, 'saves', 'psx')).create(recursive: true);
    await Directory(path.join(temp.path, 'states', 'snes')).create(recursive: true);
    final library = Directory(path.join(temp.path, 'My Games'));
    await Directory(path.join(library.path, 'gba')).create(recursive: true);

    final resolved = await IosRomLibraryRootResolver.resolveRetroArchScanRoot(
      linkedRoot: temp.path,
      systemFolderNames: const ['psx', 'snes', 'gba'],
    );

    expect(path.normalize(resolved), path.normalize(library.path));
  });
}
