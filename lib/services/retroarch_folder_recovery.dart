import 'dart:io';

import 'package:external_folder_access/external_folder_access.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/ios_rom_library_root_resolver.dart';
import 'package:neostation/services/logger_service.dart';

/// Rebases only the library belonging to RetroArch's actual bookmark. The
/// resolved grant is authoritative; guessing another app's container UUID is
/// never enough to move a library. No ROM or save file is moved or deleted.
abstract final class RetroArchFolderRecovery {
  static const rootKey = 'retroarch_bookmark_root_v1';

  static String? rebase(String value, String oldRoot, String newRoot) {
    final normalized = path.normalize(value);
    final old = path.normalize(oldRoot);
    if (normalized == old) return path.normalize(newRoot);
    if (!path.isWithin(old, normalized)) return null;
    return path.join(newRoot, path.relative(normalized, from: old));
  }

  static String? _documentsSuffix(String value) {
    final match = RegExp(
      r'^/(?:private/)?var/mobile/Containers/Data/Application/[^/]+/Documents(?:/(.*))?$',
    ).firstMatch(path.normalize(value));
    return match == null ? null : (match.group(1) ?? '');
  }

  /// Performs the same transactional path update used by production recovery.
  /// Keep row IDs, favorites, play time and metadata. A collision aborts the
  /// whole recovery, so an interrupted/repeated scan cannot discard metadata.
  static Future<void> relocate(
    DatabaseAdapter db,
    String oldRoot,
    String newRoot,
  ) async {
    await db.transaction((txn) async {
      final prefix = '${path.normalize(oldRoot)}/';
      final rows = await txn.rawQuery(
        'SELECT id, rom_path FROM user_roms WHERE rom_path = ? OR substr(rom_path, 1, ?) = ?',
        [path.normalize(oldRoot), prefix.length, prefix],
      );
      for (final row in rows) {
        final target = rebase(row['rom_path'] as String, oldRoot, newRoot)!;
        await txn.update(
          'user_roms',
          {'rom_path': target},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
      await txn.update(
        'user_rom_folders',
        {'path': newRoot},
        where: 'path = ?',
        whereArgs: [oldRoot],
      );
    });
  }

  static Future<List<String>> reconcile(
    List<String> roots,
    Iterable<String> systemFolders,
  ) async {
    if (!Platform.isIOS) return roots;
    final prefs = await SharedPreferences.getInstance();
    String? active;
    String? previous =
        prefs.getString(rootKey) ??
        ConfigService.linkedExternalFolderPreviousPath;
    try {
      final bookmark =
          await ExternalFolderAccess.resolveBookmarkedFolderDetails();
      previous ??= bookmark?.previousPath;
      active = bookmark?.path;
    } catch (error) {
      LoggerService.instance.w('RetroArch bookmark resolution failed: $error');
    }
    ConfigService.linkedExternalFolderPath = active;
    return reconcileResolved(
      roots: roots,
      systemFolders: systemFolders,
      active: active,
      previous: previous,
      db: await SqliteService.instance.database,
      prefs: prefs,
    );
  }

  /// Production recovery, independent of the native bookmark transport so the
  /// five-stale-folder case can run against real directories and SQLite.
  static Future<List<String>> reconcileResolved({
    required List<String> roots,
    required Iterable<String> systemFolders,
    required String? active,
    required String? previous,
    required DatabaseAdapter db,
    required SharedPreferences prefs,
  }) async {
    final updated = roots.toSet().toList();
    if (active == null) return updated;
    try {
      await Directory(active).list(followLinks: false).take(1).toList();
      final scanRoot = await IosRomLibraryRootResolver.resolveRetroArchScanRoot(
        linkedRoot: active,
        systemFolderNames: systemFolders,
      );
      final replacements = <String, String>{};
      if (previous != null &&
          _documentsSuffix(previous) == _documentsSuffix(active)) {
        for (final root in updated) {
          final target = rebase(root, previous, active);
          if (target == null ||
              path.normalize(target) == path.normalize(root)) {
            continue;
          }
          try {
            await Directory(target).list(followLinks: false).take(1).toList();
            replacements[root] = target;
          } on FileSystemException {
            // Retain inaccessible sources and their game metadata for recovery.
          }
        }
      }
      await db.transaction((txn) async {
        for (final entry in replacements.entries) {
          await relocate(txn, entry.key, entry.value);
        }
      });
      final recovered = updated
          .map((root) => replacements[root] ?? root)
          .toSet()
          .toList();
      // The bookmark is a managed source, independent of the five manual slots.
      // Never evict another source or silently refuse a newly selected folder.
      if (!recovered.contains(scanRoot)) recovered.add(scanRoot);
      await SqliteService.saveUserRomFolders(recovered);
      await prefs.setString(rootKey, active);
      return recovered;
    } catch (error) {
      LoggerService.instance.w(
        'RetroArch folder unavailable; keeping registered library: $error',
      );
      return updated;
    }
  }
}
