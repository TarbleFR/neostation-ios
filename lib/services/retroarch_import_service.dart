import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:external_folder_access/external_folder_access.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;

import 'retroarch_core_catalog.dart';
import 'retroarch_internal_service.dart';
import 'retroarch_data_migration.dart';

class RetroArchImportResult {
  const RetroArchImportResult({
    this.imported = 0,
    this.skipped = 0,
    this.errors = const [],
  });
  final int imported;
  final int skipped;
  final List<String> errors;
}

/// Files-visible imports preserve sidecars, original sources and old copies.
abstract final class RetroArchImportService {
  static bool _busy = false;
  static const _sourceBookmark = 'retroarch_embedded_import';
  static Set<String> get _gameExtensions => {
    ...RetroArchCoreCatalog.recognizedGameExtensions,
    // Disc descriptors need their payload and sidecars preserved together.
    'bin', 'img', 'sub', 'cue', 'ccd', 'toc', 'm3u', 'mds', 'mdf',
    'zip', '7z',
  };

  static Future<RetroArchImportResult> importFiles({
    required String systemFolder,
    bool bios = false,
    bool replace = false,
  }) async {
    _requireSystem(systemFolder);
    final selection = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.any,
      withData: false,
      lockParentWindow: true,
    );
    if (selection == null) return const RetroArchImportResult();
    final destination = bios
        ? await RetroArchInternalService.systemDirectory()
        : await RetroArchInternalService.gamesDirectory(systemFolder);
    return copyFiles(
      files: selection.files
          .where((file) => file.path != null)
          .map((file) => File(file.path!))
          .toList(),
      destination: destination,
      bios: bios,
      replace: replace,
    );
  }

  static Future<RetroArchImportResult> importFolder({
    required String systemFolder,
    bool bios = false,
    bool replace = false,
  }) async {
    _requireSystem(systemFolder);
    final sourcePath = await ExternalFolderAccess.pickAndActivateFolder(
      key: _sourceBookmark,
    );
    if (sourcePath == null) return const RetroArchImportResult();
    try {
      final source = Directory(sourcePath);
      final destination = bios
          ? await RetroArchInternalService.systemDirectory()
          : Directory(
              path.join(
                (await RetroArchInternalService.gamesDirectory(
                  systemFolder,
                )).path,
                path.basename(sourcePath),
              ),
            );
      final resolvedSource = await source.resolveSymbolicLinks();
      final resolvedDestination = await _canonicalPlannedDirectory(destination);
      if (resolvedSource == resolvedDestination ||
          path.isWithin(resolvedSource, resolvedDestination) ||
          path.isWithin(resolvedDestination, resolvedSource)) {
        throw StateError('RETROARCH_IMPORT_OVERLAPPING_DIRECTORIES');
      }
      final files = <File>[];
      await for (final item in source.list(
        recursive: true,
        followLinks: false,
      )) {
        if (item is File) files.add(item);
      }
      return await copyFiles(
        files: files,
        sourceRoot: source,
        preserveSidecars: !bios,
        destination: destination,
        bios: bios,
        replace: replace,
      );
    } finally {
      await ExternalFolderAccess.clearBookmark(key: _sourceBookmark);
    }
  }

  static Future<String> _canonicalPlannedDirectory(Directory directory) async {
    var current = path.normalize(path.absolute(directory.path));
    final missing = <String>[];
    while (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.notFound) {
      missing.add(path.basename(current));
      final parent = path.dirname(current);
      if (parent == current) {
        throw FileSystemException(
          'Missing destination ancestor',
          directory.path,
        );
      }
      current = parent;
    }
    return path.joinAll([
      await Directory(current).resolveSymbolicLinks(),
      ...missing.reversed,
    ]);
  }

  static Future<void> _safeCreateParent(String root, String target) async {
    if (!path.isWithin(root, target)) {
      throw StateError('RETROARCH_IMPORT_OUTSIDE_DESTINATION');
    }
    var current = root;
    for (final segment in path.split(
      path.relative(path.dirname(target), from: root),
    )) {
      if (segment == '.') continue;
      current = path.join(current, segment);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        throw StateError('RETROARCH_IMPORT_DESTINATION_SYMLINK');
      }
      if (type == FileSystemEntityType.notFound) {
        await Directory(current).create();
      }
    }
  }

  static void _requireSystem(String folder) {
    if (!RetroArchCoreCatalog.supportsSystem(folder)) {
      throw ArgumentError.value(folder, 'systemFolder');
    }
  }

  /// Public for real-file behavioral verification without a document picker.
  static Future<RetroArchImportResult> copyFiles({
    required List<File> files,
    required Directory destination,
    Directory? sourceRoot,
    bool preserveSidecars = false,
    bool bios = false,
    bool replace = false,
  }) async {
    if (_busy) throw StateError('RETROARCH_IMPORT_BUSY');
    _busy = true;
    var imported = 0;
    var skipped = 0;
    final errors = <String>[];
    try {
      final origin = await sourceRoot?.resolveSymbolicLinks();
      final plannedTarget = await _canonicalPlannedDirectory(destination);
      if (origin != null &&
          (path.equals(origin, plannedTarget) ||
              path.isWithin(origin, plannedTarget) ||
              path.isWithin(plannedTarget, origin))) {
        throw StateError('RETROARCH_IMPORT_OVERLAPPING_DIRECTORIES');
      }
      if (await FileSystemEntity.type(destination.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('RETROARCH_IMPORT_DESTINATION_SYMLINK');
      }
      await destination.create(recursive: true);
      final targetRoot = await destination.resolveSymbolicLinks();
      for (final source in files) {
        File? staged;
        File? backup;
        File? target;
        try {
          if (await FileSystemEntity.type(source.path, followLinks: false) !=
              FileSystemEntityType.file) {
            throw StateError('RETROARCH_IMPORT_NONREGULAR_SOURCE');
          }
          final resolved = await source.resolveSymbolicLinks();
          if (origin != null && !path.isWithin(origin, resolved)) {
            throw StateError('RETROARCH_IMPORT_OUTSIDE_SOURCE');
          }
          if (await RetroArchDataMigration.isExecutableFile(
                source,
                includePortableExecutables: bios,
              ) ||
              path
                  .split(source.path)
                  .any(
                    (segment) => segment.toLowerCase().endsWith('.framework'),
                  ) ||
              path.basename(source.path).toLowerCase().contains('_libretro')) {
            skipped++;
            continue;
          }
          final extension = path
              .extension(source.path)
              .replaceFirst('.', '')
              .toLowerCase();
          if (const {'dylib', 'so', 'dll', 'ipa', 'a'}.contains(extension) ||
              (bios && const {'exe', 'o'}.contains(extension)) ||
              (!bios &&
                  !preserveSidecars &&
                  !_gameExtensions.contains(extension))) {
            skipped++;
            continue;
          }
          final relative = origin == null
              ? path.basename(source.path)
              : path.relative(resolved, from: origin);
          final targetPath = path.normalize(path.join(targetRoot, relative));
          if (!path.isWithin(targetRoot, targetPath)) {
            throw StateError('RETROARCH_IMPORT_OUTSIDE_DESTINATION');
          }
          target = File(targetPath);
          if (path.equals(resolved, targetPath)) {
            skipped++;
            continue;
          }
          await _safeCreateParent(targetRoot, targetPath);
          final parent = await target.parent.resolveSymbolicLinks();
          if (parent != targetRoot && !path.isWithin(targetRoot, parent)) {
            throw StateError('RETROARCH_IMPORT_DESTINATION_SYMLINK');
          }
          final targetType = await FileSystemEntity.type(
            targetPath,
            followLinks: false,
          );
          if (targetType != FileSystemEntityType.notFound &&
              targetType != FileSystemEntityType.file) {
            throw StateError('RETROARCH_IMPORT_NONREGULAR_DESTINATION');
          }
          if (targetType == FileSystemEntityType.file && !replace) {
            skipped++;
            continue;
          }
          final stamp = DateTime.now().microsecondsSinceEpoch;
          staged = File('$targetPath.neostation-import-$stamp.partial');
          await source.copy(staged.path);
          if (await source.length() != await staged.length() ||
              await sha256.bind(source.openRead()).first !=
                  await sha256.bind(staged.openRead()).first) {
            throw StateError('RETROARCH_IMPORT_COPY_MISMATCH');
          }
          await _safeCreateParent(targetRoot, targetPath);
          final latestType = await FileSystemEntity.type(
            targetPath,
            followLinks: false,
          );
          if (latestType != FileSystemEntityType.notFound &&
              latestType != FileSystemEntityType.file) {
            throw StateError('RETROARCH_IMPORT_NONREGULAR_DESTINATION');
          }
          if (latestType == FileSystemEntityType.file && !replace) {
            skipped++;
            continue;
          }
          if (latestType == FileSystemEntityType.file) {
            final previousDigest = await sha256.bind(target.openRead()).first;
            final backupRoot = Directory(
              path.join(targetRoot, '.import-backups', '$stamp'),
            );
            // The scanner must not rediscover old game files as new games.
            backup = File(path.join(backupRoot.path, '$relative.backup'));
            await _safeCreateParent(targetRoot, backup.path);
            await target.rename(backup.path);
            if (await sha256.bind(backup.openRead()).first != previousDigest) {
              throw StateError('RETROARCH_IMPORT_BACKUP_MISMATCH');
            }
          }
          await staged.rename(target.path);
          imported++;
        } catch (error) {
          if (backup != null &&
              target != null &&
              await backup.exists() &&
              !await target.exists()) {
            await backup.rename(target.path);
          }
          errors.add('${path.basename(source.path)}: $error');
        } finally {
          if (staged != null && await staged.exists()) await staged.delete();
        }
      }
      return RetroArchImportResult(
        imported: imported,
        skipped: skipped,
        errors: errors,
      );
    } finally {
      _busy = false;
    }
  }
}
