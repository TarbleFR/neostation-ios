import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_data_migration.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory sandbox;
  late Directory source;
  late Directory target;
  Future<File> write(String relative, String content, {Directory? root}) async {
    final file = File(path.join((root ?? source).path, relative));
    await file.parent.create(recursive: true);
    return file.writeAsString(content);
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp(
      'retroarch-migration-test-',
    );
    source = await Directory(path.join(sandbox.path, 'source')).create();
    target = Directory(path.join(sandbox.path, 'target'));
  });
  tearDown(() async {
    await sandbox.delete(recursive: true);
  });

  test(
    'selected category subfolders copied, original files and excluded cores untouched',
    () async {
      await write('system/nested/console-bios.bin', 'legal-bios');
      await write('saves/Core/game.srm', 'save-data');
      await write('states/game.state', 'state-data');
      await write('games/PS1/game.cue', 'FILE "track.bin" BINARY');
      await write('games/PS1/track.bin', 'disc-data');
      await write('games/PS1/injected_libretro.dylib', 'binary');
      await write('Frameworks/evil.framework/evil', 'binary');
      final report = await RetroArchDataMigration.copy(
        sourceRoot: source,
        targetRoot: target,
        categories: {
          RetroArchMigrationCategory.bios,
          RetroArchMigrationCategory.games,
          RetroArchMigrationCategory.saves,
        },
      );
      expect(report.complete, isTrue);
      expect(report.copied, 4);
      expect(
        await File(
          path.join(target.path, 'system/nested/console-bios.bin'),
        ).readAsString(),
        'legal-bios',
      );
      expect(
        await File(
          path.join(target.path, 'saves/Core/game.srm'),
        ).readAsString(),
        'save-data',
      );
      expect(
        await File(
          path.join(source.path, 'saves/Core/game.srm'),
        ).readAsString(),
        'save-data',
      );
      expect(
        await Directory(path.join(target.path, 'states')).exists(),
        isFalse,
      );
      expect(
        await File(
          path.join(target.path, 'games/PS1/injected_libretro.dylib'),
        ).exists(),
        isFalse,
      );
      expect(
        await Directory(path.join(target.path, 'Frameworks')).exists(),
        isFalse,
      );
      final retry = await RetroArchDataMigration.copy(
        sourceRoot: source,
        targetRoot: target,
        categories: {
          RetroArchMigrationCategory.bios,
          RetroArchMigrationCategory.games,
          RetroArchMigrationCategory.saves,
        },
      );
      expect(retry.copied, 0);
      expect(retry.complete, isTrue);
    },
  );

  test(
    'Documents selection imports nested RetroArch data and sibling ROM directories',
    () async {
      await write('RetroArch/system/bios.bin', 'bios');
      await write('RetroArch/saves/game.srm', 'save');
      await write('SNES/game.sfc', 'rom');
      final report = await RetroArchDataMigration.copy(
        sourceRoot: source,
        targetRoot: target,
        categories: RetroArchMigrationCategory.values.toSet(),
      );
      expect(report.copied, 3);
      expect(
        await File(
          path.join(target.path, 'games/SNES/game.sfc'),
        ).readAsString(),
        'rom',
      );
      expect(
        await File(path.join(target.path, 'system/bios.bin')).readAsString(),
        'bios',
      );
    },
  );

  test(
    'migration retains DOS program data while excluding executable BIOS images',
    () async {
      final program = await write('games/dos/DOOM.EXE', '');
      await program.writeAsBytes([0x4d, 0x5a, 0x90, 0]);
      await write('games/dos/data/DOOM.WAD', 'game assets');
      final nativeBios = await write('system/not-a-bios.bin', '');
      await nativeBios.writeAsBytes([0x4d, 0x5a, 0x90, 0]);
      final report = await RetroArchDataMigration.copy(
        sourceRoot: source,
        targetRoot: target,
        categories: {
          RetroArchMigrationCategory.games,
          RetroArchMigrationCategory.bios,
        },
      );
      expect(report.complete, isTrue);
      expect(report.copied, 2);
      expect(
        await File(path.join(target.path, 'games/dos/DOOM.EXE')).readAsBytes(),
        await program.readAsBytes(),
      );
      expect(
        await File(
          path.join(target.path, 'games/dos/data/DOOM.WAD'),
        ).readAsString(),
        'game assets',
      );
      expect(
        await File(path.join(target.path, 'system/not-a-bios.bin')).exists(),
        isFalse,
      );
      expect(await nativeBios.exists(), isTrue);
    },
  );

  test(
    'keep collision skips conflicting file, replace retains backup and retry is idempotent',
    () async {
      final from = await write('saves/game.srm', 'new');
      final to = await write('saves/game.srm', 'old', root: target);
      expect(
        await RetroArchDataMigration.copyVerifiedFile(
          source: from,
          destination: to,
          destinationRoot: target,
          collision: RetroArchMigrationCollision.keepExisting,
        ),
        RetroArchMigrationFileResult.skipped,
      );
      expect(await to.readAsString(), 'old');
      expect(
        await RetroArchDataMigration.copyVerifiedFile(
          source: from,
          destination: to,
          destinationRoot: target,
          collision: RetroArchMigrationCollision.replaceWithBackup,
        ),
        RetroArchMigrationFileResult.copied,
      );
      expect(await to.readAsString(), 'new');
      final backups = await Directory(
        path.join(target.path, '.migration-backups'),
      ).list(recursive: true).where((entity) => entity is File).toList();
      expect(backups, hasLength(1));
      expect(
        path.extension(backups.single.path),
        '.backup',
        reason: 'Old game backups must never be rediscovered as ROMs.',
      );
      expect(await File(backups.single.path).readAsString(), 'old');
      expect(await from.readAsString(), 'new');
      expect(
        await RetroArchDataMigration.copyVerifiedFile(
          source: from,
          destination: to,
          destinationRoot: target,
          collision: RetroArchMigrationCollision.replaceWithBackup,
        ),
        RetroArchMigrationFileResult.skipped,
      );
      expect(
        await Directory(
          path.join(target.path, '.migration-backups'),
        ).list(recursive: true).where((entity) => entity is File).length,
        1,
      );
    },
  );

  test(
    'configs preserve originals and options but host paths and drivers are safely derived',
    () async {
      const original =
          'video_driver = "vulkan"\nlibretro_directory = "/external/cores"\nsystem_directory = "/external/system"\nvideo_smooth = "true"\nnetwork_cmd_enable = "true"\nvideo_shader = "/foreign/RetroArch/shaders/crt/preset.slangp"\n';
      await write('retroarch.cfg', original);
      await write(
        'config/retroarch-core-options.cfg',
        'mgba_gb_model = "Game Boy"\n',
      );
      final report = await RetroArchDataMigration.copy(
        sourceRoot: source,
        targetRoot: target,
        categories: {RetroArchMigrationCategory.configs},
      );
      expect(report.complete, isTrue);
      expect(
        await File(
          path.join(target.path, 'config/imported-originals/retroarch.cfg'),
        ).readAsString(),
        original,
      );
      expect(
        await File(path.join(source.path, 'retroarch.cfg')).readAsString(),
        original,
      );
      final derived = await File(
        path.join(target.path, 'config/retroarch.cfg'),
      ).readAsString();
      expect(derived, contains('video_smooth = "true"'));
      expect(derived, contains('system_directory = "${target.path}/system"'));
      expect(derived, contains('${target.path}/shaders/crt/preset.slangp'));
      expect(derived, isNot(contains('video_driver')));
      expect(derived, isNot(contains('libretro_directory')));
      expect(derived, isNot(contains('network_cmd_enable')));
      expect(
        await File(
          path.join(target.path, 'config/retroarch-core-options.cfg'),
        ).readAsString(),
        contains('mgba_gb_model'),
      );
    },
  );

  test(
    'partial failure is reported and retry preserves successful data',
    () async {
      await write('saves/good.srm', 'good');
      await write('saves/blocked.srm', 'blocked');
      await Directory(
        path.join(target.path, 'saves/blocked.srm'),
      ).create(recursive: true);
      final first = await RetroArchDataMigration.copy(
        sourceRoot: source,
        targetRoot: target,
        categories: {RetroArchMigrationCategory.saves},
      );
      expect(first.complete, isFalse);
      expect(first.copied, 1);
      expect(first.errors.keys, contains('saves/blocked.srm'));
      await Directory(path.join(target.path, 'saves/blocked.srm')).delete();
      final retry = await RetroArchDataMigration.copy(
        sourceRoot: source,
        targetRoot: target,
        categories: {RetroArchMigrationCategory.saves},
      );
      expect(retry.complete, isTrue);
      expect(retry.copied, 1);
      expect(retry.skipped, 1);
    },
  );

  test('source and destination symlink escapes are never traversed', () async {
    final outside = await Directory(
      path.join(sandbox.path, 'outside'),
    ).create();
    await File(
      path.join(outside.path, 'secret.bin'),
    ).writeAsString('untouched');
    await Link(path.join(source.path, 'system')).create(outside.path);
    final report = await RetroArchDataMigration.copy(
      sourceRoot: source,
      targetRoot: target,
      categories: {RetroArchMigrationCategory.bios},
    );
    expect(report.copied, 0);
    final from = await write('saves/game.srm', 'save');
    await target.create();
    await Link(path.join(target.path, 'saves')).create(outside.path);
    await expectLater(
      RetroArchDataMigration.copyVerifiedFile(
        source: from,
        destination: File(path.join(target.path, 'saves/game.srm')),
        destinationRoot: target,
        collision: RetroArchMigrationCollision.replaceWithBackup,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File(path.join(outside.path, 'game.srm')).exists(), isFalse);
    expect(
      await File(path.join(outside.path, 'secret.bin')).readAsString(),
      'untouched',
    );
  });

  test(
    'disc manifests rebase absolute source references while keeping originals',
    () async {
      final track = await write('games/PS1/Disc 1/track.bin', 'disc');
      final cueText = 'FILE "${track.path}" BINARY\n  TRACK 01 MODE2/2352\n';
      final cue = await write('games/PS1/Disc 1/game.cue', cueText);
      final playlistText = '${cue.path}\n';
      await write('games/PS1/game.m3u', playlistText);
      final report = await RetroArchDataMigration.copy(
        sourceRoot: source,
        targetRoot: target,
        categories: {RetroArchMigrationCategory.games},
      );
      expect(report.complete, isTrue, reason: '${report.errors}');
      expect(
        await File(
          path.join(target.path, 'games/PS1/Disc 1/game.cue'),
        ).readAsString(),
        'FILE "track.bin" BINARY\n  TRACK 01 MODE2/2352\n',
      );
      expect(
        await File(path.join(target.path, 'games/PS1/game.m3u')).readAsString(),
        'Disc 1/game.cue\n',
      );
      expect(
        await File(
          path.join(
            target.path,
            'config/imported-originals/games/PS1/game.m3u',
          ),
        ).readAsString(),
        playlistText,
      );
      expect(await cue.readAsString(), cueText);
    },
  );

  test(
    'shader and overlay resource references rebase, foreign references fail visibly',
    () async {
      final image = await write('overlays/gamepad/image.png', 'image');
      await write(
        'overlays/gamepad/overlay.cfg',
        'overlays = 1\noverlay0_overlay = "${image.path}"\n',
      );
      final shader = await write('shaders/crt/source.glsl', 'shader');
      await write(
        'shaders/crt/preset.glslp',
        'shaders = 1\nshader0 = "${shader.path}"\n',
      );
      final report = await RetroArchDataMigration.copy(
        sourceRoot: source,
        targetRoot: target,
        categories: {
          RetroArchMigrationCategory.overlays,
          RetroArchMigrationCategory.shaders,
        },
      );
      expect(report.complete, isTrue, reason: '${report.errors}');
      expect(
        await File(
          path.join(target.path, 'overlays/gamepad/overlay.cfg'),
        ).readAsString(),
        'overlays = 1\noverlay0_overlay = "image.png"\n',
      );
      expect(
        await File(
          path.join(target.path, 'shaders/crt/preset.glslp'),
        ).readAsString(),
        'shaders = 1\nshader0 = "source.glsl"\n',
      );
      final outside = await File(
        path.join(sandbox.path, 'outside.bin'),
      ).writeAsString('external');
      await write('games/foreign.m3u', '${outside.path}\n');
      final rejected = await RetroArchDataMigration.copy(
        sourceRoot: source,
        targetRoot: target,
        categories: {RetroArchMigrationCategory.games},
      );
      expect(rejected.complete, isFalse);
      expect(rejected.errors.keys, contains('games/foreign.m3u'));
      expect(
        await File(path.join(target.path, 'games/foreign.m3u')).exists(),
        isFalse,
      );
      expect(await outside.readAsString(), 'external');
    },
  );

  test('Mach-O executable disguised as a ROM is excluded', () async {
    final binary = File(path.join(source.path, 'games/core.bin'));
    await binary.parent.create(recursive: true);
    await binary.writeAsBytes([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]);
    final report = await RetroArchDataMigration.copy(
      sourceRoot: source,
      targetRoot: target,
      categories: {RetroArchMigrationCategory.games},
    );
    expect(report.copied, 0);
    expect(report.skipped, 1);
    expect(
      await File(path.join(target.path, 'games/core.bin')).exists(),
      isFalse,
    );
  });

  test('overlapping destination and missing source reject migration', () async {
    final alias = Link(path.join(sandbox.path, 'alias'));
    await alias.create(sandbox.path);
    await expectLater(
      RetroArchDataMigration.copy(
        sourceRoot: source,
        targetRoot: Directory(path.join(alias.path, 'source')),
        categories: {RetroArchMigrationCategory.games},
      ),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      RetroArchDataMigration.copy(
        sourceRoot: source,
        targetRoot: Directory(path.join(source.path, 'nested')),
        categories: {RetroArchMigrationCategory.games},
      ),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      RetroArchDataMigration.copy(
        sourceRoot: Directory(path.join(sandbox.path, 'missing')),
        targetRoot: target,
        categories: {RetroArchMigrationCategory.games},
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
