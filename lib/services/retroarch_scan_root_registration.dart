import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/ios_rom_library_root_resolver.dart';
import 'package:neostation/services/logger_service.dart';

/// Keeps the RetroArch library registered as a ROM scan root.
///
/// ROM roots are stored as absolute paths. When RetroArch's iOS container
/// moves (update, reinstall), its bookmark resolves to the new location but
/// the scanner keeps walking the old root and prunes every RetroArch game.
/// The resolved root is therefore registered again, at startup and when the
/// folder is linked. A registered folder is dropped only when it is the same
/// container-relative folder and is no longer reachable (an older container,
/// or the whitespace-trimmed spelling of a folder such as `Bibliothèques `).
/// Every other folder is kept; ROM rows are left to the existing scanner.
abstract final class RetroArchScanRootRegistration {
  static final _log = LoggerService.instance;

  static final RegExp _appContainer = RegExp(
    r'^(?:/private)?/var/mobile/Containers/(?:Data/Application|Shared/AppGroup)/[0-9A-Fa-f-]{36}/(.+)$',
  );

  /// Path inside its iOS app container, ignoring whitespace around each
  /// segment. Null outside an app container: no identity is inferred there.
  static String? _containerRelativeFolder(String folder) {
    final match = _appContainer.firstMatch(path.posix.normalize(folder));
    if (match == null) return null;
    final segments = match
        .group(1)!
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty);
    return segments.isEmpty ? null : segments.join('/');
  }

  static bool isSameFolder(String registered, String linked) {
    final folder = _containerRelativeFolder(registered);
    return folder != null && folder == _containerRelativeFolder(linked);
  }

  static Future<bool> _exists(String folder) => Directory(folder).exists();

  /// The registered folders to keep, followed by [scanRoot].
  static Future<List<String>> foldersAfterLink(
    List<String> registered,
    String scanRoot, {
    Future<bool> Function(String folder)? exists,
  }) async {
    final reachable = exists ?? _exists;
    final kept = <String>[];
    for (final folder in registered) {
      if (folder == scanRoot) continue;
      if (isSameFolder(folder, scanRoot) && !await reachable(folder)) continue;
      kept.add(folder);
    }
    return [...kept, scanRoot];
  }

  /// Null when [scanRoot] is already registered or cannot be read, so a
  /// startup pass never registers a folder the bookmark does not open.
  static Future<List<String>?> foldersAtStartup(
    List<String> registered,
    String scanRoot, {
    Future<bool> Function(String folder)? exists,
  }) async {
    final reachable = exists ?? _exists;
    if (registered.contains(scanRoot) || !await reachable(scanRoot)) {
      return null;
    }
    return foldersAfterLink(registered, scanRoot, exists: reachable);
  }

  /// Runs once after the RetroArch bookmark is resolved and before the
  /// configuration provider reads its ROM roots for the startup scan.
  static Future<void> registerResolvedBookmark(String linkedRoot) async {
    try {
      // Same database definitions as the scanner; the asset loader in
      // ConfigService has no bundled systems file on iOS.
      final systems = await SqliteConfigService.loadAvailableSystems();
      final scanRoot = await IosRomLibraryRootResolver.resolveRetroArchScanRoot(
        linkedRoot: linkedRoot,
        systemFolderNames: systems.expand(
          (system) => <String>[system.folderName, ...system.folders],
        ),
      );
      final registered = await SqliteService.getUserRomFolders();
      final folders = await foldersAtStartup(registered, scanRoot);
      if (folders == null) return;
      await SqliteService.saveUserRomFolders(folders);
      _log.i(
        'RetroArch startup root registered: $scanRoot '
        'replacedUnreachable=${registered.where((f) => !folders.contains(f)).toList()}',
      );
    } catch (e) {
      _log.e('RetroArch startup root registration failed: $e');
    }
  }
}
