import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/diagnostics_directory.dart';
import 'package:neostation/services/ios_rom_library_root_resolver.dart';
import 'package:neostation/services/logger_service.dart';

/// Files-visible snapshot of the RetroArch library chain, rewritten after
/// each scan: Documents/Diagnostics/retroarch_library_report.txt.
///
/// It records what the app actually sees — bookmark, ROM roots, the folders
/// inside them and the stored rows — so an empty library can be traced to
/// its link, access, scan or display step without guessing.
abstract final class RetroArchLibraryReport {
  static final _log = LoggerService.instance;
  static const fileName = 'retroarch_library_report.txt';

  static Future<void> write(String reason, {List<String>? romFolders}) async {
    try {
      final file = await DiagnosticsDirectory.file(fileName);
      await file.writeAsString(await build(reason, romFolders: romFolders));
    } catch (e) {
      _log.e('RetroArch library report failed: $e');
    }
  }

  static Future<String> build(String reason, {List<String>? romFolders}) async {
    final out = StringBuffer()
      ..writeln('time: ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln('reason: $reason');
    final systems = await SqliteConfigService.loadAvailableSystems();
    final systemFolders = {
      for (final system in systems)
        for (final name in [system.folderName, ...system.folders])
          name.toLowerCase(),
    };
    out.writeln('userDataPath: ${await ConfigService.getUserDataPath()}');

    final linked = ConfigService.linkedExternalFolderPath;
    final registered = romFolders ?? await SqliteService.getUserRomFolders();
    out.writeln('retroarchBookmark: ${linked ?? '<none>'}');
    if (linked != null) {
      out.writeln('  ${await describeFolder(linked, systemFolders)}');
      final scanRoot = await IosRomLibraryRootResolver.resolveRetroArchScanRoot(
        linkedRoot: linked,
        systemFolderNames: systemFolders,
      );
      out.writeln(
        'resolvedScanRoot: $scanRoot registered=${registered.contains(scanRoot)}',
      );
    }

    out.writeln('romFolders (${registered.length}):');
    for (final folder in registered) {
      out
        ..writeln('- $folder')
        ..writeln('  ${await describeFolder(folder, systemFolders)}');
    }

    final db = await SqliteService.getDatabase();
    final total = await db.rawQuery('SELECT COUNT(*) AS n FROM user_roms');
    out.writeln('user_roms: ${total.first['n']}');
    final perSystem = await db.rawQuery(
      'SELECT app_system_id AS id, COUNT(*) AS n FROM user_roms '
      'GROUP BY app_system_id ORDER BY n DESC LIMIT 40',
    );
    out.writeln(
      'romsPerSystem: ${perSystem.map((r) => '${r['id']}=${r['n']}').join(', ')}',
    );
    final detected = await db.rawQuery(
      'SELECT app_system_id AS id, is_hidden AS hidden '
      'FROM user_detected_systems ORDER BY app_system_id',
    );
    out.writeln(
      'detectedSystems (${detected.length}): '
      '${detected.map((r) => r['hidden'] == 1 ? '${r['id']}(hidden)' : '${r['id']}').join(', ')}',
    );
    final samples = await db.rawQuery(
      'SELECT rom_path FROM user_roms ORDER BY rowid DESC LIMIT 5',
    );
    out.writeln('latestRomPaths:');
    for (final row in samples) {
      out.writeln('- ${row['rom_path']}');
    }
    return out.toString();
  }

  /// Existence, readability and the system folders found directly inside.
  static Future<String> describeFolder(
    String folder,
    Set<String> systemFolders,
  ) async {
    final directory = Directory(folder);
    if (!await directory.exists()) return 'exists=false';
    try {
      final children = await directory.list(followLinks: false).toList();
      final names = children
          .whereType<Directory>()
          .map((child) => path.basename(child.path))
          .toList()
        ..sort();
      final matched = names
          .where((name) => systemFolders.contains(name.toLowerCase()))
          .toList();
      final files = children.whereType<File>().length;
      return 'exists=true directories=${names.length} files=$files '
          'systemFolders=$matched otherFolders=${names.where((n) => !matched.contains(n)).take(15).toList()}';
    } catch (e) {
      return 'exists=true readable=false error=$e';
    }
  }
}
