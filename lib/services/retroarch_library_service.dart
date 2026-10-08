import 'dart:convert';
import 'dart:io';

import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:external_folder_access/external_folder_access.dart';
import 'package:neostation/services/retroarch_library_protocol.dart';
import 'package:neostation/services/retroarch_library_importer.dart';
import 'package:neostation/services/retroarch_folder_recovery.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
export 'package:neostation/services/retroarch_library_protocol.dart'
    show RetroArchSyncOutcome;
import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/diagnostics_directory.dart';

enum RetroArchLaunchStage {
  cacheEmpty,
  entryMissing,
  invalidEntry,
  ambiguousEntry,
  launchBusy,
  handoffRejected,
  handoffError,
  handoffAccepted,
}

/// RetroArch's external URL protocol has no game-start acknowledgement.
/// An accepted handoff is deliberately not a claim that a core is running.
class RetroArchLaunchAttempt {
  const RetroArchLaunchAttempt(this.stage, this.details);
  final RetroArchLaunchStage stage;
  final String details;
  bool get accepted => stage == RetroArchLaunchStage.handoffAccepted;
}

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
  static final _sync = RetroArchSyncController();
  static RetroArchSyncOutcome? get lastSyncOutcome => _sync.lastOutcome;

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
  static bool _launchPending = false;

  /// Waits for a real, validated library response. Opening the URL alone is
  /// never reported as a completed sync. Failure preserves the previous cache.
  static Future<bool> requestLibrarySync() async {
    await loadCachedLibrary();
    final outcome = await _sync.request(() async {
      final started = DateTime.now().toUtc().toIso8601String();
      _log.i('RetroArchSync stage=requested time=$started');
      await _writeDebugFile(
        'retroarch_sync_status_debug.txt',
        'time: $started\nstage: requested\ncallbackReceived: false',
      );
      try {
        final accepted = await ExternalFolderAccess.openRetroArchUrl(
          'retroarch://library?scheme=$_callbackScheme',
          preserveErrors: true,
        );
        _log.i(
          'RetroArchSync stage=transportCompleted accepted=$accepted '
          '(does not confirm callback delivery)',
        );
        return accepted;
      } catch (error) {
        _log.e('RetroArchSync stage=transportFailed error=$error');
        rethrow;
      }
    });
    _log.i(
      'RetroArchSync stage=finished outcome=${outcome.name} '
      'transportError=${_sync.lastTransportError}',
    );
    await _writeDebugFile(
      'retroarch_sync_status_debug.txt',
      'time: ${DateTime.now().toUtc().toIso8601String()}\n'
          'outcome: ${outcome.name}\ncacheKeys: ${_cache?.length ?? 0}\n'
          'transportError: ${_sync.lastTransportError}',
    );
    return outcome == RetroArchSyncOutcome.synced;
  }

  /// Call this with every incoming URI the app receives (from
  /// the native external_folder_access listener). Returns `true` if the
  /// URI was RetroArch's library callback and was handled.
  static Future<bool> handleIncomingUri(Uri uri) async {
    if (uri.scheme != _callbackScheme || uri.host != 'retroarch') {
      return false;
    }

    final gamesParam = uri.queryParameters['games'];
    _log.i(
      'RetroArchSync stage=callbackReceived '
      'time=${DateTime.now().toUtc().toIso8601String()} '
      'payloadCharacters=${gamesParam?.length ?? 0} '
      'requestPending=${_sync.isPending}',
    );
    if (gamesParam == null) {
      _log.w('RetroArchLibraryService: callback with no "games" param');
      _sync.complete(RetroArchSyncOutcome.invalid);
      return true;
    }

    try {
      final decoded = RetroArchLibraryProtocol.decode(gamesParam);
      if (decoded.isEmpty) {
        // RetroArch can export [] before its runloop/playlists are ready.
        // Keep launch metadata from the last successful export in this case.
        _log.w('RetroArch exported an empty library; previous cache retained');
        _sync.complete(RetroArchSyncOutcome.empty);
        return true;
      }
      final byFilename = RetroArchLibraryProtocol.index(decoded);

      // SQLite restoration must succeed before the sync reports success.
      final imported = await _restoreEntries(decoded);
      if (imported == 0) {
        throw StateError('No supported system found in RetroArch export');
      }
      await _persist(byFilename);
      _cache = byFilename;
      _sync.complete(RetroArchSyncOutcome.synced);
      _log.i(
        'RetroArchLibraryService: synced ${decoded.length} games from RetroArch',
      );
      await _writeDebugFile(
        'sync_debug.txt',
        'Synced ${decoded.length} games.\n\n'
            'Raw entries:\n${const JsonEncoder.withIndent('  ').convert(decoded)}',
      );

      // Refresh the catalog directly. An unavailable external folder must not
      // prevent a successful URL export from making its games visible.
      try {
        final context = rootNavigatorKey.currentContext;
        if (context != null && context.mounted) {
          await Provider.of<SqliteConfigProvider>(
            context,
            listen: false,
          ).refreshLibraryCatalog();
        }
      } catch (e) {
        _log.e('RetroArchLibraryService: post-sync catalog refresh failed: $e');
      }

      return true;
    } catch (e) {
      _log.e('RetroArchLibraryService: failed to parse library callback: $e');
      _sync.complete(RetroArchSyncOutcome.invalid);
      return true;
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
    final uri = Uri.tryParse(romPath);
    if (uri?.scheme == 'retroarch-library' && uri!.pathSegments.length == 2) {
      final exact = cache[romPath];
      if (exact != null) return exact;
      // Older cache versions have no namespaced identity keys.
      for (final entry in cache.values) {
        if (entry['system'] == uri.pathSegments[0] &&
            (entry['filename'] ?? entry['titleId']) == uri.pathSegments[1]) {
          return entry;
        }
      }
      return null;
    }
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

  static Future<int> _restoreEntries(
    Iterable<Map<String, dynamic>> entries,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final root = prefs.getString(RetroArchFolderRecovery.rootKey);
    return RetroArchLibraryImporter.restore(
      await SqliteService.getDatabase(),
      entries,
      ownedRoots: root == null ? const [] : [root],
    );
  }

  /// Rebuild the visible index from the last valid export after a failed scan
  /// or a container change. This does not replace or clear the launch cache.
  static Future<void> restoreCachedLibrary() async {
    await loadCachedLibrary();
    if (_cache == null || _cache!.isEmpty) return;
    try {
      final count = await _restoreEntries(_cache!.values);
      _log.i('RetroArch cached library restored: $count games');
    } catch (error) {
      _log.e('RetroArch cached library restoration failed: $error');
    }
  }

  static Future<void> _persist(Map<String, Map<String, dynamic>> data) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(_prefsKey, jsonEncode(data));
    if (!saved) throw StateError('RetroArch library cache could not be saved');
  }

  /// Whether a library sync has ever completed (so the UI can prompt the
  /// user to sync if not).
  static bool get hasSyncedLibrary => (_cache?.isNotEmpty ?? false);

  /// Attempts a genuine one-tap launch for [romPath] via RetroArch's
  /// `retroarch://game/<filename>` scheme, matching against the
  /// last-synced library by filename. Returns `true` only if a match was
  /// found AND iOS accepted the URL. This is not a game-start acknowledgement.
  static Future<bool> launchGameByRomPath(String romPath) async =>
      (await launchGameWithDiagnostics(romPath)).accepted;

  static Future<RetroArchLaunchAttempt> launchGameWithDiagnostics(
    String romPath, {
    Future<bool> Function(String)? openUrl,
  }) async {
    if (_launchPending) {
      return const RetroArchLaunchAttempt(
        RetroArchLaunchStage.launchBusy,
        'A RetroArch launch is already awaiting its handoff.',
      );
    }
    _launchPending = true;
    try {
      return await _launchGameWithDiagnostics(romPath, openUrl: openUrl);
    } finally {
      _launchPending = false;
    }
  }

  static Future<RetroArchLaunchAttempt> _launchGameWithDiagnostics(
    String romPath, {
    Future<bool> Function(String)? openUrl,
  }) async {
    final attempt = DateTime.now().microsecondsSinceEpoch;
    Future<RetroArchLaunchAttempt> finish(
      RetroArchLaunchStage stage,
      String details,
    ) async {
      final diagnostic =
          'attempt=$attempt stage=${stage.name}\nromPath=$romPath\n$details';
      _log.i('RetroArchLaunch $diagnostic');
      await _writeDebugFile('launch_debug.txt', diagnostic);
      return RetroArchLaunchAttempt(stage, diagnostic);
    }

    if (_cache == null) await loadCachedLibrary();
    final cache = _cache;
    if (cache == null || cache.isEmpty) {
      return finish(
        RetroArchLaunchStage.cacheEmpty,
        'No persisted RetroArch export is available. Synchronize the library.',
      );
    }
    final entry = _entryForRomPath(cache, romPath);
    if (entry == null) {
      return finish(
        RetroArchLaunchStage.entryMissing,
        'cacheKeys=${cache.length}\nNo matching export entry. Synchronize the library.',
      );
    }

    final filename = (entry['filename'] ?? entry['titleId'])?.toString();
    if (filename == null || filename.isEmpty) {
      return finish(
        RetroArchLaunchStage.invalidEntry,
        'Export has no launch filename.',
      );
    }

    // RetroArch's verified dispatcher takes only a filename and chooses its
    // first match globally. A namespaced UI key cannot disambiguate that URL.
    final matches = <String>{};
    for (final candidate in cache.values) {
      if ((candidate['filename'] ?? candidate['titleId']) == filename) {
        matches.add(candidate['gameId']?.toString() ?? jsonEncode(candidate));
      }
    }
    if (matches.length > 1) {
      return finish(
        RetroArchLaunchStage.ambiguousEntry,
        'launchFilename=$filename\nexportRecords=${matches.length}\n'
        'The external filename-only route cannot identify this content uniquely. '
        'Select the exact playlist entry inside RetroArch.',
      );
    }

    final uri = Uri(
      scheme: 'retroarch',
      host: 'game',
      pathSegments: [filename],
    );

    final details =
        'entry=${jsonEncode(entry)}\nurl=$uri\n'
        'Content, core and BIOS validation belong to external RetroArch; '
        'this protocol provides no game-start acknowledgement.';
    _log.i('RetroArchLaunch attempt=$attempt stage=handoffRequested $details');
    try {
      final opened =
          await (openUrl ??
              (url) => ExternalFolderAccess.openRetroArchUrl(
                url,
                preserveErrors: true,
              ))(uri.toString());
      return await finish(
        opened
            ? RetroArchLaunchStage.handoffAccepted
            : RetroArchLaunchStage.handoffRejected,
        details,
      );
    } catch (e) {
      return finish(RetroArchLaunchStage.handoffError, '$details\nerror=$e');
    }
  }

  /// Writes diagnostic info to a plain text file under the app's Documents
  /// folder, readable via the Files app ("On My iPhone > NeoStation >
  /// <name>") — there's no Xcode console access to check this otherwise.
  static Future<void> _writeDebugFile(String name, String content) async {
    try {
      final file = await DiagnosticsDirectory.file(name);
      await file.writeAsString('--- ${DateTime.now()} ---\n$content');
    } catch (e) {
      _log.e('RetroArchLibraryService: failed writing debug file $name: $e');
    }
  }
}
