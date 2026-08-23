import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:external_folder_access/external_folder_access.dart';
import 'package:flutter/foundation.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/sqlite_database_provider.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/ios_shortcut_jit_launch_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One GameCube or Wii title discovered in Fin's Files-visible game folder.
class FinLibraryGame {
  const FinLibraryGame({
    required this.fileName,
    required this.relativePath,
    required this.systemFolder,
    required this.title,
    this.gameId,
  });

  final String fileName;
  final String relativePath;
  final String systemFolder;
  final String title;
  final String? gameId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'fileName': fileName,
    'relativePath': relativePath,
    'systemFolder': systemFolder,
    'title': title,
    'gameId': gameId,
  };

  factory FinLibraryGame.fromJson(Map<String, dynamic> json) {
    return FinLibraryGame(
      fileName: json['fileName']?.toString() ?? '',
      relativePath: json['relativePath']?.toString() ?? '',
      systemFolder: json['systemFolder']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      gameId: json['gameId']?.toString(),
    );
  }
}

class FinSyncResult {
  const FinSyncResult({
    required this.discoveredGames,
    required this.gameCubeGames,
    required this.wiiGames,
    required this.skippedGames,
    required this.virtualRows,
    required this.physicalRows,
    required this.removedRows,
  });

  final int discoveredGames;
  final int gameCubeGames;
  final int wiiGames;
  final int skippedGames;
  final int virtualRows;
  final int physicalRows;
  final int removedRows;
}

/// Imports Fin's GameCube/Wii library into NeoStation and launches it through
/// the user-installed `NeoStation+Fin` Apple Shortcut.
///
/// Fin exposes its game files in the Files app. NeoStation bookmarks that
/// folder, classifies each image as GameCube or Wii, and stores virtual
/// `fin://launch?...` rows when no matching physical NeoStation ROM exists.
/// The virtual row carries only a relative path. The Shortcut resolves that
/// path inside Fin/Games and hands the resulting file to Fin's own Shortcuts
/// action, so no unstable iOS sandbox path is persisted.
class FinLibraryService {
  FinLibraryService._();

  static final _log = LoggerService.instance;

  static const String bookmarkKey = 'fin-games';
  static const String _prefsKey = 'fin_library_cache_v1';
  static const String _syncCompletedKey = 'fin_library_sync_completed_v1';
  static const String _virtualScheme = 'fin';
  static const String _gameCubeScreenScraperSystemId = '13';
  static const String _wiiScreenScraperSystemId = '16';

  static const Set<String> _supportedExtensions = <String>{
    '.iso',
    '.wia',
    '.rvz',
    '.nkit',
    '.m3u',
    '.dol',
    '.elf',
    '.gcm',
    '.tgc',
    '.gcz',
    '.ciso',
    '.wbfs',
    '.wad',
  };

  static const Set<String> _gameCubeExtensions = <String>{
    '.gcm',
    '.tgc',
    '.gcz',
  };

  static const Set<String> _wiiExtensions = <String>{'.ciso', '.wbfs', '.wad'};

  static String? _linkedGamesPath;
  static List<FinLibraryGame>? _cache;
  static bool _syncCompleted = false;
  static int _lastSkippedGames = 0;
  static int _lastNativeCandidates = 0;
  static int _lastNativeUnreadablePrefixes = 0;

  static String? get linkedGamesPath {
    final value = _linkedGamesPath;
    if (value == null || value.isEmpty) return null;
    if (Platform.isIOS) return value;
    return Directory(value).existsSync() ? value : null;
  }

  static bool get isLinked => linkedGamesPath != null;
  static bool get hasSyncedLibrary => _syncCompleted;
  static int get syncedGameCount => _cache?.length ?? 0;
  static int get gameCubeCount =>
      _cache?.where((game) => game.systemFolder == 'gc').length ?? 0;
  static int get wiiCount =>
      _cache?.where((game) => game.systemFolder == 'wii').length ?? 0;
  static int get skippedGameCount => _lastSkippedGames;

  static String? get firstLaunchableGameId {
    for (final game in _cache ?? const <FinLibraryGame>[]) {
      final value = game.gameId?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static bool isVirtualLibraryPath(String romPath) {
    final uri = Uri.tryParse(romPath);
    return uri != null &&
        uri.scheme.toLowerCase() == _virtualScheme &&
        uri.host.toLowerCase() == 'launch';
  }

  /// Restores the bookmark and cached library before the provider graph exists.
  static Future<void> initialize() async {
    await loadCachedLibrary();
    if (!Platform.isIOS) return;

    try {
      final selected = await ExternalFolderAccess.resolveBookmarkedFolder(
        key: bookmarkKey,
      );
      if (selected != null) {
        _linkedGamesPath = await _normalizeGamesRoot(selected);
      }
    } catch (error) {
      _log.w(
        'FinLibraryService: could not restore linked Games folder: $error',
      );
    }
  }

  /// Restores Fin rows after SQLite providers are ready. A readable live folder
  /// is authoritative; otherwise the last cache keeps the two console cards
  /// populated until the bookmark can be linked again.
  static Future<void> restoreAfterDatabaseReady({
    required SqliteConfigProvider configProvider,
    required SqliteDatabaseProvider databaseProvider,
  }) async {
    await loadCachedLibrary();
    if (!Platform.isIOS) return;

    final root = await _resolveLinkedGamesRoot();
    if (root != null) {
      try {
        final discovery = await _discoverLibraryNatively(
          root,
          allowTitleLookup: false,
        );
        if (discovery != null) {
          await _importIntoNeoStation(discovery.games);
          await _replaceCache(discovery.games, skipped: discovery.skipped);
          await configProvider.refreshDetectedSystems();
          await databaseProvider.loadDatabase();
          _log.i(
            'FinLibraryService: reconciled ${discovery.games.length} live game(s) '
            'after database initialization.',
          );
          return;
        }
      } catch (error) {
        _log.w('FinLibraryService: live startup reconcile failed: $error');
      }
    }

    final cache = _cache;
    if (!_syncCompleted || cache == null || cache.isEmpty) return;
    try {
      await _importIntoNeoStation(cache);
      await configProvider.refreshDetectedSystems();
      await databaseProvider.loadDatabase();
      _log.i('FinLibraryService: restored ${cache.length} cached game(s).');
    } catch (error) {
      _log.e('FinLibraryService: cache restore failed: $error');
    }
  }

  /// Lets the user select either Fin itself or its Games folder and immediately
  /// performs a library sync. Returns null when the picker is cancelled.
  static Future<FinSyncResult?> linkAndSync() async {
    if (!Platform.isIOS) return null;

    final selected = await ExternalFolderAccess.pickAndBookmarkFolder(
      key: bookmarkKey,
    );
    if (selected == null) return null;

    // The picker callback stores a bookmark. Resolve it once before scanning so
    // the security-scoped grant is active while Dart enumerates Fin/Games.
    final resolved = await ExternalFolderAccess.resolveBookmarkedFolder(
      key: bookmarkKey,
    );
    final normalized = await _normalizeGamesRoot(resolved ?? selected);
    if (normalized == null) {
      await _writeDebugFile(
        'STATE: INVALID_SELECTION\nSelected: $selected\nResolved: $resolved',
      );
      throw const FormatException(
        'Select Fin/Games (or the Fin folder that contains Games).',
      );
    }

    _linkedGamesPath = normalized;
    return syncLinkedLibrary();
  }

  static Future<FinSyncResult> syncLinkedLibrary() async {
    final root = await _resolveLinkedGamesRoot();
    if (root == null) {
      await _writeDebugFile('STATE: NO_LINKED_FOLDER');
      throw StateError('Fin Games folder is not linked.');
    }

    await _writeDebugFile('STATE: SCANNING\nGames root: $root');
    final discovery = Platform.isIOS
        ? await _discoverLibraryNatively(root, allowTitleLookup: true)
        : await discoverLibrary(root, allowTitleLookup: true);
    if (discovery == null) {
      await _writeDebugFile(
        'STATE: NATIVE_SCAN_UNAVAILABLE\nGames root: $root',
      );
      throw StateError('Fin native iOS scan is unavailable for the linked folder.');
    }
    final discoveryMode = Platform.isIOS ? 'native-ios' : 'dart';
    final importResult = await _importIntoNeoStation(discovery.games);
    await _replaceCache(discovery.games, skipped: discovery.skipped);
    await _refreshNeoStationUi();

    final gameCubeGames = discovery.games
        .where((game) => game.systemFolder == 'gc')
        .length;
    final wiiGames = discovery.games
        .where((game) => game.systemFolder == 'wii')
        .length;

    _log.i(
      'FinLibraryService: ${discovery.games.length} games '
      '($gameCubeGames GameCube, $wiiGames Wii), '
      '${discovery.skipped} unclassified, '
      '${importResult.virtualRows} virtual rows, '
      '${importResult.physicalRows} physical rows, '
      '${importResult.removedRows} stale rows removed.',
    );
    await _writeDebugFile(
      'STATE: IMPORTED\nGames root: $root\n'
      'Discovery mode: $discoveryMode\n'
      'Native candidates: $_lastNativeCandidates\n'
      'Unreadable prefixes: $_lastNativeUnreadablePrefixes\n'
      'Detected: ${discovery.games.length}\n'
      'GameCube: $gameCubeGames\nWii: $wiiGames\n'
      'Unclassified: ${discovery.skipped}\n'
      'Virtual rows: ${importResult.virtualRows}\n'
      'Physical rows: ${importResult.physicalRows}\n'
      'Removed rows: ${importResult.removedRows}\n\n'
      '${discovery.games.map((game) => '${game.systemFolder} | ${game.gameId ?? '-'} | ${game.relativePath}').join('\n')}',
    );

    return FinSyncResult(
      discoveredGames: discovery.games.length,
      gameCubeGames: gameCubeGames,
      wiiGames: wiiGames,
      skippedGames: discovery.skipped,
      virtualRows: importResult.virtualRows,
      physicalRows: importResult.physicalRows,
      removedRows: importResult.removedRows,
    );
  }

  /// iOS-native discovery path. The security-scoped bookmark stays owned
  /// by the Swift URL while it enumerates the Files-visible Fin directory and
  /// reads only the first 256 bytes of each candidate image. This avoids the
  /// provider-backed folder traversal failure that can occur after returning a
  /// path string to Dart.
  static Future<({List<FinLibraryGame> games, int skipped})?>
  _discoverLibraryNatively(
    String gamesRoot, {
    required bool allowTitleLookup,
  }) async {
    if (!Platform.isIOS) return null;

    final bookmarkedRoot = await ExternalFolderAccess.resolveBookmarkedFolder(
      key: bookmarkKey,
    );
    if (bookmarkedRoot == null || bookmarkedRoot.trim().isEmpty) return null;

    final bookmarkPath = path.normalize(bookmarkedRoot);
    final normalizedGamesRoot = path.normalize(gamesRoot);
    String? subdirectory;
    if (bookmarkPath != normalizedGamesRoot) {
      final relative = path
          .relative(normalizedGamesRoot, from: bookmarkPath)
          .replaceAll('\\', '/');
      if (relative != '.' &&
          relative.isNotEmpty &&
          relative != '..' &&
          !relative.startsWith('../')) {
        subdirectory = relative;
      }
    }

    final entries = await ExternalFolderAccess.listBookmarkedFiles(
      key: bookmarkKey,
      subdirectory: subdirectory,
      extensions: _supportedExtensions
          .map((extension) => extension.replaceFirst('.', ''))
          .toList(growable: false),
      recursive: true,
      prefixBytes: 0x100,
    );
    if (entries == null) {
      throw StateError('Fin bookmark resolved but native enumeration returned no result.');
    }

    _lastNativeCandidates = entries.length;
    _lastNativeUnreadablePrefixes = 0;
    final games = <FinLibraryGame>[];
    var skipped = 0;
    for (final entry in entries) {
      final relative =
          entry['relativePath']?.toString().replaceAll('\\', '/') ?? '';
      final fileName = entry['fileName']?.toString() ?? path.basename(relative);
      if (relative.isEmpty || fileName.isEmpty) continue;

      final extension = path.extension(fileName).toLowerCase();
      if (!_supportedExtensions.contains(extension)) continue;

      if (entry['prefixRead'] == false) {
        _lastNativeUnreadablePrefixes++;
      }
      final rawPrefix = entry['prefix'];
      final Uint8List prefix;
      if (rawPrefix is Uint8List) {
        prefix = rawPrefix;
      } else if (rawPrefix is List) {
        prefix = Uint8List.fromList(
          rawPrefix.whereType<num>().map((value) => value.toInt()).toList(),
        );
      } else {
        prefix = Uint8List(0);
      }

      var title = path.basenameWithoutExtension(fileName);
      if (title.toLowerCase().endsWith('.nkit')) {
        title = title.substring(0, title.length - 5);
      }

      var info = detectDiscInfoFromPrefix(
        prefix,
        extension: extension,
        pathHint: relative,
      );
      if (info == null && allowTitleLookup) {
        info = await _classifyByTitle(title, fileName: fileName);
      }
      if (info == null) {
        skipped++;
        continue;
      }

      games.add(
        FinLibraryGame(
          fileName: fileName,
          relativePath: relative,
          systemFolder: info.systemFolder,
          title: title,
          gameId: info.gameId,
        ),
      );
    }

    games.sort((a, b) {
      final systemCompare = a.systemFolder.compareTo(b.systemFolder);
      if (systemCompare != 0) return systemCompare;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return (games: List<FinLibraryGame>.unmodifiable(games), skipped: skipped);
  }

  /// Scans the linked Fin folder and classifies formats without relying on
  /// filenames. RVZ/WIA carries an explicit Dolphin disc_type in header 2;
  /// ordinary disc images use the standard Wii/GameCube magic words.
  @visibleForTesting
  static Future<({List<FinLibraryGame> games, int skipped})> discoverLibrary(
    String gamesRoot, {
    bool allowTitleLookup = false,
  }) async {
    final root = Directory(path.normalize(gamesRoot));
    if (!await root.exists()) {
      return (games: const <FinLibraryGame>[], skipped: 0);
    }

    final games = <FinLibraryGame>[];
    var skipped = 0;
    final visitedPlaylists = <String>{};

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final extension = path.extension(entity.path).toLowerCase();
      if (!_supportedExtensions.contains(extension)) continue;

      var relative = path.relative(entity.path, from: root.path);
      relative = relative.replaceAll('\\', '/');
      final fileName = path.basename(entity.path);
      var title = path.basenameWithoutExtension(fileName);
      if (title.toLowerCase().endsWith('.nkit')) {
        title = title.substring(0, title.length - 5);
      }

      var info = await detectDiscInfo(
        entity,
        visitedPlaylists: visitedPlaylists,
      );
      if (info == null && allowTitleLookup) {
        info = await _classifyByTitle(title, fileName: fileName);
      }
      if (info == null) {
        skipped++;
        continue;
      }

      games.add(
        FinLibraryGame(
          fileName: fileName,
          relativePath: relative,
          systemFolder: info.systemFolder,
          title: title,
          gameId: info.gameId,
        ),
      );
    }

    games.sort((a, b) {
      final systemCompare = a.systemFolder.compareTo(b.systemFolder);
      if (systemCompare != 0) return systemCompare;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return (games: List<FinLibraryGame>.unmodifiable(games), skipped: skipped);
  }

  /// Classifies a game from the small prefix read by the native iOS
  /// bookmark scanner. RVZ/WIA stores disc_type and the raw optical-disc header
  /// in this prefix, so the full multi-gigabyte image never needs to be copied.
  @visibleForTesting
  static ({String systemFolder, String? gameId})? detectDiscInfoFromPrefix(
    Uint8List bytes, {
    required String extension,
    String pathHint = '',
  }) {
    final normalizedExtension = extension.toLowerCase();
    if (_gameCubeExtensions.contains(normalizedExtension)) {
      return (systemFolder: 'gc', gameId: null);
    }
    if (_wiiExtensions.contains(normalizedExtension)) {
      return (systemFolder: 'wii', gameId: null);
    }

    if (bytes.length >= 0x5e &&
        (_startsWith(bytes, const <int>[0x52, 0x56, 0x5a, 0x01]) ||
            _startsWith(bytes, const <int>[0x57, 0x49, 0x41, 0x01]))) {
      final data = ByteData.sublistView(bytes);
      final discType = data.getUint32(0x48, Endian.big);
      final gameId = _readGameId(bytes, 0x58);
      if (discType == 1) return (systemFolder: 'gc', gameId: gameId);
      if (discType == 2) return (systemFolder: 'wii', gameId: gameId);
      final idHint = _systemFromNintendoGameId(gameId);
      if (idHint != null) return (systemFolder: idHint, gameId: gameId);
    }

    if (bytes.length >= 0x20) {
      final data = ByteData.sublistView(bytes);
      final wiiMagic = data.getUint32(0x18, Endian.big);
      final gameCubeMagic = data.getUint32(0x1c, Endian.big);
      final gameId = _readGameId(bytes, 0);
      if (wiiMagic == 0x5d1c9ea3) {
        return (systemFolder: 'wii', gameId: gameId);
      }
      if (gameCubeMagic == 0xc2339f3d) {
        return (systemFolder: 'gc', gameId: gameId);
      }
    }

    return pathHint.isEmpty ? null : _pathHint(pathHint);
  }

  /// Public only for deterministic unit tests and diagnostics.
  @visibleForTesting
  static Future<({String systemFolder, String? gameId})?> detectDiscInfo(
    File file, {
    Set<String>? visitedPlaylists,
  }) async {
    final extension = path.extension(file.path).toLowerCase();
    if (!_supportedExtensions.contains(extension)) return null;

    if (_gameCubeExtensions.contains(extension)) {
      return (systemFolder: 'gc', gameId: null);
    }
    if (_wiiExtensions.contains(extension)) {
      return (systemFolder: 'wii', gameId: null);
    }

    if (extension == '.m3u') {
      final visited = visitedPlaylists ?? <String>{};
      final normalized = path.normalize(file.path).toLowerCase();
      if (!visited.add(normalized)) return null;
      try {
        final lines = await file.readAsLines();
        for (var raw in lines) {
          raw = raw.trim();
          if (raw.isEmpty || raw.startsWith('#')) continue;
          if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
            raw = raw.substring(1, raw.length - 1);
          }
          final candidate = File(
            path.isAbsolute(raw) ? raw : path.join(file.parent.path, raw),
          );
          if (!await candidate.exists()) continue;
          final nested = await detectDiscInfo(
            candidate,
            visitedPlaylists: visited,
          );
          if (nested != null) return nested;
        }
      } catch (_) {}
      return _pathHint(file.path);
    }

    Uint8List bytes;
    try {
      final handle = await file.open();
      try {
        bytes = Uint8List.fromList(await handle.read(0x100));
      } finally {
        await handle.close();
      }
    } catch (_) {
      return _pathHint(file.path);
    }

    return detectDiscInfoFromPrefix(
      bytes,
      extension: extension,
      pathHint: file.path,
    );
  }

  static String? _systemFromNintendoGameId(String? gameId) {
    final value = gameId?.trim().toUpperCase() ?? '';
    if (value.length != 6) return null;
    // Fallback only. Primary classification remains the RVZ/WIA disc_type or
    // the optical-disc magic. Retail GameCube IDs overwhelmingly begin with G,
    // while Wii retail IDs commonly begin with R or S.
    if (value.startsWith('G')) return 'gc';
    if (value.startsWith('R') || value.startsWith('S')) return 'wii';
    return null;
  }

  static Future<({String systemFolder, String? gameId})?> _classifyByTitle(
    String title, {
    required String fileName,
  }) async {
    final pathHint = _pathHint('$title $fileName');
    if (pathHint != null) return pathHint;

    // Mixed Fin/Games folders are normal. Only use the title database as a
    // last resort when the disc itself could not be classified. If a title
    // exists on exactly one of GameCube/Wii, the platform is unambiguous. A
    // port that exists on both stays unclassified rather than being guessed.
    try {
      final gc = await ScreenScraperService.fetchGameInfo(
        _gameCubeScreenScraperSystemId,
        fileName,
        gameName: title,
      );
      final wii = await ScreenScraperService.fetchGameInfo(
        _wiiScreenScraperSystemId,
        fileName,
        gameName: title,
      );
      final hasGc = gc?['gameInfo'] is Map;
      final hasWii = wii?['gameInfo'] is Map;
      if (hasGc && !hasWii) return (systemFolder: 'gc', gameId: null);
      if (hasWii && !hasGc) return (systemFolder: 'wii', gameId: null);
    } catch (error) {
      _log.w(
        'FinLibraryService: title platform lookup failed for $title: $error',
      );
    }
    return null;
  }

  static ({String systemFolder, String? gameId})? _pathHint(String value) {
    final normalized = value
        .replaceAll('\\', '/')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    if (RegExp(r'(^| )game ?cube( |$)|(^| )gc( |$)').hasMatch(normalized)) {
      return (systemFolder: 'gc', gameId: null);
    }
    if (RegExp(r'(^| )wii( |$)').hasMatch(normalized)) {
      return (systemFolder: 'wii', gameId: null);
    }
    return null;
  }

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static String? _readGameId(Uint8List bytes, int offset) {
    if (bytes.length < offset + 6) return null;
    final values = bytes.sublist(offset, offset + 6);
    if (values.any((value) => value < 0x21 || value > 0x7e)) return null;
    return String.fromCharCodes(values);
  }

  static Future<({int virtualRows, int physicalRows, int removedRows})>
  _importIntoNeoStation(List<FinLibraryGame> games) async {
    var gameCube = await SystemRepository.getSystemByFolderName('gc');
    var wii = await SystemRepository.getSystemByFolderName('wii');
    if (gameCube?.id == null || wii?.id == null) {
      await SystemRepository.getAllSystems();
      gameCube = await SystemRepository.getSystemByFolderName('gc');
      wii = await SystemRepository.getSystemByFolderName('wii');
    }
    if (gameCube?.id == null || wii?.id == null) {
      throw StateError(
        'NeoStation GameCube/Wii system definitions were not found.',
      );
    }

    final systems = <String, String>{'gc': gameCube!.id!, 'wii': wii!.id!};
    final db = await SqliteService.getDatabase();
    final physicalBySystem = <String, Set<String>>{
      'gc': <String>{},
      'wii': <String>{},
    };

    for (final entry in systems.entries) {
      final rows = await db.rawQuery(
        'SELECT filename, rom_path FROM user_roms WHERE app_system_id = ?',
        [entry.value],
      );
      for (final row in rows) {
        final fileName = row['filename']?.toString().trim();
        final romPath = row['rom_path']?.toString() ?? '';
        if (fileName == null ||
            fileName.isEmpty ||
            isVirtualLibraryPath(romPath)) {
          continue;
        }
        physicalBySystem[entry.key]!.add(fileName.toLowerCase());
      }
    }

    final desiredBySystem = <String, Set<String>>{
      'gc': <String>{},
      'wii': <String>{},
    };
    var virtualRows = 0;
    var physicalRows = 0;

    await db.transaction((txn) async {
      for (final game in games) {
        final systemId = systems[game.systemFolder];
        if (systemId == null) continue;

        if (physicalBySystem[game.systemFolder]!.contains(
          game.fileName.toLowerCase(),
        )) {
          physicalRows++;
          continue;
        }

        final launchParameters = <String, String>{
          'system': game.systemFolder,
          'path': game.relativePath,
          'game': game.fileName,
        };
        final gameId = game.gameId?.trim();
        if (gameId != null && gameId.isNotEmpty) {
          launchParameters['id'] = gameId;
        }
        final virtualPath = Uri(
          scheme: _virtualScheme,
          host: 'launch',
          queryParameters: launchParameters,
        ).toString();
        desiredBySystem[game.systemFolder]!.add(virtualPath);

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
              WHEN excluded.title_id IS NOT NULL AND excluded.title_id != ''
              THEN excluded.title_id ELSE user_roms.title_id END,
            title_name = CASE
              WHEN user_roms.title_name IS NULL OR user_roms.title_name = ''
              THEN excluded.title_name ELSE user_roms.title_name END,
            updated_at = datetime('now')
          ''',
          [systemId, game.fileName, virtualPath, game.gameId, game.title],
        );
        virtualRows++;
      }
    });

    var removedRows = 0;
    for (final entry in systems.entries) {
      final virtualRowsInDb = await db.rawQuery(
        "SELECT rom_path FROM user_roms WHERE app_system_id = ? AND rom_path LIKE 'fin://%'",
        [entry.value],
      );
      final desired = desiredBySystem[entry.key]!;
      final stale = virtualRowsInDb
          .map((row) => row['rom_path']?.toString() ?? '')
          .where((romPath) => romPath.isNotEmpty && !desired.contains(romPath))
          .toList();
      if (stale.isEmpty) continue;

      await db.transaction((txn) async {
        const batchSize = 100;
        for (var i = 0; i < stale.length; i += batchSize) {
          final end = (i + batchSize < stale.length)
              ? i + batchSize
              : stale.length;
          final batch = stale.sublist(i, end);
          final placeholders = List.filled(batch.length, '?').join(',');
          removedRows += await txn.rawDelete(
            'DELETE FROM user_roms WHERE app_system_id = ? '
            'AND rom_path IN ($placeholders)',
            [entry.value, ...batch],
          );
        }
      });
    }

    for (final entry in systems.entries) {
      final countRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM user_roms WHERE app_system_id = ?',
        [entry.value],
      );
      final count = int.tryParse('${countRows.first['count'] ?? 0}') ?? 0;
      if (count > 0) {
        await SystemRepository.addDetectedSystem(entry.value, entry.key);
      } else {
        await SystemRepository.removeDetectedSystem(entry.value);
      }
    }

    return (
      virtualRows: virtualRows,
      physicalRows: physicalRows,
      removedRows: removedRows,
    );
  }

  static Future<void> _refreshNeoStationUi() async {
    try {
      final context = rootNavigatorKey.currentContext;
      if (context == null) return;
      final databaseProvider = Provider.of<SqliteDatabaseProvider>(
        context,
        listen: false,
      );
      await Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      ).refreshDetectedSystems();
      await databaseProvider.loadDatabase();
    } catch (error) {
      _log.e('FinLibraryService: UI refresh failed: $error');
    }
  }

  /// Launches a Fin-backed row through the user-created Apple Shortcut.
  /// NeoStation passes Fin's Nintendo Game ID (for example RMCP01), because
  /// the Shortcut searches Fin's Game entity by its `ID du jeu` field. Older
  /// Fin rows are upgraded lazily from SQLite/cache so users do not need to
  /// rescan the library just to use the new Shortcut contract.
  static Future<bool> launchGameByRomPath(String romPath) async {
    String? gameId;
    String? relativePath;

    if (isVirtualLibraryPath(romPath)) {
      final uri = Uri.tryParse(romPath);
      gameId = uri?.queryParameters['id']?.trim();
      relativePath =
          uri?.queryParameters['path'] ?? uri?.queryParameters['game'];
    }

    // Rows created before the Game-ID Shortcut contract already store the
    // detected Nintendo ID in user_roms.title_id. Reuse it without requiring
    // the user to relink or resync Fin/Games.
    if (gameId == null || gameId.isEmpty) {
      try {
        final db = await SqliteService.getDatabase();
        final rows = await db.rawQuery(
          'SELECT title_id FROM user_roms WHERE rom_path = ? LIMIT 1',
          [romPath],
        );
        if (rows.isNotEmpty) {
          gameId = rows.first['title_id']?.toString().trim();
        }
      } catch (error) {
        _log.w('FinLibraryService: could not read Game ID from SQLite: $error');
      }
    }

    // Final compatibility fallback: resolve the game from the cached Fin scan
    // by relative path or filename and use the Game ID captured from RVZ/WIA.
    if (gameId == null || gameId.isEmpty) {
      await loadCachedLibrary();
      final normalizedPath = (relativePath ?? romPath)
          .replaceAll('\\', '/')
          .toLowerCase();
      final normalizedName = path.basename(romPath).toLowerCase();
      for (final game in _cache ?? const <FinLibraryGame>[]) {
        final cachedRelative = game.relativePath
            .replaceAll('\\', '/')
            .toLowerCase();
        if (cachedRelative == normalizedPath ||
            game.fileName.toLowerCase() == normalizedName) {
          gameId = game.gameId?.trim();
          if (gameId != null && gameId.isNotEmpty) break;
        }
      }
    }

    final input = gameId?.trim();
    if (input == null || input.isEmpty) {
      _log.e(
        'FinLibraryService: no Nintendo Game ID available for Shortcut launch: $romPath',
      );
      return false;
    }

    await _writeLaunchDebugFile(
      'ROM path: $romPath\n'
      'Relative path: ${relativePath ?? '-'}\n'
      'Shortcut input (Nintendo Game ID): $input',
    );

    try {
      final launched = await IosShortcutJitLaunchService.run(
        shortcutName: IosShortcutJitLaunchService.finShortcutName,
        input: input,
      );
      await _writeLaunchDebugFile(
        'ROM path: $romPath\n'
        'Relative path: ${relativePath ?? '-'}\n'
        'Shortcut input (Nintendo Game ID): $input\n'
        'Shortcuts handoff opened: $launched',
      );
      return launched;
    } catch (error) {
      await _writeLaunchDebugFile(
        'ROM path: $romPath\n'
        'Relative path: ${relativePath ?? '-'}\n'
        'Shortcut input (Nintendo Game ID): $input\n'
        'Shortcut launch error: $error',
      );
      _log.e('FinLibraryService: Shortcut launch failed: $error');
      return false;
    }
  }

  static Future<String?> _resolveLinkedGamesRoot() async {
    if (!Platform.isIOS) return linkedGamesPath;

    try {
      final selected = await ExternalFolderAccess.resolveBookmarkedFolder(
        key: bookmarkKey,
      );
      if (selected != null) {
        final normalized = await _normalizeGamesRoot(selected);
        if (normalized != null) {
          _linkedGamesPath = normalized;
          return normalized;
        }
      }
    } catch (error) {
      _log.w('FinLibraryService: failed resolving bookmark: $error');
    }

    // Keep a best-effort fallback for an already-active path in the same app
    // session, but never prefer it over resolving the bookmark first.
    return linkedGamesPath;
  }

  static Future<String?> _normalizeGamesRoot(String selected) async {
    final normalizedPath = path.normalize(selected);
    final base = path.basename(normalizedPath).toLowerCase();
    if (base == 'games' || base == 'software') return normalizedPath;

    // The native recursive scanner can walk a selected parent Fin folder even
    // when Dart cannot stat/list provider-backed folders returned by Files.
    if (Platform.isIOS) return normalizedPath;

    final root = Directory(normalizedPath);
    if (!await root.exists()) return null;

    for (final name in const <String>[
      'Games',
      'games',
      'Software',
      'software',
    ]) {
      final child = Directory(path.join(root.path, name));
      if (await child.exists()) return child.path;
    }

    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is File &&
            _supportedExtensions.contains(
              path.extension(entity.path).toLowerCase(),
            )) {
          return root.path;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _writeLaunchDebugFile(String content) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File(path.join(docs.path, 'fin_launch_debug.txt'));
      await file.writeAsString(
        '--- ${DateTime.now().toIso8601String()} ---\n$content',
      );
    } catch (error) {
      _log.w('FinLibraryService: could not write launch diagnostics: $error');
    }
  }

  static Future<void> _writeDebugFile(String content) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File(path.join(docs.path, 'fin_sync_debug.txt'));
      await file.writeAsString(
        '--- ${DateTime.now().toIso8601String()} ---\n$content',
      );
    } catch (error) {
      _log.w('FinLibraryService: could not write sync diagnostics: $error');
    }
  }

  static Future<void> loadCachedLibrary() async {
    if (_cache != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _syncCompleted = prefs.getBool(_syncCompletedKey) ?? false;
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) {
        _cache = <FinLibraryGame>[];
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _cache = <FinLibraryGame>[];
        return;
      }
      _lastSkippedGames = int.tryParse('${decoded['skipped'] ?? 0}') ?? 0;
      final rawGames = decoded['games'];
      if (rawGames is! List) {
        _cache = <FinLibraryGame>[];
        return;
      }
      _cache = rawGames
          .whereType<Map>()
          .map(
            (value) =>
                FinLibraryGame.fromJson(Map<String, dynamic>.from(value)),
          )
          .where(
            (game) =>
                game.fileName.isNotEmpty &&
                game.relativePath.isNotEmpty &&
                (game.systemFolder == 'gc' || game.systemFolder == 'wii'),
          )
          .toList(growable: false);
    } catch (error) {
      _log.e('FinLibraryService: failed loading cache: $error');
      _cache = <FinLibraryGame>[];
    }
  }

  static Future<void> _replaceCache(
    List<FinLibraryGame> games, {
    required int skipped,
  }) async {
    _cache = List<FinLibraryGame>.unmodifiable(games);
    _lastSkippedGames = skipped;
    _syncCompleted = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(<String, dynamic>{
          'schema': 1,
          'skipped': skipped,
          'games': games.map((game) => game.toJson()).toList(),
        }),
      );
      await prefs.setBool(_syncCompletedKey, true);
    } catch (error) {
      _log.e('FinLibraryService: failed persisting cache: $error');
    }
  }
}
