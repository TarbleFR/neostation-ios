import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:external_folder_access/external_folder_access.dart';
import 'package:flutter/foundation.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/sqlite_database_provider.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/rpcs3_title_catalog_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One PS3 title discovered inside RPCS3's Files-visible `Data` directory.
class Rpcs3LibraryGame {
  const Rpcs3LibraryGame({
    required this.titleId,
    required this.title,
    required this.version,
    required this.category,
    required this.sourcePath,
    required this.sourceKind,
    this.iconPath,
  });

  final String titleId;
  final String title;
  final String version;
  final String category;
  final String sourcePath;
  final String sourceKind;
  final String? iconPath;

  Rpcs3LibraryGame copyWith({
    String? titleId,
    String? title,
    String? version,
    String? category,
    String? sourcePath,
    String? sourceKind,
    String? iconPath,
  }) {
    return Rpcs3LibraryGame(
      titleId: titleId ?? this.titleId,
      title: title ?? this.title,
      version: version ?? this.version,
      category: category ?? this.category,
      sourcePath: sourcePath ?? this.sourcePath,
      sourceKind: sourceKind ?? this.sourceKind,
      iconPath: iconPath ?? this.iconPath,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'titleId': titleId,
    'title': title,
    'version': version,
    'category': category,
    'sourcePath': sourcePath,
    'sourceKind': sourceKind,
    'iconPath': iconPath,
  };

  factory Rpcs3LibraryGame.fromJson(Map<String, dynamic> json) {
    return Rpcs3LibraryGame(
      titleId: json['titleId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      category: json['category']?.toString() ?? '',
      sourcePath: json['sourcePath']?.toString() ?? '',
      sourceKind: json['sourceKind']?.toString() ?? '',
      iconPath: json['iconPath']?.toString(),
    );
  }
}

class Rpcs3SyncResult {
  const Rpcs3SyncResult({
    required this.discoveredGames,
    required this.virtualRows,
    required this.physicalRows,
    required this.artworkFiles,
    required this.removedRows,
    required this.totalPs3Rows,
  });

  final int discoveredGames;
  final int virtualRows;
  final int physicalRows;
  final int artworkFiles;
  final int removedRows;
  final int totalPs3Rows;
}

/// Imports the game list exposed by the unofficial RPCS3 iOS port.
///
/// RPCS3 exposes its persistent directory through Files at:
/// `On My iPhone/iPad > RPCS3 > Data`.
///
/// The iOS build does not currently expose a library-export URL scheme, so
/// NeoStation bookmarks that Data directory and mirrors RPCS3's own discovery
/// rules. Metadata comes from `PARAM.SFO` under:
///
/// - `Data/dev_hdd0/game/`
/// - `Data/games/ExtractedGames/`
/// - `Data/games/DiscImages/`
///
/// `Data/games/DiscImages`, `Data/games/DiscImgs` (legacy alias),
/// `Data/games/ExtractedGames` and `Data/dev_hdd0/game` are authoritative.
/// RPCS3's `games.yml` is deliberately not used to create rows because it
/// can retain stale or cross-linked registrations after a game is removed.
///
/// Imported rows intentionally use an internal `rpcs3-library://` URI. They are
/// display-only until RPCS3 publishes a supported direct-game deeplink.
class Rpcs3LibraryService {
  Rpcs3LibraryService._();

  static final _log = LoggerService.instance;

  static const String bookmarkKey = 'rpcs3';
  static const String _prefsKey = 'rpcs3_library_cache_v1';
  static const String _syncCompletedKey = 'rpcs3_library_sync_completed_v1';
  static const String _virtualScheme = 'rpcs3-library';

  static String? _linkedDataPath;
  static Map<String, Rpcs3LibraryGame>? _cache;
  static bool _syncCompleted = false;

  static String? get linkedDataPath {
    final value = _linkedDataPath;
    if (value == null || value.isEmpty) return null;
    return Directory(value).existsSync() ? value : null;
  }

  static bool get isLinked => linkedDataPath != null;
  static bool get hasSyncedLibrary => _syncCompleted;
  static int get syncedGameCount => _cache?.length ?? 0;

  static Rpcs3LibraryGame? cachedGameForTitleId(String? titleId) {
    final normalized = titleId?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty) return null;
    return _cache?[normalized];
  }

  static bool isVirtualLibraryPath(String romPath) {
    final uri = Uri.tryParse(romPath);
    return uri != null &&
        uri.scheme.toLowerCase() == _virtualScheme &&
        uri.host.toLowerCase() == 'game';
  }

  /// Restores the security-scoped bookmark and the last lightweight cache.
  static Future<void> initialize() async {
    await loadCachedLibrary();
    if (!Platform.isIOS) return;

    try {
      final selected = await ExternalFolderAccess.resolveBookmarkedFolder(
        key: bookmarkKey,
      );
      if (selected != null) {
        _linkedDataPath = await _normalizeDataRoot(selected);
      }
    } catch (e) {
      _log.w('Rpcs3LibraryService: could not restore linked Data folder: $e');
    }
  }

  /// Restores cached virtual PS3 rows after SQLite providers are ready.
  ///
  /// The bookmark/cache is loaded before the provider graph during startup, but
  /// UI providers cannot be refreshed at that point. Re-importing the tiny
  /// cached metadata set here keeps the PS3 system and games visible on every
  /// cold launch without requiring a manual RPCS3 resync.
  static Future<void> restoreAfterDatabaseReady({
    required SqliteConfigProvider configProvider,
    required SqliteDatabaseProvider databaseProvider,
  }) async {
    await loadCachedLibrary();
    if (!Platform.isIOS) return;

    final dataRoot = await _resolveLinkedDataRoot();
    final dataRootReadable =
        dataRoot != null && await _canReadDataRoot(dataRoot);

    if (dataRootReadable) {
      try {
        final discovered = await discoverLibrary(dataRoot);
        final games = await _applyTitleFallbacks(
          discovered,
          allowNetwork: false,
        );
        final result = await _importIntoNeoStation(games);
        await _replaceCache(games);
        await _writeDebugFile(dataRoot: dataRoot, games: games, result: result);
        await _writeStartupDebugFile(
          mode: 'LIVE_RECONCILE',
          dataRoot: dataRoot,
          readable: true,
          gameCount: games.length,
          removedRows: result.removedRows,
        );
        await databaseProvider.loadGamesForSystem('ps3');
        await configProvider.refreshDetectedSystems();
        _log.i(
          'Rpcs3LibraryService: reconciled ${games.length} live PS3 game(s) '
          'after database initialization; removed ${result.removedRows} stale '
          'row(s).',
        );

        unawaited(
          _refreshCatalogAfterStartup(
            dataRoot: dataRoot,
            games: games,
            configProvider: configProvider,
            databaseProvider: databaseProvider,
          ),
        );
        return;
      } catch (error) {
        _log.w(
          'Rpcs3LibraryService: live startup reconciliation failed; '
          'falling back to cache: $error',
        );
        await _writeStartupDebugFile(
          mode: 'LIVE_RECONCILE_FAILED',
          dataRoot: dataRoot,
          readable: true,
          error: error.toString(),
        );
      }
    } else {
      await _writeStartupDebugFile(
        mode: 'BOOKMARK_UNAVAILABLE',
        dataRoot: dataRoot,
        readable: false,
      );
    }

    final cache = _cache;
    if (!_syncCompleted || cache == null || cache.isEmpty) return;
    try {
      // Build 133 only enriched names on the live-folder path. When an IPA
      // update invalidated the folder bookmark, the old cache therefore kept
      // raw serials such as BLES00412 forever. Apply the disk/seed catalog to
      // cached rows as well, independently of folder access.
      final cachedGames = await _applyTitleFallbacks(
        cache.values.toList(),
        allowNetwork: false,
      );
      await _importIntoNeoStation(cachedGames);
      await _replaceCache(cachedGames);
      await _writeStartupDebugFile(
        mode: 'CACHE_FALLBACK',
        dataRoot: dataRoot,
        readable: false,
        gameCount: cachedGames.length,
      );
      await databaseProvider.loadGamesForSystem('ps3');
      await configProvider.refreshDetectedSystems();
      _log.i(
        'Rpcs3LibraryService: restored ${cachedGames.length} cached PS3 game(s) '
        'because the linked Data folder was unavailable.',
      );

      // Retry live access after the rest of the app has reached a stable
      // foreground state. This catches security-scope timing issues without
      // blocking startup and, when successful, removes stale rows immediately.
      unawaited(
        _retryLiveReconcileAfterStartup(
          configProvider: configProvider,
          databaseProvider: databaseProvider,
        ),
      );
      unawaited(
        _refreshCachedCatalogAfterStartup(
          games: cachedGames,
          configProvider: configProvider,
          databaseProvider: databaseProvider,
        ),
      );
    } catch (error) {
      _log.e('Rpcs3LibraryService: startup cache restore failed: $error');
    }
  }

  /// Lets the user select RPCS3's folder, bookmarks it, then performs a sync.
  /// Returns null when the picker is cancelled.
  static Future<Rpcs3SyncResult?> linkAndSync() async {
    if (!Platform.isIOS) return null;

    final picked = await ExternalFolderAccess.pickAndBookmarkFolder(
      key: bookmarkKey,
    );
    if (picked == null) return null;

    // The document picker grant is temporary. Re-resolve the freshly stored
    // RPCS3 bookmark immediately so this session owns an active
    // security-scoped URL before discovery starts. Without this, iOS can make
    // the first scan look empty until NeoStation is restarted.
    final selected = await ExternalFolderAccess.resolveBookmarkedFolder(
      key: bookmarkKey,
    );
    if (selected == null) {
      throw StateError('RPCS3 Data folder could not be activated.');
    }

    final normalized = await _normalizeDataRoot(selected);
    if (normalized == null) {
      throw const FormatException(
        'Select the RPCS3 Data folder shown in Files under RPCS3 > Data.',
      );
    }

    _linkedDataPath = normalized;
    return syncLinkedLibrary();
  }

  /// Reads the currently linked RPCS3 Data directory and imports its PS3 rows.
  static Future<Rpcs3SyncResult> syncLinkedLibrary() async {
    final dataRoot = await _resolveLinkedDataRoot();
    if (dataRoot == null) {
      throw StateError('RPCS3 Data folder is not linked.');
    }

    final discovered = await discoverLibrary(dataRoot);
    final games = await _applyTitleFallbacks(discovered, allowNetwork: true);
    final importResult = await _importIntoNeoStation(games);
    await _replaceCache(games);

    await _writeDebugFile(
      dataRoot: dataRoot,
      games: games,
      result: importResult,
    );
    await _refreshNeoStationUi();

    _log.i(
      'Rpcs3LibraryService: discovered ${games.length} games; '
      '${importResult.virtualRows} virtual rows, '
      '${importResult.physicalRows} physical rows, '
      '${importResult.artworkFiles} artwork files, '
      '${importResult.removedRows} stale rows removed',
    );

    return importResult;
  }

  /// Pure filesystem discovery entry point, also used by unit tests.
  @visibleForTesting
  static Future<List<Rpcs3LibraryGame>> discoverLibrary(String dataRoot) async {
    final root = Directory(path.normalize(dataRoot));
    if (!await root.exists()) return const <Rpcs3LibraryGame>[];

    final byTitleId = <String, Rpcs3LibraryGame>{};

    Future<void> scan(
      String relativePath, {
      required String sourceKind,
      required int maxDepth,
      required bool hddRules,
    }) async {
      final directory = Directory(path.join(root.path, relativePath));
      if (!await directory.exists()) return;

      final sfoFiles = await _findNamedFiles(
        directory,
        targetName: 'param.sfo',
        maxDepth: maxDepth,
      );
      for (final sfo in sfoFiles) {
        final game = await _gameFromSfo(
          sfo,
          dataRoot: root.path,
          sourceKind: sourceKind,
          hddRules: hddRules,
        );
        if (game != null) _putPreferred(byTitleId, game);
      }
    }

    await scan(
      path.join('dev_hdd0', 'game'),
      sourceKind: 'dev_hdd0',
      maxDepth: 3,
      hddRules: true,
    );
    await scan(
      path.join('games', 'ExtractedGames'),
      sourceKind: 'extracted',
      maxDepth: 5,
      hddRules: false,
    );
    final discDirectoryNames = await _discoverDiscImageDirectoryNames(
      root.path,
    );
    for (final discDirectoryName in discDirectoryNames) {
      await scan(
        path.join('games', discDirectoryName),
        sourceKind: 'disc-image',
        maxDepth: 5,
        hddRules: false,
      );
      await _addDiscImageFolderFallbacks(
        dataRoot: root.path,
        directoryName: discDirectoryName,
        target: byTitleId,
      );
    }

    // Do not create entries from games.yml. RPCS3 can leave a historical
    // TITLE_ID mapped to another still-existing disc path, which previously
    // resurrected deleted titles such as BLES01484. Physical folders/files are
    // now the sole source of truth for disc-image presence.

    final games = byTitleId.values.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return games;
  }

  static Future<List<String>> _discoverDiscImageDirectoryNames(
    String dataRoot,
  ) async {
    final gamesRoot = Directory(path.join(dataRoot, 'games'));
    if (!await gamesRoot.exists()) return const <String>[];

    final names = <String>[];
    try {
      await for (final entity in gamesRoot.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final basename = path.basename(entity.path);
        final normalized = basename.toLowerCase();
        if (normalized == 'discimages' || normalized == 'discimgs') {
          names.add(basename);
        }
      }
    } catch (error) {
      _log.w('Rpcs3LibraryService: could not list disc-image roots: $error');
    }
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names.toSet().toList(growable: false);
  }

  static Future<void> _addDiscImageFolderFallbacks({
    required String dataRoot,
    required String directoryName,
    required Map<String, Rpcs3LibraryGame> target,
  }) async {
    final directory = Directory(path.join(dataRoot, 'games', directoryName));
    if (!await directory.exists()) return;

    try {
      await for (final entity in directory.list(followLinks: false)) {
        String titleId = '';
        if (entity is Directory) {
          titleId = _cleanTitleId(path.basename(entity.path));
        } else if (entity is File) {
          titleId = _cleanTitleId(path.basenameWithoutExtension(entity.path));
        }
        if (titleId.isEmpty || target.containsKey(titleId.toLowerCase())) {
          continue;
        }

        final iconPath = entity is Directory
            ? await _findFileCaseInsensitive(entity, 'ICON0.PNG') ??
                  await _findCachedIcon(dataRoot, titleId)
            : await _findCachedIcon(dataRoot, titleId);
        _putPreferred(
          target,
          Rpcs3LibraryGame(
            titleId: titleId,
            title: titleId,
            version: '',
            category: '',
            sourcePath: entity.path,
            sourceKind: 'disc-image-folder',
            iconPath: iconPath,
          ),
        );
      }
    } catch (error) {
      _log.w('Rpcs3LibraryService: could not enumerate $directoryName: $error');
    }
  }

  static Future<String?> _resolveLinkedDataRoot() async {
    final current = linkedDataPath;
    if (current != null) return current;
    if (!Platform.isIOS) return null;

    try {
      final selected = await ExternalFolderAccess.resolveBookmarkedFolder(
        key: bookmarkKey,
      );
      if (selected == null) return null;
      final normalized = await _normalizeDataRoot(selected);
      _linkedDataPath = normalized;
      return normalized;
    } catch (error) {
      _log.w('Rpcs3LibraryService: linked Data folder resolve failed: $error');
      return null;
    }
  }

  static Future<void> _replaceCache(List<Rpcs3LibraryGame> games) async {
    _cache = <String, Rpcs3LibraryGame>{
      for (final game in games) game.titleId.toLowerCase(): game,
    };
    _syncCompleted = true;
    await _persistCache();
  }

  static Future<List<Rpcs3LibraryGame>> _applyTitleFallbacks(
    List<Rpcs3LibraryGame> games, {
    required bool allowNetwork,
  }) async {
    if (!games.any(_needsCatalogTitle)) return games;

    final catalog = await Rpcs3TitleCatalogService.loadTitles(
      allowNetwork: allowNetwork,
    );
    return <Rpcs3LibraryGame>[
      for (final game in games)
        if (_needsCatalogTitle(game))
          game.copyWith(
            title:
                Rpcs3TitleCatalogService.resolveFromCatalogForTesting(
                  game.titleId,
                  catalog,
                ) ??
                game.title,
          )
        else
          game,
    ];
  }

  static bool _needsCatalogTitle(Rpcs3LibraryGame game) {
    final title = game.title.trim();
    if (title.isEmpty) return true;
    return Rpcs3TitleCatalogService.normalizeTitleId(title) ==
        Rpcs3TitleCatalogService.normalizeTitleId(game.titleId);
  }

  @visibleForTesting
  static Future<List<Rpcs3LibraryGame>> applyTitleCatalogForTesting(
    List<Rpcs3LibraryGame> games,
    Map<String, String> catalog,
  ) async {
    return <Rpcs3LibraryGame>[
      for (final game in games)
        if (_needsCatalogTitle(game))
          game.copyWith(
            title:
                Rpcs3TitleCatalogService.resolveFromCatalogForTesting(
                  game.titleId,
                  catalog,
                ) ??
                game.title,
          )
        else
          game,
    ];
  }

  static Future<void> _refreshCatalogAfterStartup({
    required String dataRoot,
    required List<Rpcs3LibraryGame> games,
    required SqliteConfigProvider configProvider,
    required SqliteDatabaseProvider databaseProvider,
  }) async {
    try {
      final enriched = await _applyTitleFallbacks(games, allowNetwork: true);
      var changed = enriched.length != games.length;
      if (!changed) {
        for (var index = 0; index < games.length; index++) {
          if (games[index].title != enriched[index].title) {
            changed = true;
            break;
          }
        }
      }
      if (!changed) return;

      final result = await _importIntoNeoStation(enriched);
      await _replaceCache(enriched);
      await _writeDebugFile(
        dataRoot: dataRoot,
        games: enriched,
        result: result,
      );
      await databaseProvider.loadGamesForSystem('ps3');
      await configProvider.refreshDetectedSystems();
      _log.i('Rpcs3LibraryService: applied background PS3 title enrichment.');
    } catch (error) {
      _log.w('Rpcs3LibraryService: background title enrichment failed: $error');
    }
  }

  static Future<bool> _canReadDataRoot(String dataRoot) async {
    try {
      final directory = Directory(dataRoot);
      if (!await directory.exists()) return false;
      // Listing zero entries is still a successful access probe. The point is
      // to distinguish an empty RPCS3 library from a sandbox/bookmark failure.
      await directory.list(followLinks: false).take(1).toList();
      return true;
    } catch (error) {
      _log.w('Rpcs3LibraryService: Data-root read probe failed: $error');
      return false;
    }
  }

  static Future<void> _retryLiveReconcileAfterStartup({
    required SqliteConfigProvider configProvider,
    required SqliteDatabaseProvider databaseProvider,
  }) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    final dataRoot = await _resolveLinkedDataRoot();
    if (dataRoot == null || !await _canReadDataRoot(dataRoot)) {
      await _writeStartupDebugFile(
        mode: 'DELAYED_RECONCILE_UNAVAILABLE',
        dataRoot: dataRoot,
        readable: false,
      );
      return;
    }

    try {
      final discovered = await discoverLibrary(dataRoot);
      final games = await _applyTitleFallbacks(discovered, allowNetwork: false);
      final result = await _importIntoNeoStation(games);
      await _replaceCache(games);
      await _writeDebugFile(dataRoot: dataRoot, games: games, result: result);
      await _writeStartupDebugFile(
        mode: 'DELAYED_LIVE_RECONCILE',
        dataRoot: dataRoot,
        readable: true,
        gameCount: games.length,
        removedRows: result.removedRows,
      );
      await databaseProvider.loadGamesForSystem('ps3');
      await configProvider.refreshDetectedSystems();
    } catch (error) {
      await _writeStartupDebugFile(
        mode: 'DELAYED_RECONCILE_FAILED',
        dataRoot: dataRoot,
        readable: true,
        error: error.toString(),
      );
    }
  }

  static Future<void> _refreshCachedCatalogAfterStartup({
    required List<Rpcs3LibraryGame> games,
    required SqliteConfigProvider configProvider,
    required SqliteDatabaseProvider databaseProvider,
  }) async {
    try {
      final enriched = await _applyTitleFallbacks(games, allowNetwork: true);
      var changed = enriched.length != games.length;
      if (!changed) {
        for (var index = 0; index < games.length; index++) {
          if (games[index].title != enriched[index].title) {
            changed = true;
            break;
          }
        }
      }
      if (!changed) return;

      await _importIntoNeoStation(enriched);
      await _replaceCache(enriched);
      await databaseProvider.loadGamesForSystem('ps3');
      await configProvider.refreshDetectedSystems();
      _log.i('Rpcs3LibraryService: enriched cached PS3 titles in background.');
    } catch (error) {
      _log.w('Rpcs3LibraryService: cached title enrichment failed: $error');
    }
  }

  static Future<void> _writeStartupDebugFile({
    required String mode,
    required String? dataRoot,
    required bool readable,
    int? gameCount,
    int? removedRows,
    String? error,
  }) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File(path.join(docs.path, 'rpcs3_startup_debug.txt'));
      await file.writeAsString(
        'Timestamp: ${DateTime.now().toIso8601String()}\n'
        'Mode: $mode\n'
        'Data root: ${dataRoot ?? '<none>'}\n'
        'Readable: $readable\n'
        'Cache count: ${_cache?.length ?? 0}\n'
        'Game count: ${gameCount ?? -1}\n'
        'Removed rows: ${removedRows ?? -1}\n'
        'Error: ${error ?? '<none>'}\n',
        flush: true,
      );
    } catch (_) {}
  }

  static Future<String?> _normalizeDataRoot(String selectedPath) async {
    final normalized = path.normalize(selectedPath);
    final selected = Directory(normalized);
    if (!await selected.exists()) return null;

    if (path.basename(normalized).toLowerCase() == 'data') {
      return normalized;
    }

    final dataChild = Directory(path.join(normalized, 'Data'));
    if (await dataChild.exists()) return path.normalize(dataChild.path);

    if (await _looksLikeDataRoot(selected)) return normalized;
    return null;
  }

  @visibleForTesting
  static Future<String?> normalizeDataRootForTesting(String selectedPath) {
    return _normalizeDataRoot(selectedPath);
  }

  static Future<bool> _looksLikeDataRoot(Directory directory) async {
    for (final relative in const <String>[
      'dev_hdd0',
      'games',
      'games.yml',
      'Icons',
    ]) {
      final candidate = path.join(directory.path, relative);
      if (await FileSystemEntity.type(candidate) !=
          FileSystemEntityType.notFound) {
        return true;
      }
    }
    return false;
  }

  static Future<Rpcs3LibraryGame?> _gameFromSfo(
    File sfo, {
    required String dataRoot,
    required String sourceKind,
    required bool hddRules,
    String? expectedTitleId,
  }) async {
    try {
      final values = parseParamSfoBytes(await sfo.readAsBytes());
      var titleId = _cleanTitleId(values['TITLE_ID']?.toString() ?? '');
      if (titleId.isEmpty) titleId = _cleanTitleId(expectedTitleId ?? '');
      if (titleId.isEmpty) return null;

      final category =
          values['CATEGORY']?.toString().trim().toUpperCase() ?? '';
      if (hddRules) {
        if (!_isHddCategory(category)) return null;
      } else if (category.isNotEmpty &&
          category != 'DG' &&
          !_isHddCategory(category)) {
        return null;
      }

      var title = values['TITLE']?.toString().trim() ?? '';
      if (title.isEmpty) title = titleId;
      final version = values['APP_VER']?.toString().trim().isNotEmpty == true
          ? values['APP_VER']!.toString().trim()
          : values['VERSION']?.toString().trim() ?? '';

      final metadataDir = sfo.parent;
      final gameRoot =
          path.basename(metadataDir.path).toUpperCase() == 'PS3_GAME'
          ? metadataDir.parent.path
          : metadataDir.path;
      final iconPath =
          await _findFileCaseInsensitive(metadataDir, 'ICON0.PNG') ??
          await _findCachedIcon(dataRoot, titleId);

      return Rpcs3LibraryGame(
        titleId: titleId,
        title: title,
        version: version,
        category: category,
        sourcePath: gameRoot,
        sourceKind: sourceKind,
        iconPath: iconPath,
      );
    } catch (e) {
      _log.w('Rpcs3LibraryService: ignored invalid ${sfo.path}: $e');
      return null;
    }
  }

  /// Parses Sony's binary PSF/SFO format used by PARAM.SFO.
  @visibleForTesting
  static Map<String, Object> parseParamSfoBytes(Uint8List bytes) {
    if (bytes.length < 20 ||
        bytes[0] != 0x00 ||
        bytes[1] != 0x50 ||
        bytes[2] != 0x53 ||
        bytes[3] != 0x46) {
      throw const FormatException('Not a PSF/PARAM.SFO file.');
    }

    final data = ByteData.sublistView(bytes);
    final version = data.getUint32(4, Endian.little);
    if (version != 0x00000101) {
      throw FormatException(
        'Unsupported PSF version 0x${version.toRadixString(16)}.',
      );
    }

    final keyTableOffset = data.getUint32(8, Endian.little);
    final dataTableOffset = data.getUint32(12, Endian.little);
    final entryCount = data.getUint32(16, Endian.little);
    if (keyTableOffset < 20 ||
        keyTableOffset > dataTableOffset ||
        dataTableOffset > bytes.length ||
        entryCount > 4096 ||
        20 + entryCount * 16 > bytes.length) {
      throw const FormatException('Corrupt PARAM.SFO header.');
    }

    final result = <String, Object>{};
    for (var index = 0; index < entryCount; index++) {
      final entryOffset = 20 + index * 16;
      final keyOffset = data.getUint16(entryOffset, Endian.little);
      final format = data.getUint16(entryOffset + 2, Endian.little);
      final valueLength = data.getUint32(entryOffset + 4, Endian.little);
      final valueOffset = data.getUint32(entryOffset + 12, Endian.little);

      final absoluteKeyOffset = keyTableOffset + keyOffset;
      final absoluteValueOffset = dataTableOffset + valueOffset;
      if (absoluteKeyOffset >= bytes.length ||
          absoluteValueOffset > bytes.length ||
          absoluteValueOffset + valueLength > bytes.length) {
        throw const FormatException('Corrupt PARAM.SFO entry.');
      }

      final keyEnd = _findZeroByte(bytes, absoluteKeyOffset, dataTableOffset);
      if (keyEnd <= absoluteKeyOffset) continue;
      final key = utf8
          .decode(
            bytes.sublist(absoluteKeyOffset, keyEnd),
            allowMalformed: true,
          )
          .trim();
      if (key.isEmpty) continue;

      switch (format) {
        case 0x0004:
        case 0x0204:
          final raw = bytes.sublist(
            absoluteValueOffset,
            absoluteValueOffset + valueLength,
          );
          final zero = raw.indexOf(0);
          final textBytes = zero >= 0 ? raw.sublist(0, zero) : raw;
          result[key] = utf8.decode(textBytes, allowMalformed: true).trim();
          break;
        case 0x0404:
          if (valueLength >= 4 && absoluteValueOffset + 4 <= bytes.length) {
            result[key] = data.getUint32(absoluteValueOffset, Endian.little);
          }
          break;
        default:
          break;
      }
    }
    return result;
  }

  static int _findZeroByte(Uint8List bytes, int start, int limit) {
    final safeLimit = limit.clamp(start, bytes.length) as int;
    for (var i = start; i < safeLimit; i++) {
      if (bytes[i] == 0) return i;
    }
    return safeLimit;
  }

  static bool _isHddCategory(String category) {
    return category.length == 2 &&
        category[1] != 'D' &&
        category != 'DG' &&
        category != 'MS';
  }

  static String _cleanTitleId(String value) {
    final cleaned = value.trim().toUpperCase();
    return RegExp(r'^[A-Z0-9._-]{3,32}$').hasMatch(cleaned) ? cleaned : '';
  }

  static Future<List<File>> _findNamedFiles(
    Directory root, {
    required String targetName,
    required int maxDepth,
  }) async {
    final result = <File>[];
    final wanted = targetName.toLowerCase();
    const skippedDirectories = <String>{
      'usrdir',
      'tropdir',
      'licdir',
      'ps3_extra',
      'cache',
      'caches',
      'shaderlog',
    };

    Future<void> walk(Directory directory, int depth) async {
      if (depth > maxDepth) return;
      List<FileSystemEntity> entries;
      try {
        entries = await directory.list(followLinks: false).toList();
      } catch (_) {
        return;
      }

      for (final entry in entries) {
        final name = path.basename(entry.path).toLowerCase();
        if (entry is File) {
          if (name == wanted) result.add(entry);
        } else if (entry is Directory &&
            depth < maxDepth &&
            !skippedDirectories.contains(name) &&
            !name.startsWith('.')) {
          await walk(entry, depth + 1);
        }
      }
    }

    await walk(root, 0);
    return result;
  }

  static Future<String?> _findFileCaseInsensitive(
    Directory directory,
    String fileName,
  ) async {
    if (!await directory.exists()) return null;
    final wanted = fileName.toLowerCase();
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File &&
            path.basename(entity.path).toLowerCase() == wanted) {
          return entity.path;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> _findCachedIcon(
    String dataRoot,
    String titleId,
  ) async {
    final iconRoot = Directory(path.join(dataRoot, 'Icons', 'game_icons'));
    final titleDir = Directory(path.join(iconRoot.path, titleId));
    for (final directory in <Directory>[titleDir, iconRoot]) {
      if (!await directory.exists()) continue;
      try {
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is! File) continue;
          final lower = path.basename(entity.path).toLowerCase();
          if (lower == 'icon0.png' ||
              lower == '${titleId.toLowerCase()}.png' ||
              lower == '${titleId.toLowerCase()}.jpg' ||
              lower == '${titleId.toLowerCase()}.jpeg') {
            return entity.path;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  @visibleForTesting
  static Map<String, String> parseGamesYmlTextForTesting(String text) {
    final result = <String, String>{};
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty ||
          line.startsWith('#') ||
          line == '---' ||
          line == '...') {
        continue;
      }
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final key = _decodeYamlScalar(line.substring(0, colon));
      final value = _decodeYamlScalar(line.substring(colon + 1));
      if (key.isNotEmpty && value.isNotEmpty) result[key] = value;
    }
    return result;
  }

  static String _decodeYamlScalar(String value) {
    var text = value.trim();
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        return jsonDecode(text).toString();
      } catch (_) {
        text = text.substring(1, text.length - 1);
      }
    } else if (text.length >= 2 && text.startsWith("'") && text.endsWith("'")) {
      text = text.substring(1, text.length - 1).replaceAll("''", "'");
    }
    return text.trim();
  }

  static Future<String?> _findEntityByBasename(
    Directory root,
    String basename, {
    required int maxDepth,
  }) async {
    if (!await root.exists()) return null;
    final wanted = basename.toLowerCase();

    Future<String?> walk(Directory directory, int depth) async {
      if (depth > maxDepth) return null;
      try {
        await for (final entity in directory.list(followLinks: false)) {
          if (path.basename(entity.path).toLowerCase() == wanted) {
            return entity.path;
          }
          if (entity is Directory && depth < maxDepth) {
            final found = await walk(entity, depth + 1);
            if (found != null) return found;
          }
        }
      } catch (_) {}
      return null;
    }

    return walk(root, 0);
  }

  static void _putPreferred(
    Map<String, Rpcs3LibraryGame> target,
    Rpcs3LibraryGame candidate,
  ) {
    final key = candidate.titleId.toLowerCase();
    final current = target[key];
    if (current == null ||
        _metadataScore(candidate) > _metadataScore(current)) {
      target[key] = candidate;
    }
  }

  static int _metadataScore(Rpcs3LibraryGame game) {
    var score = 0;
    if (game.title.isNotEmpty && game.title != game.titleId) score += 4;
    if (game.version.isNotEmpty) score += 1;
    if (game.category.isNotEmpty) score += 1;
    if (game.iconPath != null) score += 4;
    if (game.sourceKind != 'games.yml') score += 2;
    return score;
  }

  static Future<Rpcs3SyncResult> _importIntoNeoStation(
    List<Rpcs3LibraryGame> games,
  ) async {
    final ps3 = await SystemRepository.getSystemByFolderName('ps3');
    if (ps3?.id == null) {
      throw StateError('NeoStation PS3 system definition was not found.');
    }

    final systemId = ps3!.id!;
    final db = await SqliteService.getDatabase();
    final existingRows = await db.rawQuery(
      'SELECT filename, rom_path, title_id, title_name '
      'FROM user_roms WHERE app_system_id = ?',
      <Object?>[systemId],
    );

    final physicalByTitleId = <String, Map<String, Object?>>{};
    final physicalByTitleName = <String, Map<String, Object?>>{};
    for (final row in existingRows) {
      final romPath = row['rom_path']?.toString() ?? '';
      if (isVirtualLibraryPath(romPath)) continue;
      final titleId = row['title_id']?.toString().trim() ?? '';
      final titleName = row['title_name']?.toString().trim() ?? '';
      if (titleId.isNotEmpty) physicalByTitleId[titleId.toLowerCase()] = row;
      if (titleName.isNotEmpty) {
        physicalByTitleName[titleName.toLowerCase()] = row;
      }
    }

    final desiredVirtualPaths = <String>{};
    final artwork = <({String filename, String iconPath})>[];
    var virtualRows = 0;
    var physicalRows = 0;

    await db.transaction((txn) async {
      for (final game in games) {
        Map<String, Object?>? physical =
            physicalByTitleId[game.titleId.toLowerCase()] ??
            physicalByTitleName[game.title.toLowerCase()];

        if (physical != null) {
          final physicalPath = physical['rom_path']?.toString() ?? '';
          if (physicalPath.isNotEmpty) {
            await txn.rawUpdate(
              '''
              UPDATE user_roms SET
                title_id = CASE
                  WHEN title_id IS NULL OR title_id = '' THEN ? ELSE title_id END,
                title_name = CASE
                  WHEN title_name IS NULL OR title_name = ''
                    OR UPPER(TRIM(title_name)) = UPPER(TRIM(COALESCE(title_id, '')))
                    OR UPPER(TRIM(title_name)) = UPPER(TRIM(filename))
                  THEN ? ELSE title_name END,
                updated_at = datetime('now')
              WHERE rom_path = ?
              ''',
              <Object?>[game.titleId, game.title, physicalPath],
            );
          }
          final filename = physical['filename']?.toString() ?? '';
          if (filename.isNotEmpty && game.iconPath != null) {
            artwork.add((filename: filename, iconPath: game.iconPath!));
          }
          physicalRows++;
          continue;
        }

        final virtualUri = Uri(
          scheme: _virtualScheme,
          host: 'game',
          queryParameters: <String, String>{'title-id': game.titleId},
        );
        final virtualPath = virtualUri.toString();
        desiredVirtualPaths.add(virtualPath);
        final syntheticFilename = game.titleId;

        await txn.rawInsert(
          '''
          INSERT INTO user_roms
            (app_system_id, app_emulator_unique_id, app_emulator_os_id,
             filename, rom_path, title_id, title_name,
             created_at, updated_at)
          VALUES (?, NULL, NULL, ?, ?, ?, ?, datetime('now'), datetime('now'))
          ON CONFLICT(rom_path) DO UPDATE SET
            app_system_id = excluded.app_system_id,
            filename = excluded.filename,
            title_id = excluded.title_id,
            title_name = excluded.title_name,
            updated_at = datetime('now')
          ''',
          <Object?>[
            systemId,
            syntheticFilename,
            virtualPath,
            game.titleId,
            game.title,
          ],
        );

        await txn.rawUpdate(
          '''
          UPDATE user_screenscraper_metadata
          SET real_name = NULL
          WHERE app_system_id = ?
            AND filename IN (?, ?)
            AND real_name IS NOT NULL
            AND (
              UPPER(TRIM(real_name)) = UPPER(TRIM(?))
              OR UPPER(TRIM(real_name)) = UPPER(TRIM(?))
              OR UPPER(TRIM(real_name)) = UPPER(TRIM(?))
            )
          ''',
          <Object?>[
            systemId,
            syntheticFilename,
            '${game.titleId}.rpcs3',
            game.titleId,
            syntheticFilename,
            '${game.titleId}.rpcs3',
          ],
        );

        if (game.iconPath != null) {
          artwork.add((filename: syntheticFilename, iconPath: game.iconPath!));
        }
        virtualRows++;
      }
    });

    final virtualRowsInDb = await db.rawQuery(
      "SELECT rom_path FROM user_roms WHERE app_system_id = ? "
      "AND rom_path LIKE 'rpcs3-library://%'",
      <Object?>[systemId],
    );
    final stalePaths = virtualRowsInDb
        .map((row) => row['rom_path']?.toString() ?? '')
        .where(
          (romPath) =>
              romPath.isNotEmpty && !desiredVirtualPaths.contains(romPath),
        )
        .toList();

    var removedRows = 0;
    if (stalePaths.isNotEmpty) {
      await db.transaction((txn) async {
        const batchSize = 100;
        for (var i = 0; i < stalePaths.length; i += batchSize) {
          final end = (i + batchSize < stalePaths.length)
              ? i + batchSize
              : stalePaths.length;
          final batch = stalePaths.sublist(i, end);
          final placeholders = List.filled(batch.length, '?').join(',');
          removedRows += await txn.rawDelete(
            'DELETE FROM user_roms WHERE app_system_id = ? '
            'AND rom_path IN ($placeholders)',
            <Object?>[systemId, ...batch],
          );
        }
      });
    }

    await _repairPersistedRpcs3Names(games, systemId);

    final artworkFiles = await _writeArtwork(artwork);
    final countRows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM user_roms WHERE app_system_id = ?',
      <Object?>[systemId],
    );
    final totalPs3Rows = int.tryParse('${countRows.first['count'] ?? 0}') ?? 0;

    if (totalPs3Rows > 0) {
      await SystemRepository.addDetectedSystem(systemId, 'ps3');
    } else {
      await SystemRepository.removeDetectedSystem(systemId);
    }

    return Rpcs3SyncResult(
      discoveredGames: games.length,
      virtualRows: virtualRows,
      physicalRows: physicalRows,
      artworkFiles: artworkFiles,
      removedRows: removedRows,
      totalPs3Rows: totalPs3Rows,
    );
  }

  static Future<void> _repairPersistedRpcs3Names(
    List<Rpcs3LibraryGame> games,
    String systemId,
  ) async {
    if (games.isEmpty) return;

    final db = await SqliteService.getDatabase();
    final romInfo = await db.rawQuery('PRAGMA table_info(user_roms)');
    final romColumns = romInfo
        .map((row) => row['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .toSet();
    final metadataInfo = await db.rawQuery(
      'PRAGMA table_info(user_screenscraper_metadata)',
    );
    final metadataColumns = metadataInfo
        .map((row) => row['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .toSet();

    final romRepairColumns = <String>[
      for (final column in const <String>[
        'real_name',
        'ss_real_name',
        'game_display_name',
      ])
        if (romColumns.contains(column)) column,
    ];
    final metadataRepairColumns = <String>[
      for (final column in const <String>[
        'real_name',
        'ss_real_name',
        'game_display_name',
      ])
        if (metadataColumns.contains(column)) column,
    ];
    final metadataHasFilename = metadataColumns.contains('filename');
    final metadataHasSystem = metadataColumns.contains('app_system_id');

    var repairedValues = 0;
    await db.transaction((txn) async {
      for (final game in games) {
        final titleId = game.titleId.trim().toUpperCase();
        final title = game.title.trim();
        if (titleId.isEmpty || title.isEmpty) continue;
        final normalizedTitle = title.toUpperCase();
        if (normalizedTitle == titleId || normalizedTitle == '$titleId.RPCS3') {
          continue;
        }

        // Always refresh the authoritative local title. This migrates rows
        // created by earlier builds where title_name was only the serial.
        repairedValues += await txn.rawUpdate(
          '''
          UPDATE user_roms
          SET title_name = ?, updated_at = datetime('now')
          WHERE app_system_id = ?
            AND (
              UPPER(TRIM(COALESCE(title_id, ''))) = ?
              OR UPPER(TRIM(filename)) IN (?, ?)
            )
            AND (
              title_name IS NULL
              OR TRIM(title_name) = ''
              OR UPPER(TRIM(title_name)) IN (?, ?)
            )
          ''',
          <Object?>[
            title,
            systemId,
            titleId,
            titleId,
            '$titleId.RPCS3',
            titleId,
            '$titleId.RPCS3',
          ],
        );

        // Some historical databases carried presentation fields directly on
        // user_roms. Only clear values that normalize exactly to the serial.
        for (final column in romRepairColumns) {
          repairedValues += await txn.rawUpdate(
            '''
            UPDATE user_roms
            SET $column = NULL, updated_at = datetime('now')
            WHERE app_system_id = ?
              AND (
                UPPER(TRIM(COALESCE(title_id, ''))) = ?
                OR UPPER(TRIM(filename)) IN (?, ?)
              )
              AND UPPER(
                REPLACE(TRIM(COALESCE($column, '')), '.RPCS3', '')
              ) = ?
            ''',
            <Object?>[systemId, titleId, titleId, '$titleId.RPCS3', titleId],
          );
        }

        // Current ScreenScraper metadata is stored in a separate table. Query
        // its schema first because older installations may expose only a subset
        // of these columns.
        if (!metadataHasFilename) continue;
        for (final column in metadataRepairColumns) {
          final systemClause = metadataHasSystem ? 'AND app_system_id = ?' : '';
          final arguments = <Object?>[
            titleId,
            '$titleId.RPCS3',
            if (metadataHasSystem) systemId,
            titleId,
          ];
          repairedValues += await txn.rawUpdate('''
            UPDATE user_screenscraper_metadata
            SET $column = NULL
            WHERE UPPER(TRIM(filename)) IN (?, ?)
              $systemClause
              AND UPPER(
                REPLACE(TRIM(COALESCE($column, '')), '.RPCS3', '')
              ) = ?
            ''', arguments);
        }
      }
    });

    if (repairedValues > 0) {
      _log.i(
        'Rpcs3LibraryService: repaired $repairedValues legacy synthetic '
        'metadata value(s).',
      );
    }
  }

  static Future<int> _writeArtwork(
    List<({String filename, String iconPath})> items,
  ) async {
    if (items.isEmpty) return 0;

    final mediaRoot = await ConfigService.getMediaPath();
    final directories = <Directory>[
      Directory(path.join(mediaRoot, 'ps3', 'box2d')),
      Directory(path.join(mediaRoot, 'ps3', 'screenshots')),
    ];
    for (final directory in directories) {
      await directory.create(recursive: true);
    }

    var written = 0;
    for (final item in items) {
      final source = File(item.iconPath);
      if (!await source.exists()) continue;
      final bytes = await source.readAsBytes();
      if (bytes.isEmpty) continue;

      final mediaKey = FileProvider.stripRomExtension(item.filename);
      var extension = path
          .extension(source.path)
          .toLowerCase()
          .replaceFirst('.', '');
      if (!const <String>{'png', 'jpg', 'jpeg', 'webp'}.contains(extension)) {
        extension = 'png';
      }

      for (final directory in directories) {
        var hasExisting = false;
        for (final candidateExtension in const <String>[
          'png',
          'jpg',
          'jpeg',
          'webp',
        ]) {
          if (await File(
            path.join(directory.path, '$mediaKey.$candidateExtension'),
          ).exists()) {
            hasExisting = true;
            break;
          }
        }
        if (hasExisting) continue;

        await File(path.join(directory.path, '$mediaKey.$extension'))
            .writeAsBytes(bytes, flush: true);
        written++;
      }
    }
    return written;
  }

  static Future<void> _refreshNeoStationUi() async {
    try {
      final context = rootNavigatorKey.currentContext;
      if (context == null) return;
      await Provider.of<SqliteDatabaseProvider>(
        context,
        listen: false,
      ).loadGamesForSystem('ps3');
      await Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      ).refreshDetectedSystems();
    } catch (e) {
      _log.e('Rpcs3LibraryService: UI refresh failed: $e');
    }
  }

  static Future<void> loadCachedLibrary() async {
    if (_cache != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _syncCompleted = prefs.getBool(_syncCompletedKey) ?? false;
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) {
        _cache = <String, Rpcs3LibraryGame>{};
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _cache = <String, Rpcs3LibraryGame>{};
        return;
      }
      _cache = decoded.map(
        (key, value) => MapEntry(
          key.toString(),
          Rpcs3LibraryGame.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      );
    } catch (e) {
      _log.w('Rpcs3LibraryService: could not load cache: $e');
      _cache = <String, Rpcs3LibraryGame>{};
    }
  }

  static Future<void> _persistCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cache = _cache ?? <String, Rpcs3LibraryGame>{};
      await prefs.setString(
        _prefsKey,
        jsonEncode(cache.map((key, value) => MapEntry(key, value.toJson()))),
      );
      await prefs.setBool(_syncCompletedKey, _syncCompleted);
    } catch (e) {
      _log.w('Rpcs3LibraryService: could not save cache: $e');
    }
  }

  static Future<void> _writeDebugFile({
    required String dataRoot,
    required List<Rpcs3LibraryGame> games,
    required Rpcs3SyncResult result,
  }) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File(path.join(docs.path, 'rpcs3_sync_debug.txt'));
      final payload = games.map((game) => game.toJson()).toList();
      await file.writeAsString(
        'STATE: IMPORTED\n'
        'RPCS3 Data root: $dataRoot\n'
        'Discovered games: ${result.discoveredGames}\n'
        'Virtual PS3 rows: ${result.virtualRows}\n'
        'Existing physical PS3 rows reused: ${result.physicalRows}\n'
        'Artwork files written: ${result.artworkFiles}\n'
        'Stale RPCS3 rows removed: ${result.removedRows}\n'
        'PS3 rows now in NeoStation: ${result.totalPs3Rows}\n\n'
        '${const JsonEncoder.withIndent('  ').convert(payload)}',
        flush: true,
      );
    } catch (e) {
      _log.w('Rpcs3LibraryService: could not write debug file: $e');
    }
  }
}
