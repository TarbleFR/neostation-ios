from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, content: str) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(content, encoding="utf-8")


# 1. Remove every generic iOS Open In / Share / Resume fallback from the game
# launcher. RetroArch on iOS is TestFlight-only.
p = "lib/services/game/game_launch_service.dart"
s = read(p)
for line in [
    "import 'package:share_plus/share_plus.dart';\n",
    "import 'package:external_folder_access/external_folder_access.dart';\n",
    "import 'package:neostation/services/retroarch_playlist_service.dart';\n",
]:
    s = s.replace(line, "")

old_intro = '''      // iOS: there's no equivalent of Android's "send an Intent with a file
      // to any installed app", and dart:io Process is unimplemented. What
      // *does* work — confirmed by hand on-device — is the standard iOS
      // share sheet: RetroArch (and other emulators) register themselves as
      // valid recipients for ROM files there. So instead of shelling out to
      // a separate process, hand the ROM off through UIActivityViewController
      // and let the user pick their emulator from the native share sheet.
      // This needs one extra tap the first few times; iOS promotes
      // frequently-used apps to the front of that list afterwards.
'''
new_intro = '''      // iOS launches only through explicit emulator integrations. Generic
      // document handoff (Open In), Share Sheet and historical Resume shortcut
      // fallbacks are intentionally forbidden: they can route a TestFlight ROM
      // through an App Store-style import UI instead of launching the game.
'''
s = s.replace(old_intro, new_intro)
s = s.replace(
    "// Physical Switch rows can still fall through to RetroArch/Open In.",
    "// Physical Switch rows can still fall through to RetroArch TestFlight.",
)
s = s.replace(
    "// Physical PS2 rows can still fall through to RetroArch/Open In.",
    "// Physical PS2 rows can still fall through to RetroArch TestFlight.",
)

start_marker = "        // Multi-system iOS libraries: route by actual membership first."
end_marker = "\n      }\n\n      final configFileName"
start = s.index(start_marker)
end = s.index(end_marker, start)
replacement = '''        // Multi-system iOS libraries: route by actual synchronized
        // membership. Load the persisted TestFlight export before resolving
        // membership so a cold launch cannot race cache initialization.
        await RetroArchLibraryService.loadCachedLibrary();
        final retroArchHasGame = RetroArchLibraryService.hasGameForRomPath(
          game.romPath!,
        );
        final manicInstalled = await ManicEmuLaunchService.isInstalled();
        final manicHasGame =
            manicInstalled &&
            await ManicEmuLibraryService.hasGameForRomPath(
              ConfigService.linkedManicEmuFolderPath,
              game.romPath!,
            );
        final primaryLibraryEmulator =
            await IosEmulatorPreferenceService.primary();
        final libraryEmulator =
            IosEmulatorPreferenceService.resolveLaunchEmulator(
              primary: primaryLibraryEmulator,
              retroArchHasGame: retroArchHasGame,
              manicEmuHasGame: manicHasGame,
            );

        if (libraryEmulator == IosLibraryEmulator.manicEmu) {
          final launched = await ManicEmuLaunchService.launchGame(
            game.romPath!,
          );
          if (launched) return GameLaunchResult.success();
          return GameLaunchResult.failure(
            AppLocale.failedToLaunchStandalone
                .getString(context)
                .replaceFirst('{name}', 'Manic EMU'),
            game.romPath,
          );
        }

        if (libraryEmulator == IosLibraryEmulator.retroArch) {
          final launched = await RetroArchLibraryService.launchGameByRomPath(
            game.romPath!,
          );
          if (launched) return GameLaunchResult.success();
          return GameLaunchResult.failure(
            'RetroArch TestFlight could not launch this game. Resynchronize '
            'the RetroArch library in Settings > Directories.',
            game.romPath,
          );
        }

        return GameLaunchResult.failure(
          'This game is not present in the synchronized RetroArch TestFlight '
          'or Manic EMU library. Resynchronize the corresponding library.',
          game.romPath,
        );'''
s = s[:start] + replacement + s[end:]
if "launchUrl(" not in s:
    s = s.replace("import 'package:url_launcher/url_launcher.dart';\n", "")
if "SharePlus" in s or "openInMenu" in s or "ResumeNeoStation" in s:
    raise SystemExit("Legacy iOS launch fallback still present in game launcher")
write(p, s)


# 2. Harden the TestFlight export cache. Never revive generic/App Store-era
# cache keys, never erase a good cache on an empty callback, and load persisted
# metadata before every launch.
p = "lib/services/retroarch_library_service.dart"
s = read(p)
s = s.replace(
    "  static const List<String> _removedAppStorePreferenceKeys = [\n",
    "  static const List<String> _removedAppStorePreferenceKeys = [\n    _legacyPrefsKey,\n",
)
s = s.replace(
    "      final raw =\n          prefs.getString(_prefsKey) ?? prefs.getString(_legacyPrefsKey);",
    "      final raw = prefs.getString(_prefsKey);",
)

decoded_marker = "      if (decoded is! List) return false;\n\n      final byFilename = <String, Map<String, dynamic>>{};"
decoded_replacement = '''      if (decoded is! List) return false;

      // A transient/empty TestFlight export must never erase the last known
      // good launch index. Keep the persisted cache and wait for a later sync.
      if (decoded.isEmpty) {
        await loadCachedLibrary();
        _log.w(
          'RetroArchLibraryService: TestFlight returned an empty library; '
          'preserving the previous synchronized cache.',
        );
        await _writeDebugFile(
          'retroarch_testflight_sync_debug.txt',
          'STATE: EMPTY_EXPORT_PRESERVED\\nPrevious entries: ${_cache?.length ?? 0}',
        );
        return true;
      }

      final byFilename = <String, Map<String, dynamic>>{};'''
if decoded_marker not in s:
    raise SystemExit("RetroArch decoded marker not found")
s = s.replace(decoded_marker, decoded_replacement)

cache_assignment = "      _cache = byFilename;\n      await _persist(byFilename);"
guarded_assignment = '''      if (byFilename.isEmpty) {
        await loadCachedLibrary();
        _log.w(
          'RetroArchLibraryService: TestFlight export had no usable entries; '
          'preserving the previous synchronized cache.',
        );
        return true;
      }

      _cache = byFilename;
      await _persist(byFilename);'''
if cache_assignment not in s:
    raise SystemExit("RetroArch cache assignment marker not found")
s = s.replace(cache_assignment, guarded_assignment, 1)

launch_marker = '''  static Future<bool> launchGameByRomPath(String romPath) async {
    await _cleanupRemovedAppStoreState();
    final cache = _cache;'''
launch_replacement = '''  static Future<bool> launchGameByRomPath(String romPath) async {
    await _cleanupRemovedAppStoreState();
    await loadCachedLibrary();
    final cache = _cache;'''
if launch_marker not in s:
    raise SystemExit("RetroArch launch marker not found")
s = s.replace(launch_marker, launch_replacement)

launch_return = '''    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      _log.e('RetroArch TestFlight launch failed: $e');
      return false;
    }'''
launch_return_new = '''    try {
      if (!await canLaunchUrl(uri)) {
        _log.e('RetroArch TestFlight URL scheme is unavailable: $uri');
        return false;
      }
      final opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        // UIKit can occasionally report a false completion after a custom URL
        // handoff. The dispatch is terminal once canLaunchUrl succeeded: never
        // route the ROM into Open In/Share as a fallback.
        _log.w(
          'RetroArch TestFlight handoff reported false after a valid scheme '
          'dispatch: $uri',
        );
      }
      return true;
    } catch (e) {
      _log.e('RetroArch TestFlight launch failed: $e');
      return false;
    }'''
idx = s.rfind(launch_return)
if idx < 0:
    raise SystemExit("RetroArch launch return block not found")
s = s[:idx] + launch_return_new + s[idx + len(launch_return):]
write(p, s)


# 3. Central path persistence/reconciliation for security-scoped iOS bookmarks.
service = r'''import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps iOS security-scoped library roots stable across File Provider path
/// churn. The logical bookmark stays the same even when iOS resolves it under a
/// different absolute container prefix after an app relaunch or re-sign.
class IosLinkedLibraryPathService {
  IosLinkedLibraryPathService._();

  static const retroArchPathKey = 'ios_linked_retroarch_resolved_path_v2';
  static const manicEmuPathKey = 'ios_linked_manicemu_resolved_path_v2';

  static Future<void> rememberRetroArch(String value) =>
      _remember(retroArchPathKey, value);

  static Future<void> rememberManicEmu(String value) =>
      _remember(manicEmuPathKey, value);

  static Future<void> _remember(String key, String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, normalized);
  }

  static Future<List<String>> reconcile({
    required List<String> configuredFolders,
    required String? retroArchPath,
    required String? manicEmuPath,
    int maximumFolders = 5,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final folders = <String>[...configuredFolders];
    final protected = <String>{
      if (retroArchPath?.trim().isNotEmpty == true) retroArchPath!.trim(),
      if (manicEmuPath?.trim().isNotEmpty == true) manicEmuPath!.trim(),
    };

    Future<void> reconcileOne(String key, String? currentValue) async {
      final current = currentValue?.trim();
      if (current == null || current.isEmpty) return;

      final already = folders.indexWhere((value) => path.equals(value, current));
      if (already >= 0) {
        await prefs.setString(key, current);
        return;
      }

      String? replacement;
      final previous = prefs.getString(key)?.trim();
      if (previous != null && previous.isNotEmpty) {
        final previousIndex = folders.indexWhere(
          (value) => path.equals(value, previous),
        );
        if (previousIndex >= 0) replacement = folders[previousIndex];
      }

      // Migration for builds that predate the resolved-path marker. The old
      // and new security-scoped locations normally keep the same final folder
      // name while only the File Provider/container prefix changes.
      if (replacement == null) {
        final basename = path.basename(current).toLowerCase();
        final sameNameUnavailable = <String>[];
        for (final candidate in folders) {
          if (protected.any((value) => path.equals(value, candidate))) continue;
          if (path.basename(candidate).toLowerCase() != basename) continue;
          if (!await isReadableFolder(candidate)) {
            sameNameUnavailable.add(candidate);
          }
        }
        if (sameNameUnavailable.length == 1) {
          replacement = sameNameUnavailable.single;
        }
      }

      // Older App Store-era builds did not persist a logical path marker. If
      // exactly one dead security-scoped File Provider root remains, it is the
      // safe migration candidate for the currently resolved bookmark.
      if (replacement == null) {
        final staleScoped = <String>[];
        for (final candidate in folders) {
          if (protected.any((value) => path.equals(value, candidate))) continue;
          if (!_looksSecurityScoped(candidate)) continue;
          if (!await isReadableFolder(candidate)) staleScoped.add(candidate);
        }
        if (staleScoped.length == 1) replacement = staleScoped.single;
      }

      if (replacement != null) {
        final index = folders.indexOf(replacement);
        if (index >= 0) folders[index] = current;
      } else if (folders.length < maximumFolders) {
        folders.add(current);
      }

      await prefs.setString(key, current);
    }

    await reconcileOne(retroArchPathKey, retroArchPath);
    await reconcileOne(manicEmuPathKey, manicEmuPath);

    final deduplicated = <String>[];
    for (final folder in folders) {
      if (!deduplicated.any((existing) => path.equals(existing, folder))) {
        deduplicated.add(folder);
      }
    }
    return deduplicated;
  }

  static Future<List<String>> unreadableFolders(
    Iterable<String> folders,
  ) async {
    final unavailable = <String>[];
    for (final folder in folders) {
      final value = folder.trim();
      if (value.isEmpty) continue;
      if (!await isReadableFolder(value)) unavailable.add(value);
    }
    return unavailable;
  }

  static Future<bool> isReadableFolder(String value) async {
    try {
      final directory = Directory(value);
      if (!await directory.exists()) return false;
      await directory
          .list(recursive: false, followLinks: false)
          .take(1)
          .drain<void>()
          .timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool _looksSecurityScoped(String value) {
    final lower = value.replaceAll('\\', '/').toLowerCase();
    return lower.contains('/file provider storage/') ||
        lower.contains('/containers/shared/appgroup/');
  }
}
'''
write("lib/services/ios_linked_library_path_service.dart", service)


# Provider: reconcile stale absolute roots immediately after config load.
p = "lib/providers/sqlite_config_provider.dart"
s = read(p)
import_marker = "import '../services/manic_emu_library_service.dart';\n"
if "ios_linked_library_path_service.dart" not in s:
    s = s.replace(
        import_marker,
        import_marker + "import '../services/ios_linked_library_path_service.dart';\n",
    )
load_marker = "      await _loadInitialData();\n\n      _initialized = true;"
load_replacement = '''      await _loadInitialData();

      if (Platform.isIOS) {
        final reconciledFolders = await IosLinkedLibraryPathService.reconcile(
          configuredFolders: _config.romFolders,
          retroArchPath: ConfigService.linkedExternalFolderPath,
          manicEmuPath: ConfigService.linkedManicEmuFolderPath,
        );
        if (!listEquals(reconciledFolders, _config.romFolders)) {
          _log.i(
            'Reassociated iOS linked library paths after security-scoped '
            'bookmark resolution.',
          );
          _config = _config.copyWith(romFolders: reconciledFolders);
          await SqliteConfigService.saveConfig(_config);
        }
      }

      _initialized = true;'''
if load_marker not in s:
    raise SystemExit("Provider load marker not found")
s = s.replace(load_marker, load_replacement)
write(p, s)


# Scanner: never destructively prune a stored iOS library when one of its
# configured security-scoped roots is temporarily unreadable.
p = "lib/providers/sqlite_config_provider/scanning.dart"
s = read(p)
progress_marker = "    // Initialize progress\n"
safety = '''    if (Platform.isIOS &&
        _config.romFolders.isNotEmpty &&
        await _hasStoredRoms()) {
      final unavailable = await IosLinkedLibraryPathService.unreadableFolders(
        _config.romFolders,
      );
      if (unavailable.isNotEmpty) {
        _scanStatus =
            'Linked iOS ROM library is temporarily unavailable; existing games were kept.';
        _scanCompleted = true;
        SqliteConfigProvider._log.w(
          'Skipping destructive iOS startup scan because linked folder access '
          'is unavailable: $unavailable',
        );
        _finishSystemScan();
        return;
      }
    }

'''
if progress_marker not in s:
    raise SystemExit("Scanner progress marker not found")
s = s.replace(progress_marker, safety + progress_marker, 1)
s = s.replace(
    "The selected folder may belong to either an App Store installation or a\n  /// sideloaded/re-signed IPA.",
    "The selected folder may be re-resolved by iOS under a different\n  /// security-scoped absolute path after relaunch or re-sign.",
)
write(p, s)


# Database scan: if iOS granted a target but every walk failed, keep existing
# rows instead of interpreting the access failure as deletion.
p = "lib/data/datasources/sqlite_database_service.dart"
s = read(p)
walk_marker = "    final walkedDirs = <String>{};\n"
if walk_marker not in s:
    raise SystemExit("Database walk marker not found")
s = s.replace(
    walk_marker,
    "    final walkedDirs = <String>{};\n    var successfulTargetWalks = 0;\n",
    1,
)
entries_marker = '''            : await _scanStandardPath(
                target.dirPath,
                validExtensionsSet,
                system.recursiveScan,
                ignoreHiddenFiles: ignoreHiddenFiles,
              );

        if (entries.isNotEmpty) {'''
entries_replacement = '''            : await _scanStandardPath(
                target.dirPath,
                validExtensionsSet,
                system.recursiveScan,
                ignoreHiddenFiles: ignoreHiddenFiles,
              );

        successfulTargetWalks++;
        if (entries.isNotEmpty) {'''
if entries_marker not in s:
    raise SystemExit("Database entries marker not found")
s = s.replace(entries_marker, entries_replacement, 1)
cleanup_marker = "    // Apply M3U and redundancy filters\n"
cleanup_safety = '''    if (Platform.isIOS &&
        initialCount > 0 &&
        orderedTargets.isNotEmpty &&
        successfulTargetWalks == 0) {
      _log.w(
        'Keeping ${system.realName} ROM rows because every iOS linked-folder '
        'walk failed during this scan.',
      );
      return ScanSummary(
        added: 0,
        removed: 0,
        total: initialCount,
        systemName: system.realName,
      );
    }

'''
if cleanup_marker not in s:
    raise SystemExit("Database cleanup marker not found")
s = s.replace(cleanup_marker, cleanup_safety + cleanup_marker, 1)
write(p, s)


# 4. Persist logical bookmark path markers at every explicit link.
p = "lib/widgets/setup_wizard.dart"
s = read(p)
if "ios_linked_library_path_service.dart" not in s:
    s = s.replace(
        "import 'package:neostation/services/ios_emulator_preference_service.dart';\n",
        "import 'package:neostation/services/ios_emulator_preference_service.dart';\n"
        "import 'package:neostation/services/ios_linked_library_path_service.dart';\n",
    )
remember_marker = '''          if (usesManic) {
            ConfigService.linkedManicEmuFolderPath = linked;
          } else {
            ConfigService.linkedExternalFolderPath = linked;
          }
          await configProvider.addRomFolder(linked, scan: false);'''
remember_new = '''          if (usesManic) {
            ConfigService.linkedManicEmuFolderPath = linked;
            await IosLinkedLibraryPathService.rememberManicEmu(linked);
          } else {
            ConfigService.linkedExternalFolderPath = linked;
            await IosLinkedLibraryPathService.rememberRetroArch(linked);
          }
          await configProvider.addRomFolder(linked, scan: false);'''
if remember_marker not in s:
    raise SystemExit("Setup remember marker not found")
s = s.replace(remember_marker, remember_new, 1)
s = s.replace(
    "Waiting on RetroArch kept this button spinning when\n          // an App Store/TestFlight build did not return a library callback.",
    "Waiting on RetroArch here would keep onboarding tied to an\n          // external callback; the dedicated TestFlight sync owns that flow.",
)
write(p, s)


p = "lib/screens/settings_screen/new_settings_options/directories_settings_content.dart"
s = read(p)
if "ios_linked_library_path_service.dart" not in s:
    s = s.replace(
        "import 'package:neostation/services/ios_emulator_preference_service.dart';\n",
        "import 'package:neostation/services/ios_emulator_preference_service.dart';\n"
        "import 'package:neostation/services/ios_linked_library_path_service.dart';\n",
    )
setting_marker = '''      if (bookmarkKey == ManicEmuLaunchService.bookmarkKey) {
        ConfigService.linkedManicEmuFolderPath = activePath;
      } else {
        ConfigService.linkedExternalFolderPath = activePath;
      }
'''
setting_new = '''      if (bookmarkKey == ManicEmuLaunchService.bookmarkKey) {
        ConfigService.linkedManicEmuFolderPath = activePath;
        await IosLinkedLibraryPathService.rememberManicEmu(activePath);
      } else {
        ConfigService.linkedExternalFolderPath = activePath;
        await IosLinkedLibraryPathService.rememberRetroArch(activePath);
      }
'''
if setting_marker not in s:
    raise SystemExit("Settings path marker not found")
s = s.replace(setting_marker, setting_new, 1)
s = s.replace(
    "// RetroArch App Store/TestFlight and Manic EMU App Store/IPA are\n"
    "      // equivalent linked-library providers within their own family. Only\n"
    "      // update NeoStation's active source reference; never modify an app\n"
    "      // container. Force a scan even when iOS resolves both picks to the same\n"
    "      // display path.",
    "// RetroArch TestFlight and Manic EMU IPA keep independent\n"
    "      // security-scoped roots. Update NeoStation's source reference only;\n"
    "      // never modify either emulator container. Force a scan even when iOS\n"
    "      // resolves a bookmark to the same visible path.",
)
s = s.replace(
    "// RetroArch's exported index and existing rows remain usable until a\n"
    "        // new App Store/TestFlight callback succeeds. Manic EMU scans directly\n"
    "        // from its linked source and can safely discard the former association.",
    "// RetroArch's TestFlight export and existing rows remain usable until\n"
    "        // a fresh TestFlight callback succeeds. Manic EMU scans directly from\n"
    "        // its linked source and can safely discard the former association.",
)
write(p, s)


# 5. Remove the Open In API from the native folder plugin itself.
p = "packages/external_folder_access/lib/external_folder_access.dart"
s = read(p)
open_start = s.index('  /// Presents iOS\'s genuine "Open In" menu')
open_end = s.index("  /// Opens an arbitrary URL string on iOS", open_start)
s = s[:open_start] + s[open_end:]
write(p, s)

p = "packages/external_folder_access/ios/Classes/ExternalFolderAccessPlugin.swift"
s = read(p)
s = s.replace(
    "public class ExternalFolderAccessPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate,\n"
    "    UIDocumentInteractionControllerDelegate\n{",
    "public class ExternalFolderAccessPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {",
)
prop_start = s.index(
    "    // Held as a property, not a local var — UIDocumentInteractionController"
)
prop_end = s.index("    public static func register", prop_start)
s = s[:prop_start] + s[prop_end:]
s = s.replace(
    '        case "openInMenu":\n            openInMenu(call: call, result: result)\n',
    "",
)
method_start = s.index("    // MARK: - Open In")
method_end = s.index("    // MARK: - Helpers", method_start)
s = s[:method_start] + s[method_end:]
if "openInMenu" in s or "UIDocumentInteractionController" in s:
    raise SystemExit("Native Open In implementation still present")
write(p, s)


# 6. Regression tests + Build 161 naming.
p = "test/retroarch_testflight_library_test.dart"
s = read(p)
s = s.replace(
    "      'retroarch_appstore_launch_root_v3': '/legacy/appstore/path',\n",
    "      'retroarch_appstore_launch_root_v3': '/legacy/appstore/path',\n"
    "      'retroarch_library_cache_v1': '{\\\"stale-appstore-entry\\\":{}}',\n",
)
s = s.replace(
    "    expect(prefs.containsKey('retroarch_appstore_launch_root_v3'), isFalse);\n",
    "    expect(prefs.containsKey('retroarch_appstore_launch_root_v3'), isFalse);\n"
    "    expect(prefs.containsKey('retroarch_library_cache_v1'), isFalse);\n",
)
write(p, s)

guard_test = r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS game launch has no App Store-style Open In or Share fallback', () {
    final launch = File(
      'lib/services/game/game_launch_service.dart',
    ).readAsStringSync();
    final dartBridge = File(
      'packages/external_folder_access/lib/external_folder_access.dart',
    ).readAsStringSync();
    final nativeBridge = File(
      'packages/external_folder_access/ios/Classes/'
      'ExternalFolderAccessPlugin.swift',
    ).readAsStringSync();

    expect(launch, isNot(contains('openInMenu')));
    expect(launch, isNot(contains('SharePlus')));
    expect(launch, isNot(contains('ResumeNeoStation')));
    expect(launch, contains('await RetroArchLibraryService.loadCachedLibrary()'));
    expect(dartBridge, isNot(contains('openInMenu')));
    expect(nativeBridge, isNot(contains('UIDocumentInteractionController')));
    expect(nativeBridge, isNot(contains('openInMenu')));
  });
}
'''
write("test/ios_retroarch_testflight_launch_guard_test.dart", guard_test)

path_test = r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/ios_linked_library_path_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('replaces a previous resolved RetroArch path after iOS path churn', () async {
    SharedPreferences.setMockInitialValues({
      IosLinkedLibraryPathService.retroArchPathKey: '/old/provider/RetroArch',
    });

    final result = await IosLinkedLibraryPathService.reconcile(
      configuredFolders: const ['/roms', '/old/provider/RetroArch'],
      retroArchPath: '/new/provider/RetroArch',
      manicEmuPath: null,
    );

    expect(result, const ['/roms', '/new/provider/RetroArch']);
  });

  test('unreadable linked root is detected without deleting anything', () async {
    final missing = '${Directory.systemTemp.path}/neostation-missing-linked-root';
    final unavailable = await IosLinkedLibraryPathService.unreadableFolders([
      missing,
    ]);
    expect(unavailable, [missing]);
  });
}
'''
write("test/ios_linked_library_path_service_test.dart", path_test)

# Remove obsolete App Store wording from the reassociation test while retaining
# generic replacement helper coverage.
p = "test/ios_linked_library_reassociation_test.dart"
s = read(p)
s = s.replace(
    "test('moves NeoStation association from App Store to IPA source', () {",
    "test('moves NeoStation association to a newly resolved linked source', () {",
)
s = s.replace("'/manic-app-store'", "'/manic-old-root'")
s = s.replace("'/manic-ipa'", "'/manic-new-root'")
s = s.replace(
    "test('moves RetroArch association between App Store and TestFlight', () {",
    "test('moves RetroArch association between resolved TestFlight roots', () {",
)
s = s.replace("'/retroarch-app-store'", "'/retroarch-old-root'")
s = s.replace("'/retroarch-testflight'", "'/retroarch-new-root'")
s = s.replace(
    "final selectionStart = wizard.indexOf('Future<void> _selectFolder()');",
    "final selectionStart = wizard.indexOf('Future<void> _selectFolder({');",
)
write(p, s)

p = "pubspec.yaml"
s = read(p).replace("version: 1.0.0+160", "version: 1.0.0+161")
write(p, s)

p = ".github/workflows/build-ios-ipa.yml"
s = read(p).replace("NeoStation-iOS-Build-159", "NeoStation-iOS-Build-161")
validate_marker = "      - name: Prepare ScreenScraper build environment\n"
validate_step = '''      - name: Validate TestFlight-only iOS library paths
        run: |
          flutter test \\
            test/retroarch_testflight_library_test.dart \\
            test/ios_retroarch_testflight_launch_guard_test.dart \\
            test/ios_linked_library_path_service_test.dart \\
            test/ios_linked_library_reassociation_test.dart
          flutter analyze --no-fatal-warnings --no-fatal-infos

'''
if "Validate TestFlight-only iOS library paths" not in s:
    if validate_marker not in s:
        raise SystemExit("Build validation insertion marker not found")
    s = s.replace(validate_marker, validate_step + validate_marker, 1)
write(p, s)
