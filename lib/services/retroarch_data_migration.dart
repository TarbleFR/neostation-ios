import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'retroarch_core_catalog.dart';

enum RetroArchMigrationCategory {
  bios,
  games,
  saves,
  states,
  configs,
  shaders,
  overlays,
  cheats,
}

enum RetroArchMigrationCollision { keepExisting, replaceWithBackup }

enum RetroArchMigrationFileResult { copied, skipped }

class RetroArchMigrationCopyReport {
  RetroArchMigrationCopyReport({
    required this.copied,
    required this.skipped,
    required this.errors,
  });
  final int copied;
  final int skipped;
  final Map<String, String> errors;
  bool get complete => errors.isEmpty;
}

/// Copies only user data from the folder the user explicitly selected. It never
/// follows symlinks, imports executable cores, deletes sources or activates an
/// unmodified external RetroArch configuration.
abstract final class RetroArchDataMigration {
  static const _categoryFolders = <String, RetroArchMigrationCategory>{
    'system': RetroArchMigrationCategory.bios,
    'games': RetroArchMigrationCategory.games,
    'roms': RetroArchMigrationCategory.games,
    'downloads': RetroArchMigrationCategory.games,
    'saves': RetroArchMigrationCategory.saves,
    'states': RetroArchMigrationCategory.states,
    'config': RetroArchMigrationCategory.configs,
    'shaders': RetroArchMigrationCategory.shaders,
    'overlays': RetroArchMigrationCategory.overlays,
    'cheats': RetroArchMigrationCategory.cheats,
    'cht': RetroArchMigrationCategory.cheats,
  };
  static const _destinationFolders = <RetroArchMigrationCategory, String>{
    RetroArchMigrationCategory.bios: 'system',
    RetroArchMigrationCategory.games: 'games',
    RetroArchMigrationCategory.saves: 'saves',
    RetroArchMigrationCategory.states: 'states',
    RetroArchMigrationCategory.configs: 'config',
    RetroArchMigrationCategory.shaders: 'shaders',
    RetroArchMigrationCategory.overlays: 'overlays',
    RetroArchMigrationCategory.cheats: 'cheats',
  };
  static const _ignoredRoots = {
    'cores',
    'modules',
    'frameworks',
    'assets',
    'database',
    'info',
    'autoconfig',
    'logs',
    'playlists',
    'thumbnails',
    'records',
    'records_config',
    'filters',
    '__macosx',
  };
  static const _executables = {'.dylib', '.so', '.dll', '.ipa', '.a'};
  static Set<String> get _romExtensions => {
    for (final extension in RetroArchCoreCatalog.recognizedGameExtensions)
      '.$extension',
    '.img',
    '.sub',
    '.mdf',
    '.mds',
  };

  static String _token() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  static Future<String> _digest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static Future<String> _canonicalDirectory(Directory directory) async {
    var current = path.normalize(path.absolute(directory.path));
    final missing = <String>[];
    while (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.notFound) {
      missing.add(path.basename(current));
      final parent = path.dirname(current);
      if (parent == current) {
        throw FileSystemException(
          'No existing destination ancestor',
          directory.path,
        );
      }
      current = parent;
    }
    final resolved = await Directory(current).resolveSymbolicLinks();
    return path.joinAll([resolved, ...missing.reversed]);
  }

  /// User imports never turn executable images into BIOS or game data.
  static Future<bool> isExecutableFile(
    File file, {
    bool includePortableExecutables = true,
  }) async {
    final input = await file.open();
    try {
      final magic = await input.read(4);
      if (magic.length < 4) return false;
      final value = magic
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      return const {
            'cffaedfe',
            'feedfacf',
            'cefaedfe',
            'feedface',
            'cafebabe',
            'bebafeca',
            'cafebabf',
            'bfbafeca',
            '7f454c46',
          }.contains(value) ||
          (includePortableExecutables && magic[0] == 0x4d && magic[1] == 0x5a);
    } finally {
      await input.close();
    }
  }

  static Future<void> _safeParents(Directory root, String target) async {
    final rootPath = path.normalize(path.absolute(root.path));
    final targetPath = path.normalize(path.absolute(target));
    if (!path.isWithin(rootPath, targetPath)) {
      throw const FileSystemException('Destination is outside RetroArch');
    }
    // iOS's system-owned /var prefix can be a symlink to /private/var. Reject
    // symlinks in the user data root and its descendants, not OS ancestors.
    final rootType = await FileSystemEntity.type(rootPath, followLinks: false);
    if (rootType == FileSystemEntityType.link ||
        rootType == FileSystemEntityType.file) {
      throw FileSystemException(
        'Destination root is not a directory',
        rootPath,
      );
    }
    await Directory(rootPath).create(recursive: true);
    var current = rootPath;
    for (final segment in path.split(
      path.relative(path.dirname(targetPath), from: rootPath),
    )) {
      if (segment == '.') continue;
      current = path.join(current, segment);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link ||
          type == FileSystemEntityType.file) {
        throw FileSystemException(
          'Destination parent is not a directory',
          current,
        );
      }
      if (type == FileSystemEntityType.notFound) {
        await Directory(current).create();
      }
    }
  }

  /// Atomic replacement after size and SHA-256 verification. The old file is
  /// retained as a verified backup. Repeating a partial migration is idempotent.
  static Future<RetroArchMigrationFileResult> copyVerifiedFile({
    required File source,
    required File destination,
    required Directory destinationRoot,
    required RetroArchMigrationCollision collision,
  }) async {
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('Source is not a regular file', source.path);
    }
    await _safeParents(destinationRoot, destination.path);
    final destinationType = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    if (destinationType != FileSystemEntityType.notFound &&
        destinationType != FileSystemEntityType.file) {
      throw FileSystemException(
        'Destination is not a regular file',
        destination.path,
      );
    }
    final sourceSize = await source.length();
    final sourceDigest = await _digest(source);
    if (destinationType == FileSystemEntityType.file) {
      if (await destination.length() == sourceSize &&
          await _digest(destination) == sourceDigest) {
        return RetroArchMigrationFileResult.skipped;
      }
      if (collision == RetroArchMigrationCollision.keepExisting) {
        return RetroArchMigrationFileResult.skipped;
      }
    }
    final staged = File(
      path.join(destinationRoot.path, '.migration-staging', _token()),
    );
    await _safeParents(destinationRoot, staged.path);
    File? backup;
    try {
      await source.copy(staged.path);
      if (await staged.length() != sourceSize ||
          await _digest(staged) != sourceDigest) {
        throw FileSystemException(
          'Copied file failed verification',
          source.path,
        );
      }
      final handle = await staged.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      // The user can edit Files during a large copy. Recheck the destination
      // immediately before committing; never overwrite a newly created file
      // under the keep-existing policy or follow a replaced symlink.
      await _safeParents(destinationRoot, destination.path);
      final latestType = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      if (latestType != FileSystemEntityType.notFound &&
          latestType != FileSystemEntityType.file) {
        throw FileSystemException(
          'Destination changed to a nonregular file',
          destination.path,
        );
      }
      if (latestType == FileSystemEntityType.file) {
        if (await destination.length() == sourceSize &&
            await _digest(destination) == sourceDigest) {
          return RetroArchMigrationFileResult.skipped;
        }
        if (collision == RetroArchMigrationCollision.keepExisting) {
          return RetroArchMigrationFileResult.skipped;
        }
        backup = File(
          path.join(
            destinationRoot.path,
            '.migration-backups',
            _token(),
            '${path.relative(destination.path, from: destinationRoot.path)}.backup',
          ),
        );
        await _safeParents(destinationRoot, backup.path);
        final previousDigest = await _digest(destination);
        await destination.rename(backup.path);
        if (await _digest(backup) != previousDigest) {
          throw FileSystemException('Backup failed verification', backup.path);
        }
      }
      await staged.rename(destination.path);
      return RetroArchMigrationFileResult.copied;
    } catch (_) {
      if (backup != null &&
          await backup.exists() &&
          !await destination.exists()) {
        await backup.rename(destination.path);
      }
      rethrow;
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }

  static Future<RetroArchMigrationCopyReport> copy({
    required Directory sourceRoot,
    required Directory targetRoot,
    required Set<RetroArchMigrationCategory> categories,
    RetroArchMigrationCollision collision =
        RetroArchMigrationCollision.keepExisting,
    void Function(int done, int total)? onProgress,
  }) async {
    if (await FileSystemEntity.type(sourceRoot.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'Source folder is missing or is a symlink',
        sourceRoot.path,
      );
    }
    final sourcePath = await sourceRoot.resolveSymbolicLinks();
    final targetPath = await _canonicalDirectory(targetRoot);
    if (sourcePath == targetPath ||
        path.isWithin(sourcePath, targetPath) ||
        path.isWithin(targetPath, sourcePath)) {
      throw const FileSystemException('Source and destination folders overlap');
    }
    // Files may expose the app Documents folder. Keep sibling ROM directories
    // while mapping its nested RetroArch data folders to the same destination.
    final root = sourceRoot;
    final items =
        <
          ({File source, String relative, RetroArchMigrationCategory category})
        >[];
    var skipped = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        if (entity is Link) skipped++;
        continue;
      }
      final relative = path.relative(entity.path, from: root.path);
      final originalParts = path.split(relative);
      final parts =
          originalParts.first.toLowerCase() == 'retroarch' &&
              originalParts.length > 1
          ? originalParts.skip(1).toList()
          : originalParts;
      if (parts.any(
            (part) =>
                part.startsWith('.') ||
                part.toLowerCase().endsWith('.framework'),
          ) ||
          _executables.contains(path.extension(relative).toLowerCase()) ||
          path.basename(relative).toLowerCase().contains('_libretro') ||
          _ignoredRoots.contains(parts.first.toLowerCase())) {
        skipped++;
        continue;
      }
      var category = _categoryFolders[parts.first.toLowerCase()];
      if (category == null &&
          parts.length == 1 &&
          path.extension(relative).toLowerCase() == '.cfg') {
        category = RetroArchMigrationCategory.configs;
      }
      if (category == null &&
          _romExtensions.contains(path.extension(relative).toLowerCase())) {
        category = RetroArchMigrationCategory.games;
      }
      if (category == null || !categories.contains(category)) {
        skipped++;
        continue;
      }
      if (await isExecutableFile(
        entity,
        includePortableExecutables:
            category != RetroArchMigrationCategory.games,
      )) {
        skipped++;
        continue;
      }
      var tail =
          parts.length > 1 &&
              _categoryFolders.containsKey(parts.first.toLowerCase())
          ? path.joinAll(parts.skip(1))
          : path.joinAll(parts);
      if (parts.first.toLowerCase() == 'downloads' && parts.length > 1) {
        tail = path.join('downloads', tail);
      }
      items.add((
        source: entity,
        relative: path.join(_destinationFolders[category]!, tail),
        category: category,
      ));
    }
    items.sort((a, b) => a.relative.compareTo(b.relative));
    final errors = <String, String>{};
    var copied = 0;
    var done = 0;
    for (final item in items) {
      try {
        final isConfig =
            item.category == RetroArchMigrationCategory.configs &&
            path.extension(item.relative).toLowerCase() == '.cfg';
        final extension = path.extension(item.relative).toLowerCase();
        final isManifest =
            item.category == RetroArchMigrationCategory.games &&
            const {'.m3u', '.cue'}.contains(extension);
        final isPreset =
            (item.category == RetroArchMigrationCategory.overlays &&
                extension == '.cfg') ||
            (item.category == RetroArchMigrationCategory.shaders &&
                const {'.slangp', '.glslp'}.contains(extension));
        if (isConfig || isManifest || isPreset) {
          final archived = path.join(
            'config',
            'imported-originals',
            path.relative(item.source.path, from: root.path),
          );
          await copyVerifiedFile(
            source: item.source,
            destination: File(path.join(targetRoot.path, archived)),
            destinationRoot: targetRoot,
            collision: collision,
          );
          final staged = File(
            path.join(targetRoot.path, '.migration-staging', '${_token()}.cfg'),
          );
          await _safeParents(targetRoot, staged.path);
          try {
            final original = await item.source.readAsString();
            // Core-options files have their own parser and cannot set host
            // drivers or executable paths. Preserve their option keys intact.
            final coreOptions = path
                .basename(item.relative)
                .toLowerCase()
                .contains('core-options');
            final derived = isManifest
                ? await _rewriteDiscManifest(
                    original,
                    source: item.source,
                    destination: File(
                      path.join(targetRoot.path, item.relative),
                    ),
                    sourceRoot: sourceRoot,
                    targetRoot: targetRoot,
                  )
                : isPreset
                ? await _rewritePreset(
                    original,
                    source: item.source,
                    destination: File(
                      path.join(targetRoot.path, item.relative),
                    ),
                    sourceRoot: sourceRoot,
                    targetRoot: targetRoot,
                  )
                : coreOptions
                ? original
                : sanitizeConfiguration(original, targetRoot: targetRoot);
            await staged.writeAsString(derived, flush: true);
            final result = await copyVerifiedFile(
              source: staged,
              destination: File(path.join(targetRoot.path, item.relative)),
              destinationRoot: targetRoot,
              collision: collision,
            );
            if (result == RetroArchMigrationFileResult.copied) {
              copied++;
            } else {
              skipped++;
            }
          } finally {
            if (await staged.exists()) await staged.delete();
          }
        } else {
          final result = await copyVerifiedFile(
            source: item.source,
            destination: File(path.join(targetRoot.path, item.relative)),
            destinationRoot: targetRoot,
            collision: collision,
          );
          if (result == RetroArchMigrationFileResult.copied) {
            copied++;
          } else {
            skipped++;
          }
        }
      } catch (error) {
        errors[path.relative(item.source.path, from: root.path)] = '$error';
      }
      onProgress?.call(++done, items.length);
    }
    return RetroArchMigrationCopyReport(
      copied: copied,
      skipped: skipped,
      errors: Map.unmodifiable(errors),
    );
  }

  static String? _destinationForReference(String relative) {
    final originalParts = path.split(relative);
    final parts =
        originalParts.first.toLowerCase() == 'retroarch' &&
            originalParts.length > 1
        ? originalParts.skip(1).toList()
        : originalParts;
    if (parts.any(
          (part) =>
              part == '..' ||
              part.startsWith('.') ||
              part.toLowerCase().endsWith('.framework'),
        ) ||
        _ignoredRoots.contains(parts.first.toLowerCase()) ||
        _executables.contains(path.extension(relative).toLowerCase())) {
      return null;
    }
    final category =
        _categoryFolders[parts.first.toLowerCase()] ??
        (_romExtensions.contains(path.extension(relative).toLowerCase())
            ? RetroArchMigrationCategory.games
            : null);
    if (category == null) return null;
    var tail =
        parts.length > 1 &&
            _categoryFolders.containsKey(parts.first.toLowerCase())
        ? path.joinAll(parts.skip(1))
        : path.joinAll(parts);
    if (parts.first.toLowerCase() == 'downloads' && parts.length > 1) {
      tail = path.join('downloads', tail);
    }
    return path.join(_destinationFolders[category]!, tail);
  }

  static Future<String> _rewriteReference(
    String reference, {
    required File source,
    required File destination,
    required Directory sourceRoot,
    required Directory targetRoot,
  }) async {
    final filename = reference.replaceAll('\\', '/');
    final referenced = File(
      path.isAbsolute(filename)
          ? filename
          : path.join(source.parent.path, filename),
    );
    if (await FileSystemEntity.type(referenced.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException(
        'Referenced file is missing or is a symlink',
        reference,
      );
    }
    final resolvedRoot = await sourceRoot.resolveSymbolicLinks();
    final resolved = await referenced.resolveSymbolicLinks();
    if (!path.isWithin(resolvedRoot, resolved)) {
      throw FileSystemException(
        'Referenced file is outside the selected folder',
        reference,
      );
    }
    final mapped = _destinationForReference(
      path.relative(resolved, from: resolvedRoot),
    );
    if (mapped == null) {
      throw FileSystemException(
        'Referenced file belongs to excluded data',
        reference,
      );
    }
    // Relative references survive application-container path changes on update.
    return path.relative(
      path.join(targetRoot.path, mapped),
      from: destination.parent.path,
    );
  }

  static Future<String> _rewriteDiscManifest(
    String original, {
    required File source,
    required File destination,
    required Directory sourceRoot,
    required Directory targetRoot,
  }) async {
    final isCue = path.extension(source.path).toLowerCase() == '.cue';
    final lines = <String>[];
    for (final line in original.split('\n')) {
      if (isCue) {
        final match = RegExp(
          r'^(\s*FILE\s+)(?:"([^"]+)"|(\S+))(\s+.*)$',
          caseSensitive: false,
        ).firstMatch(line);
        if (match == null) {
          lines.add(line);
          continue;
        }
        final rebased = await _rewriteReference(
          match.group(2) ?? match.group(3)!,
          source: source,
          destination: destination,
          sourceRoot: sourceRoot,
          targetRoot: targetRoot,
        );
        lines.add('${match.group(1)}"$rebased"${match.group(4)}');
      } else {
        final value = line.trim();
        if (value.isEmpty || value.startsWith('#')) {
          lines.add(line);
          continue;
        }
        lines.add(
          await _rewriteReference(
            value,
            source: source,
            destination: destination,
            sourceRoot: sourceRoot,
            targetRoot: targetRoot,
          ),
        );
      }
    }
    return lines.join('\n');
  }

  static Future<String> _rewritePreset(
    String original, {
    required File source,
    required File destination,
    required Directory sourceRoot,
    required Directory targetRoot,
  }) async {
    final lines = <String>[];
    for (final line in original.split('\n')) {
      final match = RegExp(
        r'^(\s*[a-zA-Z0-9_]+\s*=\s*)(?:"([^"]+)"|(\S+))(\s*)$',
      ).firstMatch(line);
      final value = match?.group(2) ?? match?.group(3);
      final extension = value == null
          ? ''
          : path.extension(value).toLowerCase();
      if (match == null ||
          !const {
            '.png',
            '.jpg',
            '.jpeg',
            '.bmp',
            '.tga',
            '.webp',
            '.glsl',
            '.slang',
            '.glslp',
            '.slangp',
          }.contains(extension)) {
        lines.add(line);
        continue;
      }
      final rebased = await _rewriteReference(
        value!,
        source: source,
        destination: destination,
        sourceRoot: sourceRoot,
        targetRoot: targetRoot,
      );
      lines.add('${match.group(1)}"$rebased"${match.group(4)}');
    }
    return lines.join('\n');
  }

  static const _safeConfigurationKeys = {
    'video_vsync',
    'video_smooth',
    'video_scale_integer',
    'video_aspect_ratio_auto',
    'video_aspect_ratio',
    'video_shader_enable',
    'input_overlay_enable',
    'input_overlay_opacity',
    'input_overlay_scale',
    'input_overlay_hide_in_menu',
    'input_overlay_hide_when_gamepad_connected',
    'input_menu_toggle_gamepad_combo',
    'input_remap_binds_enable',
    'audio_volume',
    'audio_latency',
    'savestate_auto_save',
    'savestate_auto_load',
    'savestate_thumbnail_enable',
    'savestate_file_compression',
    'savefile_compression',
    'sort_savefiles_enable',
    'sort_savestates_enable',
    'sort_savefiles_by_content_enable',
    'sort_savestates_by_content_enable',
    'rewind_enable',
    'rewind_granularity',
    'cheat_apply_after_load',
  };
  static const _directoryKeys = {
    'system_directory': 'system',
    'savefile_directory': 'saves',
    'savestate_directory': 'states',
    'video_shader_dir': 'shaders',
    'overlay_directory': 'overlays',
    'cheat_database_path': 'cheats',
    'rgui_config_directory': 'config',
    'core_options_path': 'config/retroarch-core-options.cfg',
    'input_remapping_directory': 'config/remaps',
  };

  /// Preserve originals separately, and import only known host-safe settings.
  /// Executable paths, drivers, network commands/updaters and foreign absolute
  /// paths never become active. This is a derived copy, never a source rewrite.
  static String sanitizeConfiguration(
    String input, {
    required Directory targetRoot,
  }) {
    final result = <String>[];
    for (final line in input.split('\n')) {
      final match = RegExp(
        r'^\s*([a-zA-Z0-9_]+)\s*=\s*(.*?)\s*$',
      ).firstMatch(line);
      if (match == null) continue;
      final key = match.group(1)!;
      final value = match.group(2)!;
      if (_safeConfigurationKeys.contains(key)) {
        result.add('$key = $value');
      } else if (key == 'video_shader' || key == 'input_overlay') {
        final folder = key == 'video_shader' ? 'shaders' : 'overlays';
        final raw = value
            .replaceAll(RegExp(r'^"|"$'), '')
            .replaceAll('\\', '/');
        final marker = '/$folder/';
        final index = raw.lastIndexOf(marker);
        final tail = index >= 0
            ? raw.substring(index + marker.length)
            : raw.startsWith('$folder/')
            ? raw.substring(folder.length + 1)
            : null;
        if (tail != null &&
            tail.isNotEmpty &&
            !path.split(tail).contains('..')) {
          result.add('$key = "${path.join(targetRoot.path, folder, tail)}"');
        }
      }
    }
    for (final entry in _directoryKeys.entries) {
      result.add('${entry.key} = "${path.join(targetRoot.path, entry.value)}"');
    }
    return '${result.join('\n')}\n';
  }
}
