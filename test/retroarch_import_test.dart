import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_import_service.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temporary;
  late Directory source;
  late Directory target;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('retroarch-import-');
    source = await Directory(path.join(temporary.path, 'source')).create();
    target = Directory(path.join(temporary.path, 'games'));
  });
  tearDown(() async => temporary.delete(recursive: true));

  test(
    'folder import preserves multidisc sidecars and original files',
    () async {
      final cue = File(path.join(source.path, 'Disc 1', 'disc.cue'));
      await cue.parent.create();
      await cue.writeAsString('FILE "disc.bin" BINARY\n');
      final bin = await File(
        path.join(cue.parent.path, 'disc.bin'),
      ).writeAsBytes(List.generate(5000, (i) => i % 256));
      final result = await RetroArchImportService.copyFiles(
        files: [cue, bin],
        sourceRoot: source,
        destination: target,
      );
      expect(result.imported, 2);
      expect(result.errors, isEmpty);
      expect(
        await File(path.join(target.path, 'Disc 1', 'disc.bin')).readAsBytes(),
        await bin.readAsBytes(),
      );
      expect(
        await File(path.join(target.path, 'Disc 1', 'disc.cue')).readAsString(),
        await cue.readAsString(),
      );
      expect(await cue.exists(), isTrue);
      expect(await bin.exists(), isTrue);
    },
  );

  test(
    'keep duplicates preserves destination and replacing keeps a backup',
    () async {
      final game = await File(
        path.join(source.path, 'game.nes'),
      ).writeAsString('new');
      await target.create();
      final old = await File(
        path.join(target.path, 'game.nes'),
      ).writeAsString('old');
      final skipped = await RetroArchImportService.copyFiles(
        files: [game],
        destination: target,
      );
      expect(skipped.skipped, 1);
      expect(await old.readAsString(), 'old');
      final replaced = await RetroArchImportService.copyFiles(
        files: [game],
        destination: target,
        replace: true,
      );
      expect(replaced.imported, 1);
      expect(await old.readAsString(), 'new');
      final backup = await target
          .list(recursive: true)
          .where(
            (file) => file is File && file.path.endsWith('game.nes.backup'),
          )
          .cast<File>()
          .single;
      expect(await backup.readAsString(), 'old');
      expect(await game.readAsString(), 'new');
    },
  );

  test('overlapping planned targets create no source directories', () async {
    final game = await File(
      path.join(source.path, 'game.nes'),
    ).writeAsString('game');
    final nested = Directory(path.join(source.path, 'created', 'games'));
    await expectLater(
      RetroArchImportService.copyFiles(
        files: [game],
        sourceRoot: source,
        destination: nested,
      ),
      throwsStateError,
    );
    expect(
      await Directory(path.join(source.path, 'created')).exists(),
      isFalse,
    );
    expect(await game.readAsString(), 'game');

    final alias = await Link(
      path.join(temporary.path, 'alias'),
    ).create(source.path);
    await expectLater(
      RetroArchImportService.copyFiles(
        files: [game],
        sourceRoot: source,
        destination: Directory(path.join(alias.path, 'created', 'games')),
      ),
      throwsStateError,
    );
    expect(
      await Directory(path.join(source.path, 'created')).exists(),
      isFalse,
    );
    final valid = await RetroArchImportService.copyFiles(
      files: [game],
      destination: target,
    );
    expect(
      valid.imported,
      1,
      reason: 'Overlap rejection must release the import lock.',
    );
  });

  test(
    'BIOS imports exclude executable images even under data names',
    () async {
      final files = <File>[];
      for (final entry in {
        'bios-macho.bin': [0xcf, 0xfa, 0xed, 0xfe],
        'bios-elf.bin': [0x7f, 0x45, 0x4c, 0x46],
        'bios-pe.bin': [0x4d, 0x5a, 0x90, 0],
        'fake.dylib': [1, 2, 3, 4],
        'scph5501.bin': [0, 1, 2, 3],
      }.entries) {
        files.add(
          await File(
            path.join(source.path, entry.key),
          ).writeAsBytes(entry.value),
        );
      }
      final result = await RetroArchImportService.copyFiles(
        files: files,
        destination: target,
        bios: true,
      );
      expect(result.imported, 1);
      expect(result.skipped, 4);
      expect(result.errors, isEmpty);
      expect(
        await File(path.join(target.path, 'scph5501.bin')).exists(),
        isTrue,
      );
      expect(
        await File(path.join(target.path, 'bios-macho.bin')).exists(),
        isFalse,
      );
      expect(await files.first.exists(), isTrue);
    },
  );

  test(
    'folder import retains emulated DOS executables and full asset hierarchy',
    () async {
      final executable = await File(
        path.join(source.path, 'DOOM.EXE'),
      ).writeAsBytes([0x4d, 0x5a, 0x90, 0]);
      final assets = <File>[executable];
      for (final filename in [
        'DOOM.WAD',
        'setup.cfg',
        'data/levels.dat',
        'media/title.png',
        'audio/theme.ogg',
      ]) {
        final asset = File(path.join(source.path, filename));
        await asset.parent.create(recursive: true);
        await asset.writeAsString('user asset');
        assets.add(asset);
      }
      final libretro = await File(
        path.join(source.path, 'dosbox_libretro.dylib'),
      ).writeAsString('core');
      final report = await RetroArchImportService.copyFiles(
        files: [...assets, libretro],
        sourceRoot: source,
        destination: target,
        preserveSidecars: true,
      );
      expect(report.imported, 6);
      expect(report.skipped, 1);
      expect(report.errors, isEmpty);
      for (final asset in assets) {
        final copy = File(
          path.join(target.path, path.relative(asset.path, from: source.path)),
        );
        expect(await copy.readAsBytes(), await asset.readAsBytes());
      }
      expect(
        await File(path.join(target.path, 'dosbox_libretro.dylib')).exists(),
        isFalse,
      );
      expect(await libretro.exists(), isTrue);
    },
  );

  test(
    'individual imports accept expanded reviewed catalogue formats',
    () async {
      final game = await File(
        path.join(source.path, 'game.a26'),
      ).writeAsString('Atari game');
      final report = await RetroArchImportService.copyFiles(
        files: [game],
        destination: target,
      );
      expect(report.imported, 1);
      expect(report.errors, isEmpty);
    },
  );

  test(
    'source symlink is rejected and destination symlink cannot escape root',
    () async {
      final bios = await File(
        path.join(source.path, 'bios.bin'),
      ).writeAsString('bios');
      final link = await Link(
        path.join(source.path, 'link.bin'),
      ).create(bios.path);
      final first = await RetroArchImportService.copyFiles(
        files: [File(link.path)],
        destination: target,
        bios: true,
      );
      expect(first.imported, 0);
      expect(first.errors, hasLength(1));
      final elsewhere = await Directory(
        path.join(temporary.path, 'elsewhere'),
      ).create();
      await Link(
        path.join(target.path, 'bios.bin'),
      ).create(path.join(elsewhere.path, 'bios.bin'));
      final second = await RetroArchImportService.copyFiles(
        files: [bios],
        destination: target,
        bios: true,
        replace: true,
      );
      expect(second.imported, 0);
      expect(
        await File(path.join(elsewhere.path, 'bios.bin')).exists(),
        isFalse,
      );
    },
  );
}
