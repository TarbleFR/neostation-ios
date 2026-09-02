import 'dart:convert';
import 'dart:io';

import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/logger_service.dart';

/// Talks to RetroArch's real, confirmed URL-scheme protocol for library
/// export and direct game launching, on the TestFlight build.
///
/// Protocol (provided directly by the developer of a third-party app that
/// already uses it successfully):
///
///   1. NeoStation opens `retroarch://library?scheme=neostation` to ask
///      RetroArch to export its whole game library.
///   2. RetroArch calls back `neostation://retroarch?games=<base64url>` —
///      a base64url (no padding), JSON-encoded array of every game it
///      knows about, each with `titleId`/`filename`/`titleName`/`gameId`/
///      `system`/`coreName`. `filename` (== `titleId`) is the exact value
///      RetroArch's own `retroarch://game/<filename>` scheme expects.
///   3. To launch a specific game with no menu, no import step, and no
///      picker: `retroarch://game/<filename>`.
///
/// This replaces the earlier "Resume Last Game" playlist-rewriting
/// approach (kept as a fallback in GameLaunchService) — that one relied on
/// an assumption about RetroArch re-reading content_history.lpl on launch
/// that testing didn't bear out. This scheme is directly documented by
/// RetroArch's own TestFlight-side code, not inferred.
class RetroArchLibraryService {
  RetroArchLibraryService._();

  static final _log = LoggerService.instance;

  static const String _callbackScheme = 'neostation';
  static const String _prefsKey = 'retroarch_library_cache_v1';
  static const String _cleanRollbackKey =
      'ios_testflight_clean_rollback_162_v1';
  static const List<String> _newTestFlightCacheKeys = <String>[
    'retroarch_testflight_library_cache_v1',
    'retroarch_testflight_library_cache_v2',
  ];

  /// filename -> the raw exported entry (titleId/filename/titleName/
  /// gameId/system/coreName), cached in memory after the first sync or
  /// load from disk this session.
  static Map<String, Map<String, dynamic>>? _cache;

  /// Opens RetroArch and asks it to export its library. The actual data
  /// arrives asynchronously via the `neostation://retroarch?games=...`
  /// callback — see [handleIncomingUri], wired up in main.dart through the
  /// app_links package. Returns whether the request URL was opened at all
  /// (not whether RetroArch actually responded).
  static Future<bool> requestLibrarySync() async {
    return launchUrl(Uri.parse('retroarch://library?scheme=$_callbackScheme'));
  }

  /// Call this with every incoming URI the app receives (from
  /// app_links' uriLinkStream / getInitialAppLink). Returns `true` if the
  /// URI was RetroArch's library callback and was handled.
  static Future<bool> handleIncomingUri(Uri uri) async {
    if (uri.scheme != _callbackScheme || uri.host != 'retroarch') {
      return false;
    }

    final gamesParam = uri.queryParameters['games'];
    if (gamesParam == null) {
      _log.w('RetroArchLibraryService: callback with no "games" param');
      return false;
    }

    try {
      final normalized = base64Url.normalize(gamesParam);
      final jsonBytes = base64Url.decode(normalized);
      final decoded = jsonDecode(utf8.decode(jsonBytes));
      if (decoded is! List) {
        _log.e('RetroArchLibraryService: decoded payload is not a list');
        return false;
      }

      final byFilename = <String, Map<String, dynamic>>{};
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry);
        final filename = (map['filename'] ?? map['titleId'])?.toString();
        if (filename == null || filename.isEmpty) continue;
        byFilename[filename] = map;
        // Also index by bare basename, in case RetroArch's "filename"
        // field turns out to be a relative/full path rather than a bare
        // filename in practice — cheap to keep both keys.
        byFilename[path.basename(filename)] = map;

        // Libretro's "content inside an archive" convention represents a
        // single ROM inside a zip as "archive.zip#innerfile.ext" — common
        // for systems typically distributed as one-ROM-per-zip (GBC, GB,
        // NES, etc). NeoStation only knows the archive's own path/name
        // (game.romPath points at the .zip, not what's inside it), so
        // index by the archive's basename too, or the lookup below would
        // never match for any archived content. Systems where the whole
        // zip itself IS the content as a unit (arcade/FBNeo romsets) don't
        // use "#" and are unaffected — they already matched via the plain
        // basename above.
        final hashIndex = filename.indexOf('#');
        if (hashIndex > 0) {
          final archivePart = filename.substring(0, hashIndex);
          byFilename[path.basename(archivePart)] = map;
        }

        // RetroArch's playlist "filename" for a zipped ROM sometimes uses
        // the inner content's own extension (e.g. "Game.gb") rather than
        // the container file's extension NeoStation actually sees on disk
        // (e.g. "Game.zip") — same title, different extension, no "#"
        // involved. Index by the extension-stripped stem too, as a last
        // fallback for exactly that mismatch. Confirmed via debug logging
        // on a real device: "4 in 1 Funpak (USA, Europe).gb" (RetroArch)
        // vs "4 in 1 Funpak (USA, Europe).zip" (actual file).
        final stem = path.basenameWithoutExtension(filename);
        byFilename.putIfAbsent(stem, () => map);
      }

      _cache = byFilename;
      await _persist(byFilename);
      _log.i(
        'RetroArchLibraryService: synced ${decoded.length} games from RetroArch',
      );
      await _writeDebugFile(
        'sync_debug.txt',
        'Synced ${decoded.length} games.\n\n'
            'Raw entries:\n${const JsonEncoder.withIndent('  ').convert(decoded)}',
      );

      // A RetroArch sync is exactly the moment new ROMs are most likely to
      // have shown up (the user just dropped some in and asked RetroArch
      // about its library) — rescan NeoStation's own game database too, so
      // they appear without needing to restart the app. Goes through the
      // root navigator's context since this is a plain service class with
      // no BuildContext of its own.
      try {
        final context = rootNavigatorKey.currentContext;
        if (context != null) {
          await Provider.of<SqliteConfigProvider>(
            context,
            listen: false,
          ).scanSystems();
        }
      } catch (e) {
        _log.e('RetroArchLibraryService: post-sync rescan failed: $e');
      }

      return true;
    } catch (e) {
      _log.e('RetroArchLibraryService: failed to parse library callback: $e');
      return false;
    }
  }

  static bool _looksLikeLibraryCache(String? raw) {
    if (raw == null || raw.isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map && decoded.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// One-time bridge from the experimental legacy iOS builds back to the
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
            key.startsWith('ios_game_emulator_v1:')) {
          await prefs.remove(key);
        }
      }

      await prefs.setBool(_cleanRollbackKey, true);
      _log.i(
        'RetroArch rollback: removed legacy iOS routing state; TestFlight only.',
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

  /// Loads the last-synced library from disk into memory, if not already
  /// loaded this session. Call once at startup so [launchGameByRomPath]
  /// works without needing a fresh sync every cold launch.
  static Future<void> loadCachedLibrary() async {
    await _runCleanRollbackMigration();
    if (_cache != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) {
        _cache = {};
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _cache = decoded.map(
          (key, value) =>
              MapEntry(key.toString(), Map<String, dynamic>.from(value as Map)),
        );
      } else {
        _cache = {};
      }
    } catch (e) {
      _log.e('RetroArchLibraryService: failed loading cached library: $e');
      _cache = {};
    }
  }

  static Future<void> _persist(Map<String, Map<String, dynamic>> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(data));
    } catch (e) {
      _log.e('RetroArchLibraryService: failed persisting library cache: $e');
    }
  }

  /// Whether a library sync has ever completed (so the UI can prompt the
  /// user to sync if not).
  static bool get hasSyncedLibrary => (_cache?.isNotEmpty ?? false);

  /// Attempts a genuine one-tap launch for [romPath] via RetroArch's
  /// `retroarch://game/<filename>` scheme, matching against the
  /// last-synced library by filename. Returns `true` only if a match was
  /// found AND the URL was opened — callers should fall back to another
  /// launch path otherwise (see GameLaunchService).
  static Future<bool> launchGameByRomPath(String romPath) async {
    final cache = _cache;
    if (cache == null || cache.isEmpty) {
      await _writeDebugFile(
        'launch_debug.txt',
        'romPath: $romPath\ncache is null or empty (no sync done yet?)',
      );
      return false;
    }

    final basename = path.basename(romPath);
    final entry = _entryForRomPath(cache, romPath);

    await _writeDebugFile(
      'launch_debug.txt',
      'romPath: $romPath\n'
          'basename looked up: $basename\n'
          'match found: ${entry != null}\n'
          'matched entry: ${entry != null ? jsonEncode(entry) : "none"}\n'
          'all cache keys (${cache.length}):\n'
          '${cache.keys.join('\n')}',
    );

    if (entry == null) return false;

    final filename = (entry['filename'] ?? entry['titleId'])?.toString();
    if (filename == null || filename.isEmpty) return false;

    final uri = Uri(
      scheme: 'retroarch',
      host: 'game',
      pathSegments: [filename],
    );

    try {
      return await launchUrl(uri);
    } catch (e) {
      _log.e('RetroArchLibraryService: failed to launch $uri: $e');
      return false;
    }
  }

  /// Writes diagnostic info to a plain text file under the app's Documents
  /// folder, readable via the Files app ("On My iPhone > NeoStation >
  /// <name>") — there's no Xcode console access to check this otherwise.
  static Future<void> _writeDebugFile(String name, String content) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final file = File(path.join(docsDir.path, name));
      await file.writeAsString('--- ${DateTime.now()} ---\n$content');
    } catch (e) {
      _log.e('RetroArchLibraryService: failed writing debug file $name: $e');
    }
  }
}
