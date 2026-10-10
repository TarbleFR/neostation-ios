import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../data/datasources/sqlite_service.dart';
import 'logger_service.dart';

/// Finds the registered ROM folders again after iOS moved an app container.
///
/// ROM folders are stored as absolute paths, and an app's data container
/// lives at `.../Containers/Data/Application/<UUID>/`. When NeoStation (or
/// the app whose folder was linked) is reinstalled or updated, iOS can give
/// it a new UUID: the files are still there, but the stored path no longer
/// opens, the scanner finds no console and the library looks empty until
/// the folder is picked again, which only added the new path next to the
/// dead one (seven saved folders on 9 October 2026, several in containers
/// that no longer existed).
///
/// At startup, before the configuration is read, each registered folder
/// that no longer opens and lies in an app container is looked for at the
/// same place in the current containers: NeoStation's own first, then the
/// container of the linked folder (its security-scoped bookmark follows the
/// folder). A folder found there replaces the dead path; one found nowhere
/// is kept as it is (it may only be unavailable for now). No file is moved
/// and no game row is rewritten: the scanner indexes the folder at its new
/// path, as after picking the folder again by hand.
abstract final class IosLibraryRootRelocation {
  static final _log = LoggerService.instance;

  static final RegExp _appContainer = RegExp(
    r'^((?:/private)?/var/mobile/Containers/(?:Data/Application|Shared/AppGroup)/[0-9A-Fa-f-]{36})(?:/(.*))?$',
  );

  /// Whether this launch replaced a registered folder.
  static bool relocatedThisLaunch = false;

  /// The container of [folder] and its path inside it; null outside an iOS
  /// app container.
  static ({String container, String relative})? split(String folder) {
    final match = _appContainer.firstMatch(path.posix.normalize(folder));
    if (match == null) return null;
    return (container: match.group(1)!, relative: match.group(2) ?? '');
  }

  /// [registered] with each folder that no longer opens replaced by the same
  /// folder in one of [containers] (in that order) when it exists there;
  /// duplicates are dropped. Null when nothing changes.
  static Future<List<String>?> relocate(
    List<String> registered, {
    required List<String> containers,
    Future<bool> Function(String folder)? exists,
  }) async {
    final reachable = exists ?? (folder) => Directory(folder).exists();
    final folders = <String>[];
    var changed = false;
    for (final folder in registered) {
      var chosen = folder;
      final parts = split(folder);
      if (parts != null && parts.relative.isNotEmpty && !await reachable(folder)) {
        for (final container in containers) {
          if (container == parts.container) continue;
          final candidate = '$container/${parts.relative}';
          if (await reachable(candidate)) {
            chosen = candidate;
            break;
          }
        }
      }
      if (chosen != folder) changed = true;
      if (folders.contains(chosen)) {
        changed = true;
      } else {
        folders.add(chosen);
      }
    }
    return changed ? folders : null;
  }

  /// Runs once at startup, after the linked folder's bookmark was resolved
  /// ([linkedFolder], null when none) and before the configuration provider
  /// reads the ROM folders.
  static Future<void> run({String? linkedFolder}) async {
    try {
      final containers = <String>[];
      final own = split((await getApplicationDocumentsDirectory()).path)?.container;
      if (own != null) containers.add(own);
      final linked = linkedFolder == null ? null : split(linkedFolder)?.container;
      if (linked != null && !containers.contains(linked)) containers.add(linked);
      if (containers.isEmpty) return;
      final registered = await SqliteService.getUserRomFolders();
      final folders = await relocate(registered, containers: containers);
      if (folders == null) return;
      await SqliteService.saveUserRomFolders(folders);
      relocatedThisLaunch = true;
      _log.i(
        'Library folders found again after a container move: '
        '${registered.where((folder) => !folders.contains(folder)).toList()} -> '
        '${folders.where((folder) => !registered.contains(folder)).toList()}',
      );
    } catch (error) {
      _log.e('Library folder relocation failed: $error');
    }
  }
}
