import 'dart:io';

import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/armsx2_folder_service.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/stikjit_armsx2_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Launch integration for ARMSX2 on iOS.
///
/// ARMSX2 library discovery no longer depends on an exported-library callback
/// or cache. NeoStation scans the physical PS2 library derived from the single
/// `armsx2` security-scoped bookmark, while this service is responsible only
/// for handing an ARMSX2-owned game directly to the embedded Core/JIT path.
class Armsx2LibraryService {
  Armsx2LibraryService._();

  static final _log = LoggerService.instance;

  static const String _virtualScheme = 'armsx2';
  static const String _legacyExportCacheKey = 'armsx2_library_cache_v1';

  /// True for a legacy NeoStation row backed by an ARMSX2 direct-launch URL.
  ///
  /// These rows are recognized only for migration cleanup; new library scans
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
      _log.w(
        'ARMSX2 legacy URL row is retired; rescan the linked PS2 folder '
        'to obtain a physical path.',
      );
      return false;
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
    return StikJitArmsx2Service.launch(gamePath: path.normalize(romPath));
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
