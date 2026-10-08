import 'dart:convert';
import 'dart:io';

import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:path/path.dart' as path;

/// Only NeoStation-owned, fixed library namespaces are portable across its
/// container UUIDs. External sources must use their own resolved bookmarks.
abstract final class EmbeddedLibraryRecovery {
  static final _container = RegExp(
    r'^/(?:private/)?var/mobile/Containers/Data/Application/[0-9A-Fa-f-]+/',
  );
  static const _prefixes = <String, List<String>>{
    'gc': ['Library/Application Support/NeoStation/Dolphin/Library/gc/'],
    'wii': ['Library/Application Support/NeoStation/Dolphin/Library/wii/'],
    'ps2': ['Documents/ARMSX2/Games/'],
    'ports': [
      'Documents/Ports/Dusklight/Games/',
      'Documents/Ports/KartPad/Games/',
    ],
  };

  static String? containerRoot(String value) =>
      _container.firstMatch(value)?.group(0);

  static String? target(String value, String folder, String currentContainer) {
    final root = containerRoot(value);
    if (root == null || path.normalize(value) != value) return null;
    final relative = value.substring(root.length);
    if (!(_prefixes[folder] ?? []).any(relative.startsWith)) return null;
    return path.join(currentContainer, relative);
  }

  /// Synchronous transaction: no await can let another scan share this
  /// connection's transaction. Archive every original row before any mutation.
  /// Conflicting metadata or two nonzero histories are reported, never guessed.
  static ({int relocated, List<String> ambiguous}) reconcile(
    DatabaseAdapter adapter, {
    required String systemId,
    required String folder,
    required String currentContainer,
    bool Function(String)? fileExists,
  }) {
    final db = adapter.rawDb;
    if (!db.autocommit) {
      throw StateError('Embedded recovery requires an independent transaction');
    }
    final exists = fileExists ?? (value) => File(value).existsSync();
    var relocated = 0;
    final ambiguous = <String>[];
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT * FROM user_roms WHERE app_system_id = ?',
        [systemId],
      );
      for (final original in rows) {
        final oldPath = original['rom_path'] as String;
        final newPath = target(oldPath, folder, currentContainer);
        if (newPath == null || newPath == oldPath || !exists(newPath)) continue;
        // Another accessible old source is not evidence of a container move.
        if (exists(oldPath)) {
          ambiguous.add(oldPath);
          continue;
        }
        final matches = db.select(
          'SELECT * FROM user_roms WHERE rom_path = ?',
          [newPath],
        );
        final merged = Map<String, Object?>.from(original);
        var conflict = false;
        if (matches.isNotEmpty) {
          final other = matches.single;
          for (final key in merged.keys.toList()) {
            final a = merged[key];
            final b = other[key];
            if (key == 'rom_path') continue;
            if (key == 'is_favorite') {
              merged[key] = a == 1 || b == 1 ? 1 : 0;
            } else if (key == 'cloud_sync_enabled') {
              merged[key] = a == 0 || b == 0 ? 0 : 1;
            } else if (key == 'play_time') {
              final first = (a as num?)?.toInt() ?? 0;
              final second = (b as num?)?.toInt() ?? 0;
              if (first > 0 && second > 0) conflict = true;
              merged[key] = first + second;
            } else if ([
              'created_at',
              'updated_at',
              'last_played',
            ].contains(key)) {
              if (a == null) {
                merged[key] = b;
                continue;
              }
              if (b == null || a == b) continue;
              final first = DateTime.tryParse(a.toString());
              final second = DateTime.tryParse(b.toString());
              if (first == null || second == null) {
                conflict = true;
                continue;
              }
              final takeSecond = key == 'created_at'
                  ? second.isBefore(first)
                  : second.isAfter(first);
              if (takeSecond) merged[key] = b;
            } else if (a == null || a == '') {
              merged[key] = b;
            } else if (b != null && b != '' && a != b) {
              conflict = true;
            }
          }
        }
        if (conflict) {
          ambiguous.add(oldPath);
          continue;
        }
        db.execute('''CREATE TABLE IF NOT EXISTS user_library_path_repair_v1 (
          old_path TEXT PRIMARY KEY, target_path TEXT NOT NULL,
          original_json TEXT NOT NULL, target_json TEXT,
          repaired_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )''');
        // Never overwrite the first pre-repair snapshot on repeated restoration.
        db.execute(
          '''INSERT OR IGNORE INTO user_library_path_repair_v1
          (old_path, target_path, original_json, target_json) VALUES (?, ?, ?, ?)''',
          [
            oldPath,
            newPath,
            jsonEncode(original),
            matches.isEmpty ? null : jsonEncode(matches.single),
          ],
        );
        if (matches.isEmpty) {
          db.execute('UPDATE user_roms SET rom_path = ? WHERE rom_path = ?', [
            newPath,
            oldPath,
          ]);
        } else {
          merged.remove('rom_path');
          db.execute(
            'UPDATE user_roms SET ${merged.keys.map((k) => '"$k" = ?').join(', ')} WHERE rom_path = ?',
            [...merged.values, newPath],
          );
          db.execute('DELETE FROM user_roms WHERE rom_path = ?', [oldPath]);
        }
        relocated++;
      }
      db.execute('COMMIT');
      return (relocated: relocated, ambiguous: ambiguous);
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
