import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:path/path.dart' as path;

/// Restores the exported catalog without requiring an external filesystem grant.
/// Virtual rows keep an exact RetroArch identity across iOS container changes.
abstract final class RetroArchLibraryImporter {
  static String _key(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static String libraryPath(String system, String filename) => Uri(
    scheme: 'retroarch-library',
    host: 'game',
    pathSegments: [system, filename],
  ).toString();

  static Future<int> restore(
    DatabaseAdapter db,
    Iterable<Map<String, dynamic>> entries, {
    Iterable<String> ownedRoots = const [],
  }) async {
    final systems = await db.query('app_systems');
    final aliases = await db.query('app_system_folders');
    final names = <String, Set<String>>{};
    final folders = <String, String>{};
    void add(String name, String id) {
      final key = _key(name);
      if (key.isNotEmpty) names.putIfAbsent(key, () => {}).add(id);
    }

    for (final system in systems) {
      final id = system['id'].toString();
      final folder = system['folder_name'].toString();
      // These playlists belong to embedded engines with independent launch
      // ownership. Exposing them never hands their games to RetroArch.
      if (const {'gc', 'wii', 'ps3', 'ports', 'switch'}.contains(folder)) {
        continue;
      }
      folders[id] = folder;
      for (final column in ['real_name', 'short_name', 'folder_name']) {
        final value = system[column]?.toString() ?? '';
        add(value, id);
        add('${system['manufacturer'] ?? ''} $value', id);
      }
    }
    for (final alias in aliases) {
      final id = alias['system_id'].toString();
      if (folders.containsKey(id)) add(alias['folder_name'].toString(), id);
    }
    // Optional, backed-up repair bindings established from full .lpl paths.
    // Never infer these bindings from a basename or a title.
    final hasRepair = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='user_retroarch_repair_v1'",
    )).isNotEmpty;
    final repairedPaths = <String, String>{};
    if (hasRepair) {
      for (final row in await db.query('user_retroarch_repair_v1')) {
        repairedPaths[row['source_path'] as String] =
            row['target_path'] as String;
      }
    }
    final known = await db.query('user_roms');
    final physicalIdentities = known
        .where((row) {
          final romPath = row['rom_path'].toString();
          return ownedRoots.any((root) => path.isWithin(root, romPath));
        })
        .map((row) => (row['app_system_id'], row['filename']))
        .toSet();
    final identities = <String>{};
    var restored = 0;
    await db.transaction((txn) async {
      for (final entry in entries) {
        final filename = (entry['filename'] ?? entry['titleId'])?.toString();
        final system = entry['system']?.toString() ?? '';
        if (filename == null || filename.isEmpty || system.isEmpty) continue;
        final candidates =
            names[_key(system)] ?? names[_key(system.split(' - ').last)];
        if (candidates == null || candidates.length != 1) continue;
        final id = candidates.single;
        final virtualPath = libraryPath(system, filename);
        if (!identities.add(virtualPath)) continue;
        final repairedPath = repairedPaths[virtualPath];
        if (repairedPath != null) {
          final target = await txn.query(
            'user_roms',
            where: 'rom_path = ?',
            whereArgs: [repairedPath],
          );
          if (target.isEmpty) {
            throw StateError(
              'RetroArch repair binding target missing: $repairedPath',
            );
          }
          await txn.insert('user_detected_systems', {
            'app_system_id': id,
            'actual_folder_name': folders[id],
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          // Preserve merged user data and the physical archive identity.
          restored++;
          continue;
        }

        // Reuse only rows under an authoritative RetroArch bookmark. A same
        // basename in an unrelated library is never treated as this game's row.
        if (!physicalIdentities.contains((id, filename))) {
          await txn.rawInsert(
            '''
            INSERT INTO user_roms
              (rom_path, app_system_id, filename, title_id, title_name, created_at)
            VALUES (?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(rom_path) DO UPDATE SET
              title_name = COALESCE(EXCLUDED.title_name, title_name),
              updated_at = datetime('now')
          ''',
            [virtualPath, id, filename, entry['titleId'], entry['titleName']],
          );
        }
        await txn.insert('user_detected_systems', {
          'app_system_id': id,
          'actual_folder_name': folders[id],
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        restored++;
      }
    });
    return restored;
  }
}
