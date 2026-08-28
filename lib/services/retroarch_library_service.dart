import 'dart:convert';
import 'dart:io';

import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/sqlite_database_provider.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Integrates both iOS RetroArch distribution variants without allowing one
/// variant's library state to leak into the other.
///
/// RetroArch TestFlight exposes a library-export callback protocol:
///
///   retroarch://library?scheme=neostation
///   -> neostation://retroarch?games=<base64url>
///
/// The App Store build must not depend on that callback. NeoStation instead
/// builds its App Store launch index from the security-scoped RetroArch folder
/// already selected by the user. It first reads RetroArch's own `.lpl`
/// playlists and, when they are not reachable from the selected folder, falls
/// back to indexing ROM files in the linked folder.
///
/// Both indexes are persisted separately and are tied to their source folder.
/// Changing from App Store to TestFlight (or back) therefore cannot reuse stale
/// launch identifiers from the previous installation.
class RetroArchLibraryService {
  RetroArchLibraryService._();

  static final _log = LoggerService.instance;

  static const String _callbackScheme = 'neostation';
  static const String _callbackHost = 'retroarch';

  static const String _legacyPrefsKey = 'retroarch_library_cache_v1';
  static const String _linkedPrefsKey = 'retroarch_linked_library_cache_v2';
  static const String _linkedRootPrefsKey = 'retroarch_linked_library_root_v2';
  static const String _testFlightPrefsKey =
      'retroarch_testflight_library_cache_v2';
  static const String _testFlightRootPrefsKey =
      'retroarch_testflight_library_root_v2';

  static const Set<String> _playlistFilesToSkip = {
    'content_history.lpl',
    'content_image_history.lpl',
    'content_music_history.lpl',
    'content_video_history.lpl',
    'favorites.lpl',
  };

  /// Lookup keys -> entries obtained from the linked RetroArch folder. This is
  /// the App Store-compatible source and is safe for TestFlight too when its
  /// playlist folder is visible.
  static Map<String, Map<String, dynamic>> _linkedCache = {};

  /// Lookup keys -> entries received specifically through the TestFlight
  /// `neostation://retroarch` callback.
  static Map<String, Map<String, dynamic>> _testFlightCache = {};

  static String? _linkedSourceRoot;
  static String? _testFlightSourceRoot;
  static bool _loaded = false;

  /// Synchronizes RetroArch using the source that is actually available.
  ///
  /// A linked folder is always attempted first. This is the App Store path and
  /// deliberately does not invoke the TestFlight export protocol. If no local
  /// RetroArch library can be built, NeoStation then falls back to TestFlight's
  /// callback-based export.
  static Future<bool> requestLibrarySync() async {
    await loadCachedLibrary();

    final linkedCount = await syncLinkedLibraryFromDisk();
    if (linkedCount > 0) {
      _log.i(
        'RetroArchLibraryService: synchronized $linkedCount game(s) from the '
        'linked RetroArch folder; TestFlight callback was not requested.',
      );
      return true;
    }

    return _requestTestFlightLibrarySync();
  }

  static Future<bool> _requestTestFlightLibrarySync() async {
    final uri = Uri.parse(
      'retroarch://library?scheme=$_callbackScheme',
    );

    await _writeDebugFile(
      'retroarch_testflight_sync_debug.txt',
      'STATE: REQUESTED\n'
          'Request URL: $uri\n'
          'Expected callback: $_callbackScheme://$_callbackHost?games=...\n'
          'Linked folder did not provide a usable local index, so NeoStation '
          'is using the TestFlight export protocol.',
    );

    try {
      final reportedOpened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!reportedOpened && Platform.isIOS) {
        _log.w(
          'RetroArch TestFlight sync handoff reported false after iOS dispatch.',
        );
        return true;
      }
      return reportedOpened;
    } catch (e) {
      _log.e('RetroArchLibraryService: TestFlight sync request failed: $e');
      return false;
    }
  }

  /// Builds the App Store-compatible RetroArch index from the currently linked
  /// folder. Returns the number of unique library entries discovered.
  ///
  /// [updateNeoStation] is exposed so unit tests can validate the file/index
  /// behavior without initializing the application database.
  static Future<int> syncLinkedLibraryFromDisk({
    bool updateNeoStation = true,
  }) async {
    final root = ConfigService.linkedExternalFolderPath;
    if (root == null || root.trim().isEmpty) {
      return 0;
    }

    final normalizedRoot = path.normalize(root);
    final entries = await _readLinkedPlaylistEntries(normalizedRoot);

    // Some App Store installations expose the ROM directory but keep their
    // RetroArch configuration/playlists outside the selected security scope.
    // In that case a filename index still gives retroarch://game/<filename> a
    // deterministic direct-launch value without involving TestFlight sync.
    if (entries.isEmpty) {
      entries.addAll(await _readLinkedRomEntries(normalizedRoot));
    }

    final byFilename = <String, Map<String, dynamic>>{};
    for (final entry in entries) {
      _indexEntry(byFilename, entry);
    }

    _linkedCache = byFilename;
    _linkedSourceRoot = normalizedRoot;
    _loaded = true;
    await _persistLinkedCache();

    if (updateNeoStation && entries.isNotEmpty) {
      try {
        await _rescanNeoStation();
        final touched = await _importPhysicalEntries(entries);
        await _refreshNeoStationUi(touched);
      } catch (e, stack) {
        // A launch index is still useful even when database import fails. Do
        // not turn a valid App Store sync into a failure because UI refresh or
        // a legacy DB row rejected an update.
        _log.e(
          'RetroArchLibraryService: linked-library DB import failed: $e\n$stack',
        );
      }
    }

    await _writeDebugFile(
      'retroarch_appstore_sync_debug.txt',
      'STATE: LOCAL_INDEX_READY\n'
          'Linked root: $normalizedRoot\n'
          'Unique library entries: ${entries.length}\n'
          'Index keys: ${byFilename.length}\n'
          'Source: ${entries.isEmpty ? 'none' : entries.first['sourceKind']}',
    );

    return entries.length;
  }

  /// Handles TestFlight's library callback. The export cache is deliberately
  /// separate from the linked-folder/App Store cache.
  static Future<bool> handleIncomingUri(Uri uri) async {
    if (uri.scheme.toLowerCase() != _callbackScheme ||
        uri.host.toLowerCase() != _callbackHost) {
      return false;
    }

    final gamesParam = uri.queryParameters['games'];
    if (gamesParam == null || gamesParam.isEmpty) {
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

      final games = <Map<String, dynamic>>[];
      final byFilename = <String, Map<String, dynamic>>{};
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final entry = Map<String, dynamic>.from(raw);
        final filename = (entry['filename'] ?? entry['titleId'])?.toString();
        if (filename == null || filename.isEmpty) continue;

        entry['sourceKind'] = 'testflight-export';
        games.add(entry);
        _indexEntry(byFilename, entry);
      }

      _testFlightCache = byFilename;
      _testFlightSourceRoot = _normalizedCurrentRoot();
      _loaded = true;
      await _persistTestFlightCache();

      try {
        // Preserve NeoStation's ordinary scanner, then supplement it with the
        // exported TestFlight entries. This is what prevents a successful
        // TestFlight sync from leaving the visible NeoStation library empty.
        await _rescanNeoStation();
        final touched = await _importPhysicalEntries(games);
        await _refreshNeoStationUi(touched);
      } catch (e, stack) {
        _log.e(
          'RetroArchLibraryService: TestFlight DB import failed: $e\n$stack',
        );
      }

      _log.i(
        'RetroArchLibraryService: synchronized ${games.length} TestFlight '
        'game(s) with an isolated export cache.',
      );
      await _writeDebugFile(
        'retroarch_testflight_sync_debug.txt',
        'STATE: CALLBACK_IMPORTED\n'
            'Games received: ${games.length}\n'
            'Linked root at callback: ${_testFlightSourceRoot ?? 'none'}\n\n'
            'Raw entries:\n'
            '${const JsonEncoder.withIndent('  ').convert(games)}',
      );
      return true;
    } catch (e, stack) {
      _log.e(
        'RetroArchLibraryService: failed to parse TestFlight callback: '
        '$e\n$stack',
      );
      return false;
    }
  }

  /// Loads both persisted sources. A linked-folder cache is only activated if
  /// it belongs to the folder currently bookmarked by NeoStation.
  static Future<void> loadCachedLibrary({bool forceReload = false}) async {
    if (_loaded && !forceReload) return;

    _linkedCache = {};
    _testFlightCache = {};
    _linkedSourceRoot = null;
    _testFlightSourceRoot = null;

    try {
      final prefs = await SharedPreferences.getInstance();
      final currentRoot = _normalizedCurrentRoot();

      final linkedRoot = prefs.getString(_linkedRootPrefsKey);
      final linkedRaw = prefs.getString(_linkedPrefsKey);
      if (linkedRaw != null && _sameRoot(linkedRoot, currentRoot)) {
        _linkedCache = _decodeCache(linkedRaw);
        _linkedSourceRoot = linkedRoot == null ? null : path.normalize(linkedRoot);
      }

      final testFlightRaw = prefs.getString(_testFlightPrefsKey);
      final testFlightRoot = prefs.getString(_testFlightRootPrefsKey);
      if (testFlightRaw != null) {
        _testFlightCache = _decodeCache(testFlightRaw);
        _testFlightSourceRoot = testFlightRoot == null
            ? null
            : path.normalize(testFlightRoot);
      } else {
        // One-way compatibility read. The old shared cache is treated as a
        // TestFlight cache with no trusted folder association, so it can never
        // override a newly linked App Store folder.
        final legacyRaw = prefs.getString(_legacyPrefsKey);
        if (legacyRaw != null) {
          _testFlightCache = _decodeCache(legacyRaw);
        }
      }
    } catch (e) {
      _log.e('RetroArchLibraryService: failed loading caches: $e');
      _linkedCache = {};
      _testFlightCache = {};
    }

    _loaded = true;
  }

  /// Clears all NeoStation-owned RetroArch caches. RetroArch's own files are
  /// never touched.
  static Future<void> clearCachedLibrary() async {
    _linkedCache = {};
    _testFlightCache = {};
    _linkedSourceRoot = null;
    _testFlightSourceRoot = null;
    _loaded = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_legacyPrefsKey);
      await prefs.remove(_linkedPrefsKey);
      await prefs.remove(_linkedRootPrefsKey);
      await prefs.remove(_testFlightPrefsKey);
      await prefs.remove(_testFlightRootPrefsKey);
    } catch (e) {
      _log.e('RetroArchLibraryService: failed clearing caches: $e');
    }
  }

  static Map<String, Map<String, dynamic>> _decodeCache(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return decoded.map(
      (key, value) => MapEntry(
        key.toString(),
        Map<String, dynamic>.from(value as Map),
      ),
    );
  }

  static Future<void> _persistLinkedCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_linkedPrefsKey, jsonEncode(_linkedCache));
      if (_linkedSourceRoot == null) {
        await prefs.remove(_linkedRootPrefsKey);
      } else {
        await prefs.setString(_linkedRootPrefsKey, _linkedSourceRoot!);
      }
    } catch (e) {
      _log.e('RetroArchLibraryService: failed persisting linked cache: $e');
    }
  }

  static Future<void> _persistTestFlightCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_testFlightPrefsKey, jsonEncode(_testFlightCache));
      if (_testFlightSourceRoot == null) {
        await prefs.remove(_testFlightRootPrefsKey);
      } else {
        await prefs.setString(
          _testFlightRootPrefsKey,
          _testFlightSourceRoot!,
        );
      }
      // Once a v2 TestFlight cache exists the ambiguous shared cache must no
      // longer participate in routing.
      await prefs.remove(_legacyPrefsKey);
    } catch (e) {
      _log.e('RetroArchLibraryService: failed persisting TestFlight cache: $e');
    }
  }

  /// Whether either isolated RetroArch source contains a usable game index.
  static bool get hasSyncedLibrary =>
      _linkedCache.isNotEmpty || _testFlightCache.isNotEmpty;

  static bool hasGameForRomPath(String romPath) {
    final currentRoot = _normalizedCurrentRoot();
    final inLinkedRoot = _pathBelongsToRoot(romPath, currentRoot);

    if (_sameRoot(_linkedSourceRoot, currentRoot) &&
        _findEntry(_linkedCache, romPath) != null) {
      return true;
    }

    // A TestFlight cache may only claim a ROM inside the active linked folder
    // when that cache was exported while the exact same folder was active.
    // This is the key guard that prevents App Store/TestFlight cache leakage.
    if (inLinkedRoot) {
      if (_sameRoot(_testFlightSourceRoot, currentRoot) &&
          _findEntry(_testFlightCache, romPath) != null) {
        return true;
      }
      try {
        return File(romPath).existsSync();
      } catch (_) {
        return false;
      }
    }

    return _findEntry(_testFlightCache, romPath) != null;
  }

  /// Launches a game without ever falling through to iOS's share sheet when
  /// the ROM belongs to the actively linked RetroArch folder.
  ///
  /// Linked-folder/App Store entries win. TestFlight entries are considered
  /// for a linked ROM only if their persisted source root matches the current
  /// bookmark. Finally, a physical linked ROM can use its own basename as the
  /// App Store launch identifier even when RetroArch's playlist folder was not
  /// visible to NeoStation.
  static Future<bool> launchGameByRomPath(String romPath) async {
    await loadCachedLibrary();

    final currentRoot = _normalizedCurrentRoot();
    final inLinkedRoot = _pathBelongsToRoot(romPath, currentRoot);

    Map<String, dynamic>? entry;
    String source = 'none';

    if (_sameRoot(_linkedSourceRoot, currentRoot)) {
      entry = _findEntry(_linkedCache, romPath);
      if (entry != null) source = 'linked-folder';
    }

    if (entry == null &&
        (!inLinkedRoot || _sameRoot(_testFlightSourceRoot, currentRoot))) {
      entry = _findEntry(_testFlightCache, romPath);
      if (entry != null) source = 'testflight-export';
    }

    if (entry == null && inLinkedRoot) {
      try {
        if (await File(romPath).exists()) {
          entry = {
            'filename': path.basename(romPath),
            'titleId': path.basename(romPath),
            'sourceKind': 'linked-file-fallback',
          };
          source = 'linked-file-fallback';
        }
      } catch (_) {
        // No readable physical file means there is no safe App Store fallback.
      }
    }

    if (entry == null) {
      await _writeDebugFile(
        'launch_debug.txt',
        'romPath: $romPath\n'
            'RESULT: no matching isolated RetroArch entry\n'
            'currentRoot: ${currentRoot ?? 'none'}\n'
            'linkedCacheRoot: ${_linkedSourceRoot ?? 'none'}\n'
            'testFlightCacheRoot: ${_testFlightSourceRoot ?? 'none'}',
      );
      return false;
    }

    final filename = (entry['filename'] ?? entry['titleId'])?.toString();
    if (filename == null || filename.isEmpty) return false;

    final uri = Uri(
      scheme: 'retroarch',
      host: 'game',
      pathSegments: [filename],
    );

    await _writeDebugFile(
      'launch_debug.txt',
      'romPath: $romPath\n'
          'source: $source\n'
          'launch filename: $filename\n'
          'launch URI: $uri\n'
          'entry: ${jsonEncode(entry)}',
    );

    try {
      final reportedOpened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!reportedOpened) {
        _log.w(
          'RetroArchLibraryService: $uri was dispatched but url_launcher '
          'reported false. The direct RetroArch handoff is considered final '
          'so GameLaunchService will not present Open In / Share.',
        );
      }
      return true;
    } catch (e) {
      _log.e('RetroArchLibraryService: failed to launch $uri: $e');
      return false;
    }
  }

  static Map<String, dynamic>? _findEntry(
    Map<String, Map<String, dynamic>> cache,
    String romPath,
  ) {
    if (cache.isEmpty) return null;
    final basename = path.basename(romPath);
    final stem = path.basenameWithoutExtension(romPath);
    return cache[romPath] ??
        cache[romPath.toLowerCase()] ??
        cache[basename] ??
        cache[basename.toLowerCase()] ??
        cache[stem] ??
        cache[stem.toLowerCase()];
  }

  static void _indexEntry(
    Map<String, Map<String, dynamic>> target,
    Map<String, dynamic> entry,
  ) {
    final filename = (entry['filename'] ?? entry['titleId'])?.toString();
    final sourcePath = entry['sourcePath']?.toString();

    if (filename != null && filename.isNotEmpty) {
      _putIndexKey(target, filename, entry);
      _putIndexKey(target, path.basename(filename), entry);

      final hashIndex = filename.indexOf('#');
      if (hashIndex > 0) {
        final archivePart = filename.substring(0, hashIndex);
        _putIndexKey(target, path.basename(archivePart), entry);
        _putIndexKey(
          target,
          path.basenameWithoutExtension(archivePart),
          entry,
        );
      }

      _putIndexKey(target, path.basenameWithoutExtension(filename), entry);
    }

    if (sourcePath != null && sourcePath.isNotEmpty) {
      _putIndexKey(target, sourcePath, entry);
      final physicalPart = _archiveContainerPath(sourcePath);
      _putIndexKey(target, path.basename(physicalPart), entry);
      _putIndexKey(
        target,
        path.basenameWithoutExtension(physicalPart),
        entry,
      );
    }
  }

  static void _putIndexKey(
    Map<String, Map<String, dynamic>> target,
    String key,
    Map<String, dynamic> entry,
  ) {
    if (key.isEmpty) return;
    target.putIfAbsent(key, () => entry);
    target.putIfAbsent(key.toLowerCase(), () => entry);
  }

  static Future<List<Map<String, dynamic>>> _readLinkedPlaylistEntries(
    String root,
  ) async {
    final playlistsDir = await _findPlaylistsDirectory(root);
    if (playlistsDir == null) return <Map<String, dynamic>>[];

    final entries = <Map<String, dynamic>>[];
    try {
      await for (final entity in playlistsDir.list(followLinks: false)) {
        if (entity is! File ||
            path.extension(entity.path).toLowerCase() != '.lpl') {
          continue;
        }

        final fileName = path.basename(entity.path);
        if (_playlistFilesToSkip.contains(fileName.toLowerCase())) continue;
        final playlistName = path.basenameWithoutExtension(fileName);

        try {
          final decoded = jsonDecode(await entity.readAsString());
          if (decoded is! Map) continue;
          final items = decoded['items'];
          if (items is! List) continue;

          for (final rawItem in items) {
            if (rawItem is! Map) continue;
            final item = Map<String, dynamic>.from(rawItem);
            final contentPath = item['path']?.toString();
            if (contentPath == null || contentPath.isEmpty) continue;

            final launchFilename = _launchFilenameForContentPath(contentPath);
            if (launchFilename.isEmpty) continue;

            entries.add({
              'filename': launchFilename,
              'titleId': launchFilename,
              'titleName': item['label']?.toString(),
              'system': item['db_name']?.toString() ?? playlistName,
              'coreName': item['core_name']?.toString(),
              'sourcePath': contentPath,
              'sourceKind': 'appstore-playlist',
            });
          }
        } catch (e) {
          _log.w(
            'RetroArchLibraryService: skipping unreadable playlist '
            '${entity.path}: $e',
          );
        }
      }
    } catch (e) {
      _log.w(
        'RetroArchLibraryService: could not enumerate playlists at '
        '${playlistsDir.path}: $e',
      );
    }

    return _dedupeEntries(entries);
  }

  static Future<Directory?> _findPlaylistsDirectory(String root) async {
    final candidates = <String>[
      if (path.basename(root).toLowerCase() == 'playlists') root,
      path.join(root, 'playlists'),
      path.join(path.dirname(root), 'playlists'),
      path.join(path.dirname(path.dirname(root)), 'playlists'),
    ];

    final seen = <String>{};
    for (final candidate in candidates) {
      final normalized = path.normalize(candidate);
      if (!seen.add(normalized)) continue;
      final directory = Directory(normalized);
      try {
        if (await directory.exists()) return directory;
      } catch (_) {
        // Security scope may not include this candidate; try the next one.
      }
    }
    return null;
  }

  static Future<List<Map<String, dynamic>>> _readLinkedRomEntries(
    String root,
  ) async {
    Set<String> validExtensions = {};
    try {
      validExtensions = (await SystemRepository.getAllValidExtensions())
          .map(_normalizeExtension)
          .where((value) => value.isNotEmpty)
          .toSet();
    } catch (e) {
      _log.w(
        'RetroArchLibraryService: could not load system extensions for local '
        'fallback index: $e',
      );
    }

    final entries = <Map<String, dynamic>>[];
    final directory = Directory(root);
    try {
      if (!await directory.exists()) return entries;
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final extension = _normalizeExtension(path.extension(entity.path));
        if (validExtensions.isNotEmpty &&
            !validExtensions.contains(extension)) {
          continue;
        }
        if (extension.isEmpty) continue;

        final filename = path.basename(entity.path);
        entries.add({
          'filename': filename,
          'titleId': filename,
          'titleName': path.basenameWithoutExtension(filename),
          'sourcePath': entity.path,
          'sourceKind': 'appstore-linked-files',
        });
      }
    } catch (e) {
      _log.w(
        'RetroArchLibraryService: could not enumerate linked ROM folder '
        '$root: $e',
      );
    }

    return _dedupeEntries(entries);
  }

  static List<Map<String, dynamic>> _dedupeEntries(
    List<Map<String, dynamic>> entries,
  ) {
    final deduped = <String, Map<String, dynamic>>{};
    for (final entry in entries) {
      final filename = (entry['filename'] ?? entry['titleId'])?.toString();
      final sourcePath = entry['sourcePath']?.toString() ?? '';
      if (filename == null || filename.isEmpty) continue;
      final key = '${filename.toLowerCase()}|${sourcePath.toLowerCase()}';
      deduped.putIfAbsent(key, () => entry);
    }
    return deduped.values.toList();
  }

  static String _launchFilenameForContentPath(String contentPath) {
    final normalized = contentPath.replaceAll('\\', '/');
    final slashIndex = normalized.lastIndexOf('/');
    return slashIndex >= 0 ? normalized.substring(slashIndex + 1) : normalized;
  }

  static String _archiveContainerPath(String value) {
    final hashIndex = value.indexOf('#');
    return hashIndex > 0 ? value.substring(0, hashIndex) : value;
  }

  static Future<Set<String>> _importPhysicalEntries(
    List<Map<String, dynamic>> entries,
  ) async {
    final root = _normalizedCurrentRoot();
    if (root == null || entries.isEmpty) return <String>{};

    final systems = await SystemRepository.getAllSystems();
    if (systems.isEmpty) return <String>{};

    final linkedFiles = await _buildLinkedFileIndex(root);
    final db = await SqliteService.getDatabase();
    final touched = <String>{};
    final touchedSystems = <String, SystemModel>{};

    await db.transaction((txn) async {
      for (final entry in entries) {
        final physicalPath = await _resolvePhysicalPath(entry, linkedFiles);
        if (physicalPath == null) continue;

        final system = _resolveSystem(entry, physicalPath, systems);
        if (system?.id == null) continue;

        final fileName = path.basename(physicalPath);
        final titleId = entry['titleId']?.toString();
        final titleName = entry['titleName']?.toString();

        await txn.rawInsert(
          '''
          INSERT INTO user_roms
            (app_system_id, app_emulator_unique_id, app_emulator_os_id,
             filename, rom_path, title_id, title_name, created_at, updated_at)
          VALUES (?, NULL, NULL, ?, ?, ?, ?, datetime('now'), datetime('now'))
          ON CONFLICT(rom_path) DO UPDATE SET
            app_system_id = excluded.app_system_id,
            filename = excluded.filename,
            title_id = CASE
              WHEN user_roms.title_id IS NULL OR user_roms.title_id = ''
              THEN excluded.title_id ELSE user_roms.title_id END,
            title_name = CASE
              WHEN user_roms.title_name IS NULL OR user_roms.title_name = ''
              THEN excluded.title_name ELSE user_roms.title_name END,
            updated_at = datetime('now')
          ''',
          [system!.id!, fileName, physicalPath, titleId, titleName],
        );

        touched.add(system.folderName);
        touchedSystems[system.folderName] = system;
      }
    });

    for (final entry in touchedSystems.entries) {
      final system = entry.value;
      await SystemRepository.addDetectedSystem(system.id!, system.folderName);
    }

    return touched;
  }

  static Future<Map<String, List<String>>> _buildLinkedFileIndex(
    String root,
  ) async {
    final index = <String, List<String>>{};
    final directory = Directory(root);
    try {
      if (!await directory.exists()) return index;
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final basename = path.basename(entity.path).toLowerCase();
        final stem = path.basenameWithoutExtension(entity.path).toLowerCase();
        index.putIfAbsent(basename, () => <String>[]).add(entity.path);
        index.putIfAbsent(stem, () => <String>[]).add(entity.path);
      }
    } catch (e) {
      _log.w(
        'RetroArchLibraryService: failed building linked file index: $e',
      );
    }
    return index;
  }

  static Future<String?> _resolvePhysicalPath(
    Map<String, dynamic> entry,
    Map<String, List<String>> fileIndex,
  ) async {
    final exportedSourcePath = entry['sourcePath']?.toString();
    if (exportedSourcePath != null && exportedSourcePath.isNotEmpty) {
      final physical = _archiveContainerPath(exportedSourcePath);
      try {
        if (await File(physical).exists()) return path.normalize(physical);
      } catch (_) {
        // Fall back to basename lookup below.
      }
    }

    final filename = (entry['filename'] ?? entry['titleId'])?.toString();
    if (filename == null || filename.isEmpty) return null;
    final physicalName = path.basename(_archiveContainerPath(filename));
    final basenameKey = physicalName.toLowerCase();
    final stemKey = path.basenameWithoutExtension(physicalName).toLowerCase();

    final candidates = fileIndex[basenameKey] ?? fileIndex[stemKey];
    if (candidates == null || candidates.isEmpty) return null;
    return path.normalize(candidates.first);
  }

  static SystemModel? _resolveSystem(
    Map<String, dynamic> entry,
    String physicalPath,
    List<SystemModel> systems,
  ) {
    final hint = (entry['system'] ?? entry['db_name'] ?? entry['playlist'])
        ?.toString();
    final hintNormalized = _normalizeSystemName(hint ?? '');

    SystemModel? best;
    var bestScore = 0;
    if (hintNormalized.isNotEmpty) {
      for (final system in systems) {
        if (system.id == null || system.isVirtual) continue;
        final names = <String>[
          system.folderName,
          system.realName,
          if (system.shortName != null) system.shortName!,
        ].map(_normalizeSystemName).where((value) => value.isNotEmpty);

        for (final name in names) {
          var score = 0;
          if (name == hintNormalized) {
            score = 10000 + name.length;
          } else if (hintNormalized.contains(name)) {
            score = 1000 + name.length;
          } else if (name.contains(hintNormalized)) {
            score = 500 + hintNormalized.length;
          }
          if (score > bestScore) {
            best = system;
            bestScore = score;
          }
        }
      }
    }

    if (best != null) return best;

    final extension = _normalizeExtension(path.extension(physicalPath));
    if (extension.isEmpty) return null;
    final matches = systems.where((system) {
      if (system.id == null || system.isVirtual) return false;
      return system.extensions
          .map(_normalizeExtension)
          .contains(extension);
    }).toList();
    return matches.length == 1 ? matches.first : null;
  }

  static String _normalizeSystemName(String value) => value
      .toLowerCase()
      .replaceAll('.lpl', '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '');

  static String _normalizeExtension(String value) =>
      value.toLowerCase().replaceFirst(RegExp(r'^\.+'), '');

  static Future<void> _rescanNeoStation() async {
    try {
      final context = rootNavigatorKey.currentContext;
      if (context == null) return;
      await Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      ).scanSystems();
    } catch (e) {
      _log.e('RetroArchLibraryService: post-sync scan failed: $e');
    }
  }

  static Future<void> _refreshNeoStationUi(Set<String> folderNames) async {
    try {
      final context = rootNavigatorKey.currentContext;
      if (context == null) return;

      final databaseProvider = Provider.of<SqliteDatabaseProvider>(
        context,
        listen: false,
      );
      for (final folderName in folderNames) {
        await databaseProvider.loadGamesForSystem(folderName);
      }
      await Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      ).refreshDetectedSystems();
    } catch (e) {
      _log.e('RetroArchLibraryService: UI refresh failed: $e');
    }
  }

  static String? _normalizedCurrentRoot() {
    final root = ConfigService.linkedExternalFolderPath;
    if (root == null || root.trim().isEmpty) return null;
    return path.normalize(root.trim());
  }

  static bool _sameRoot(String? left, String? right) {
    if (left == null || right == null) return left == right;
    return path.normalize(left).toLowerCase() ==
        path.normalize(right).toLowerCase();
  }

  static bool _pathBelongsToRoot(String romPath, String? root) {
    if (root == null || romPath.isEmpty) return false;
    try {
      return path.equals(root, romPath) || path.isWithin(root, romPath);
    } catch (_) {
      final normalizedRoot = path.normalize(root).toLowerCase();
      final normalizedRom = path.normalize(romPath).toLowerCase();
      return normalizedRom == normalizedRoot ||
          normalizedRom.startsWith('$normalizedRoot${path.separator}');
    }
  }

  /// Writes diagnostic info under NeoStation's Documents folder so device-only
  /// builds can be debugged without an attached Xcode console.
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
