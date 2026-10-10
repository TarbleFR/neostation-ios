import 'dart:io';

import 'package:path/path.dart' as path;

import 'libretro_core_catalog.dart';
import 'logger_service.dart';

/// Outcome of [NeoStationRomLibrary.moveLibrary].
class RomLibraryMove {
  const RomLibraryMove({
    this.moved = 0,
    this.alreadyPresent = 0,
    this.notRemoved = 0,
    this.failed = 0,
  });

  /// Games now in NeoStation's library and gone from the source.
  final int moved;

  /// Games left in the source because the same file (name and size) was
  /// already in NeoStation's library.
  final int alreadyPresent;

  /// Games copied into NeoStation's library whose original could not be
  /// removed: they are in both places.
  final int notRemoved;

  /// Games that could not be moved (left in the source only).
  final int failed;

  int get total => moved + alreadyPresent + notRemoved + failed;

  /// Every game of the source is in NeoStation's library: the source folder
  /// is no longer needed.
  bool get complete => failed == 0;
}

/// NeoStation's own ROM library on iOS: Files › On My iPhone › NeoStation ›
/// roms, one folder per console. NeoStation and its embedded engine read it
/// without any folder grant.
abstract final class NeoStationRomLibrary {
  static final _log = LoggerService.instance;

  /// The folder of each console the embedded engine runs, named as the
  /// scanner knows it (the system games are imported into).
  static List<String> consoleFolders() =>
      {for (final console in LibretroCoreCatalog.consoles.values) console.importSystem.toLowerCase()}.toList()
        ..sort();

  /// Creates `<romsRoot>/<console>` for every console of the embedded engine;
  /// existing folders and their games are kept. Returns the folders created.
  static Future<int> createConsoleFolders(String romsRoot) async {
    var created = 0;
    for (final folder in consoleFolders()) {
      final directory = Directory(path.join(romsRoot, folder));
      if (await directory.exists()) continue;
      await directory.create(recursive: true);
      created++;
    }
    return created;
  }

  /// Moves the games of [sourceRoot] into [romsRoot], keeping their place:
  /// `<sourceRoot>/<console>/<path>` becomes `<romsRoot>/<console>/<path>`.
  /// Only the console folders of the source are moved (a child folder whose
  /// name, ignoring case, is in [consoleFolderNames]); hidden files (iCloud
  /// placeholders of files not downloaded) are counted as not moved.
  ///
  /// A file already in the library with the same name and size is left in
  /// the source; one with the same name and another size is moved as
  /// "name (2).ext". Each file is renamed (same volume, instant); when the
  /// system refuses, it is copied, checked by size, then its original is
  /// deleted with [deleteSource] (default: File.delete).
  static Future<RomLibraryMove> moveLibrary({
    required String sourceRoot,
    required String romsRoot,
    required Set<String> consoleFolderNames,
    void Function(int done, int total)? onProgress,
    Future<void> Function(String filePath)? deleteSource,
  }) async {
    final source = path.normalize(sourceRoot);
    final destination = path.normalize(romsRoot);
    if (source == destination || path.isWithin(destination, source) || path.isWithin(source, destination)) {
      return const RomLibraryMove();
    }
    final names = {for (final name in consoleFolderNames) name.trim().toLowerCase()};
    final files = <File>[];
    var failed = 0;
    await for (final entity in Directory(source).list(followLinks: false)) {
      if (entity is! Directory || !names.contains(path.basename(entity.path).trim().toLowerCase())) continue;
      await for (final item in entity.list(recursive: true, followLinks: false)) {
        if (item is! File) continue;
        if (path.basename(item.path).startsWith('.')) {
          if (item.path.endsWith('.icloud')) failed++;
          continue;
        }
        files.add(item);
      }
    }
    final remove = deleteSource ?? (filePath) => File(filePath).delete();
    var moved = 0;
    var alreadyPresent = 0;
    var notRemoved = 0;
    final total = files.length + failed;
    onProgress?.call(failed, total);
    for (final file in files) {
      try {
        final length = await file.length();
        var target = File(path.join(destination, path.relative(file.path, from: source)));
        if (await target.exists()) {
          if (await target.length() == length) {
            alreadyPresent++;
            continue;
          }
          target = await _unique(target);
        }
        await target.parent.create(recursive: true);
        try {
          await file.rename(target.path);
          moved++;
        } on FileSystemException {
          final copied = await file.copy(target.path);
          if (await copied.length() != length) {
            await copied.delete();
            failed++;
            continue;
          }
          try {
            await remove(file.path);
            moved++;
          } catch (error) {
            _log.w('Library move kept the original of ${file.path}: $error');
            notRemoved++;
          }
        }
      } catch (error) {
        _log.w('Library move skipped ${file.path}: $error');
        failed++;
      } finally {
        onProgress?.call(moved + alreadyPresent + notRemoved + failed, total);
      }
    }
    _log.i(
      'Library moved from $source to $destination: moved=$moved alreadyPresent=$alreadyPresent '
      'notRemoved=$notRemoved failed=$failed',
    );
    return RomLibraryMove(moved: moved, alreadyPresent: alreadyPresent, notRemoved: notRemoved, failed: failed);
  }

  static Future<File> _unique(File file) async {
    final base = path.basenameWithoutExtension(file.path);
    final extension = path.extension(file.path);
    var index = 2;
    var candidate = file;
    while (await candidate.exists()) {
      candidate = File(path.join(file.parent.path, '$base ($index)$extension'));
      index++;
    }
    return candidate;
  }
}
