import 'dart:io';

import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/armsx2_folder_service.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/ios_shortcut_jit_launch_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Launch integration for ARMSX2 on iOS.
///
/// ARMSX2 library discovery no longer depends on an exported-library callback
/// or cache. NeoStation scans the physical PS2 library derived from the single
/// `armsx2` security-scoped bookmark, while this service is responsible only
/// for handing an ARMSX2-owned game to the existing Shortcut/JIT launch path.
class Armsx2LibraryService {
  Armsx2LibraryService._();

  static final _log = LoggerService.instance;

  static const String _virtualScheme = 'armsx2';
  static const String _legacyExportCacheKey = 'armsx2_library_cache_v1';

  /// True for a legacy NeoStation row backed by an ARMSX2 direct-launch URL.
  ///
  /// These rows are kept launchable during migration, but new library scans
  /// always create normal physical rows from the linked ARMSX2 root.
  static bool isVirtualLibraryPath(String romPath) {
    final uri = Uri.tryParse(romPath);
    if (uri == null || uri.scheme.toLowerCase() != _virtualScheme) {
      return false;
    }
    final route = <String>{
      if (uri.host.isNotEmpty) uri.host.toLowerCase(),
      ...uri.pathSegments.map((segment) => segment.toLowerCase()),
    };
    return route.contains('launch') ||
        route.contains('boot') ||
        route.contains('play');
  }

  /// Launches a PS2 game only when it belongs to the ARMSX2 bookmark, or when
  /// it is a legacy ARMSX2 virtual row awaiting cleanup.
  static Future<bool> launchGameByRomPath(String romPath) async {
    if (romPath.trim().isEmpty) return false;

    if (isVirtualLibraryPath(romPath)) {
      try {
        final uri = _normalizeLegacyVirtualUri(romPath);
        return await _runShortcut(
          uri,
          source: 'legacy ARMSX2 virtual row',
          romPath: romPath,
        );
      } catch (e) {
        _log.e('Armsx2LibraryService: legacy virtual launch failed: $e');
        return false;
      }
    }

    final ownsLinkedPhysicalRom = Armsx2FolderService.ownsRomPath(
      romPath,
      ConfigService.linkedArmsx2FolderPath,
    );
    if (!ownsLinkedPhysicalRom) {
      await _writeDebugFile(
        'armsx2_launch_debug.txt',
        'romPath: $romPath\nnot owned by the linked ARMSX2 root',
      );
      return false;
    }

    return _launchLinkedPhysicalRom(romPath);
  }

  /// Removes data belonging to the retired ARMSX2 exported-library mechanism.
  ///
  /// The SharedPreferences cache and old sync diagnostic are always safe to
  /// remove. Legacy virtual database rows are removed only after NeoStation has
  /// successfully indexed at least one physical PS2 game inside the currently
  /// linked ARMSX2 root, so an upgrade can never erase the user's only visible
  /// PS2 library before the replacement scan is ready.
  static Future<int> cleanupLegacyExportArtifacts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_legacyExportCacheKey);
    } catch (e) {
      _log.w('ARMSX2 legacy cache cleanup failed: $e');
    }

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final oldSyncLog = File(path.join(docsDir.path, 'armsx2_sync_debug.txt'));
      if (await oldSyncLog.exists()) await oldSyncLog.delete();
    } catch (e) {
      _log.w('ARMSX2 legacy sync-log cleanup failed: $e');
    }

    final root = ConfigService.linkedArmsx2FolderPath;
    final gameRoot = ConfigService.linkedArmsx2GameFolderPath;
    if (root == null ||
        root.trim().isEmpty ||
        gameRoot == null ||
        gameRoot.trim().isEmpty) {
      return 0;
    }

    try {
      final ps2 = await SystemRepository.getSystemByFolderName('ps2');
      if (ps2?.id == null) return 0;

      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery(
        'SELECT rom_path FROM user_roms WHERE app_system_id = ?',
        [ps2!.id!],
      );

      final hasIndexedPhysicalArmsx2Game = rows.any((row) {
        final romPath = row['rom_path']?.toString();
        return romPath != null &&
            romPath.isNotEmpty &&
            !isVirtualLibraryPath(romPath) &&
            Armsx2FolderService.ownsRomPath(romPath, root);
      });
      if (!hasIndexedPhysicalArmsx2Game) return 0;

      final removed = await db.rawDelete(
        "DELETE FROM user_roms WHERE app_system_id = ? AND lower(rom_path) LIKE 'armsx2://%'",
        [ps2.id!],
      );
      if (removed > 0) {
        _log.i('Removed $removed legacy ARMSX2 exported-library row(s).');
      }
      return removed;
    } catch (e) {
      // Migration cleanup must never make app startup fail.
      _log.w('ARMSX2 legacy virtual-row cleanup failed: $e');
      return 0;
    }
  }

  static Future<bool> _launchLinkedPhysicalRom(String romPath) async {
    final fileName = path.basename(romPath);
    if (fileName.isEmpty) return false;
    final uri = _launchUriForFileName(fileName);
    return _runShortcut(
      uri,
      source: 'linked ARMSX2 physical root',
      romPath: romPath,
    );
  }

  static Uri _launchUriForFileName(String fileName) {
    // ARMSX2 treats '+' literally in its `game` query value. Percent encoding
    // keeps spaces as `%20` and an actual plus sign as `%2B`.
    final encodedFileName = Uri.encodeComponent(fileName);
    return Uri.parse('armsx2://launch?game=$encodedFileName');
  }

  static Uri _normalizeLegacyVirtualUri(String romPath) {
    final parsed = Uri.parse(romPath);
    final fileName = parsed.queryParameters['game'];
    if (fileName == null || fileName.isEmpty) return parsed;
    return _launchUriForFileName(fileName);
  }

  static Future<bool> _runShortcut(
    Uri uri, {
    required String source,
    required String romPath,
  }) async {
    try {
      await _writeDebugFile(
        'armsx2_shortcut_launch_debug.txt',
        'STATE: SHORTCUT_REQUESTED\n'
            'Shortcut: ${IosShortcutJitLaunchService.armsx2ShortcutName}\n'
            'Game URL: $uri\n'
            'Source: $source\n'
            'ROM: $romPath',
      );
      return await IosShortcutJitLaunchService.run(
        shortcutName: IosShortcutJitLaunchService.armsx2ShortcutName,
        input: uri.toString(),
      );
    } catch (e) {
      _log.e('Armsx2LibraryService: launch failed for $uri: $e');
      await _writeDebugFile(
        'armsx2_shortcut_launch_debug.txt',
        'STATE: ERROR\n'
            'Shortcut: ${IosShortcutJitLaunchService.armsx2ShortcutName}\n'
            'Game URL: $uri\n'
            'Source: $source\n'
            'ROM: $romPath\n'
            'Error: $e',
      );
      return false;
    }
  }

  /// Device-readable diagnostics for sideloaded iOS builds where an Xcode
  /// console is not available.
  static Future<void> _writeDebugFile(String name, String content) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final file = File(path.join(docsDir.path, name));
      await file.writeAsString('--- ${DateTime.now()} ---\n$content');
    } catch (e) {
      _log.e('Armsx2LibraryService: failed writing debug file $name: $e');
    }
  }
}
