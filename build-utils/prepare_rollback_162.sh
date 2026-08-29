#!/usr/bin/env bash
set -euo pipefail

git fetch --no-tags origin '+refs/heads/*:refs/remotes/origin/*'

# Keep only the explicitly approved post-backup additions.
git checkout 183256ee2b57115769c665f3a1c253cb054c7bea -- \
  lib/screens/game_screen/my_games_carousel.dart \
  lib/screens/game_screen/my_games_grid.dart \
  lib/screens/game_screen/my_games_list.dart

git checkout 0e9379fb6cd8e684cb982784b771631a884c2f94 -- \
  lib/screens/library_screen/library_screen.dart \
  test/library_no_native_sources_test.dart
git rm -f lib/services/library_mangadex_service.dart

git checkout 70d1af3c357ecc3d54a4daf50ee8f37bed18d208 -- \
  lib/services/neo_assets_service.dart \
  docs/system-art/RiiSU.md \
  test/services/neo_assets_service_external_pack_test.dart

python3 - <<'PY'
from pathlib import Path
import re

p = Path('lib/services/retroarch_library_service.dart')
s = p.read_text(encoding='utf-8')
if "package:external_folder_access/external_folder_access.dart" not in s:
    s = s.replace(
        "import 'dart:io';\n",
        "import 'dart:io';\n\nimport 'package:external_folder_access/external_folder_access.dart';\n",
        1,
    )

prefs_line = "  static const String _prefsKey = 'retroarch_library_cache_v1';\n"
if prefs_line not in s:
    raise SystemExit('RetroArch legacy cache key marker not found')
extra_consts = """  static const String _cleanRollbackKey =
      'ios_testflight_clean_rollback_162_v1';
  static const List<String> _newTestFlightCacheKeys = <String>[
    'retroarch_testflight_library_cache_v1',
    'retroarch_testflight_library_cache_v2',
  ];
"""
if '_cleanRollbackKey' not in s:
    s = s.replace(prefs_line, prefs_line + extra_consts, 1)

migration_marker = "  /// Loads the last-synced library from disk into memory, if not already\n"
if migration_marker not in s:
    raise SystemExit('RetroArch loadCachedLibrary marker not found')

migration = r'''  static bool _looksLikeLibraryCache(String? raw) {
    if (raw == null || raw.isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map && decoded.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// One-time bridge from the experimental App Store/Manic builds back to the
  /// stable TestFlight-only cache format used by this rollback baseline.
  /// Physical ROM files and unrelated emulator bookmarks are never touched.
  static Future<void> _runCleanRollbackMigration() async {
    if (!Platform.isIOS) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_cleanRollbackKey) == true) return;

      final legacyCache = prefs.getString(_prefsKey);
      if (!_looksLikeLibraryCache(legacyCache)) {
        for (final candidateKey in _newTestFlightCacheKeys) {
          final candidate = prefs.getString(candidateKey);
          if (_looksLikeLibraryCache(candidate)) {
            await prefs.setString(_prefsKey, candidate!);
            _log.i(
              'RetroArch rollback: restored TestFlight cache from $candidateKey.',
            );
            break;
          }
        }
      }

      const exactRemovedKeys = <String>{
        'ios_library_emulator_v1',
        'manic_emu_upgrade_offer_seen_v1',
        'retroarch_linked_library_cache_v2',
        'retroarch_linked_library_root_v1',
        'retroarch_testflight_library_root_v1',
        'retroarch_distribution_v1',
        'retroarch_ios_distribution_v1',
        'retroarch_hard_split_migrated_v1',
        'retroarch_hard_split_offer_seen_v1',
        'retroarch_appstore_launch_cache_v1',
        'retroarch_appstore_launch_cache_v2',
        'retroarch_appstore_launch_cache_v3',
        'retroarch_appstore_launch_root_v1',
        'retroarch_appstore_launch_root_v2',
        'retroarch_appstore_launch_root_v3',
        'retroarch_testflight_library_cache_v1',
        'retroarch_testflight_library_cache_v2',
      };

      final keys = prefs.getKeys().toList(growable: false);
      for (final key in keys) {
        if (exactRemovedKeys.contains(key) ||
            key.startsWith('retroarch_appstore_') ||
            key.startsWith('manic_emu_') ||
            key.startsWith('ios_game_emulator_v1:')) {
          await prefs.remove(key);
        }
      }

      await ExternalFolderAccess.clearBookmark(key: 'manicemu');
      await prefs.setBool(_cleanRollbackKey, true);
      _log.i(
        'RetroArch rollback: removed App Store/Manic routing state; TestFlight only.',
      );
    } catch (e) {
      _log.w('RetroArch rollback migration will retry next launch: $e');
    }
  }

  static Map<String, dynamic>? _entryForRomPath(
    Map<String, Map<String, dynamic>> cache,
    String romPath,
  ) {
    final basename = path.basename(romPath);
    final stem = path.basenameWithoutExtension(romPath);
    return cache[basename] ?? cache[romPath] ?? cache[stem];
  }

  /// Returns true when the last TestFlight library export contains this game.
  /// This intentionally does not require the old absolute iOS container path
  /// to still exist after an emulator reinstall/update.
  static Future<bool> hasGameForRomPath(String romPath) async {
    if (_cache == null) await loadCachedLibrary();
    final cache = _cache;
    if (cache == null || cache.isEmpty) return false;
    return _entryForRomPath(cache, romPath) != null;
  }

'''
if '_runCleanRollbackMigration' not in s:
    s = s.replace(migration_marker, migration + migration_marker, 1)

load_start = "  static Future<void> loadCachedLibrary() async {\n    if (_cache != null) return;\n"
if load_start not in s:
    raise SystemExit('RetroArch loadCachedLibrary body marker not found')
s = s.replace(
    load_start,
    "  static Future<void> loadCachedLibrary() async {\n    await _runCleanRollbackMigration();\n    if (_cache != null) return;\n",
    1,
)

old_lookup = """    final basename = path.basename(romPath);
    final stem = path.basenameWithoutExtension(romPath);
    final entry = cache[basename] ?? cache[romPath] ?? cache[stem];
"""
if old_lookup not in s:
    raise SystemExit('RetroArch launch lookup marker not found')
s = s.replace(
    old_lookup,
    "    final basename = path.basename(romPath);\n    final entry = _entryForRomPath(cache, romPath);\n",
    1,
)
p.write_text(s, encoding='utf-8')

p = Path('lib/services/game/game_launch_service.dart')
s = p.read_text(encoding='utf-8')
old_exists = """        } else {
          romExists = await File(game.romPath!).exists();
        }
"""
new_exists = """        } else {
          romExists = await File(game.romPath!).exists();
          if (!romExists && Platform.isIOS) {
            try {
              romExists = await RetroArchLibraryService.hasGameForRomPath(
                game.romPath!,
              );
            } catch (_) {
              // A missing/invalid TestFlight cache remains a normal not-found.
            }
          }
        }
"""
if old_exists not in s:
    raise SystemExit('ROM existence marker not found')
s = s.replace(old_exists, new_exists, 1)

start_marker = "        // Genuine one-tap launch: if this ROM lives in a folder we've\n"
end_marker = "      final configFileName = '${system.folderName}.json';\n"
start = s.find(start_marker)
end = s.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit('iOS Open In/share fallback block markers not found')
replacement = """        if (!context.mounted) return GameLaunchResult.failure('', '');
        return GameLaunchResult.failure(
          'RetroArch TestFlight library entry not found.',
          'Synchronize the RetroArch TestFlight library in NeoStation and try again.',
        );
      }

"""
s = s[:start] + replacement + s[end:]

for import_line, symbol in [
    ("import 'package:share_plus/share_plus.dart';\n", 'SharePlus'),
    ("import 'package:external_folder_access/external_folder_access.dart';\n", 'ExternalFolderAccess'),
    ("import 'package:neostation/services/retroarch_playlist_service.dart';\n", 'RetroArchPlaylistService'),
]:
    candidate = s.replace(import_line, '')
    if symbol not in candidate:
        s = candidate
p.write_text(s, encoding='utf-8')

p = Path('pubspec.yaml')
s = p.read_text(encoding='utf-8')
s, count = re.subn(r'^version:\s*[^\n]+$', 'version: 1.0.0+162', s, count=1, flags=re.M)
if count != 1:
    raise SystemExit('pubspec version marker not found')
p.write_text(s, encoding='utf-8')

Path('test/ios_selective_rollback_test.dart').write_text(r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS launcher is RetroArch TestFlight only for general ROMs', () {
    final launcher = File(
      'lib/services/game/game_launch_service.dart',
    ).readAsStringSync();
    expect(launcher, contains('RetroArchLibraryService.launchGameByRomPath'));
    expect(launcher, contains('RetroArchLibraryService.hasGameForRomPath'));
    expect(launcher, isNot(contains('ExternalFolderAccess.openInMenu(')));
    expect(launcher, isNot(contains('SharePlus.instance.share(')));
    expect(launcher, isNot(contains('ResumeNeoStation')));
    expect(launcher.toLowerCase(), isNot(contains('manicemu')));
  });

  test('rollback migrates TestFlight cache before purging experimental state', () {
    final service = File(
      'lib/services/retroarch_library_service.dart',
    ).readAsStringSync();
    expect(service, contains("_prefsKey = 'retroarch_library_cache_v1'"));
    expect(service, contains('retroarch_testflight_library_cache_v1'));
    expect(service, contains('retroarch_testflight_library_cache_v2'));
    expect(service, contains("clearBookmark(key: 'manicemu')"));
    expect(service, contains("key.startsWith('retroarch_appstore_')"));
    expect(service, contains("key.startsWith('ios_game_emulator_v1:')"));
  });

  test('only approved post-backup feature surfaces are present', () {
    final library = File(
      'lib/screens/library_screen/library_screen.dart',
    ).readAsStringSync();
    expect(library, isNot(contains('LibraryMangaDexService')));

    final assets = File('lib/services/neo_assets_service.dart').readAsStringSync();
    expect(assets, contains('mult1v4c/RiiSU'));

    for (final path in [
      'lib/screens/game_screen/my_games_carousel.dart',
      'lib/screens/game_screen/my_games_grid.dart',
      'lib/screens/game_screen/my_games_list.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('Platform.isIOS'));
      expect(source, contains('padding'));
    }
  });
}
''', encoding='utf-8')
PY

dart format \
  lib/services/retroarch_library_service.dart \
  lib/services/game/game_launch_service.dart \
  lib/screens/library_screen/library_screen.dart \
  lib/screens/game_screen/my_games_carousel.dart \
  lib/screens/game_screen/my_games_grid.dart \
  lib/screens/game_screen/my_games_list.dart \
  test/library_no_native_sources_test.dart \
  test/services/neo_assets_service_external_pack_test.dart \
  test/ios_selective_rollback_test.dart

test ! -e lib/services/manic_emu_launch_service.dart
test ! -e lib/services/manic_emu_library_service.dart
test ! -e lib/services/retroarch_appstore_service.dart
test ! -e lib/services/library_mangadex_service.dart

# Remove this helper from the final source commit; the workflow itself is
# cleaned by the assistant after a successful artifact upload.
rm -f build-utils/prepare_rollback_162.sh

git config user.name 'NeoStation Rollback Builder'
git config user.email 'actions@users.noreply.github.com'
git add -A
git commit -m 'Restore stable TestFlight-only iOS baseline [skip ci]'
git push origin HEAD:rollback/testflight-clean-20260823
