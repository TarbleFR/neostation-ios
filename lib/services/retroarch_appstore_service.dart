import 'dart:convert';
import 'dart:io';

import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// RetroArch App Store integration only.
///
/// RetroArch 1.22.2 exposes `retroarch://game/<filename>`. The iOS handler
/// looks up that filename in RetroArch's own playlists, then launches the
/// playlist entry's full path with its recorded core. NeoStation therefore
/// must reproduce RetroArch's filename derivation exactly instead of copying,
/// extracting, or importing ROMs.
class RetroArchAppStoreService {
  RetroArchAppStoreService._();

  static final _log = LoggerService.instance;

  static const String _cacheKey = 'retroarch_appstore_launch_cache_v2';
  static const String _rootKey = 'retroarch_appstore_launch_root_v2';
  static const Set<String> _ignoredPlaylists = {
    'content_history.lpl',
    'content_image_history.lpl',
    'content_music_history.lpl',
    'content_video_history.lpl',
    'favorites.lpl',
  };

  static Map<String, String> _launchIds = <String, String>{};
  static Map<String, String> _fullPlaylistPaths = <String, String>{};
  static String? _cacheRoot;
  static bool _loaded = false;

  static bool ownsRomPath(String romPath) {
    final root = ConfigService.linkedExternalFolderPath;
    if (root == null || root.trim().isEmpty || romPath.trim().isEmpty) {
      return false;
    }
    try {
      if (path.equals(root, romPath) || path.isWithin(root, romPath)) {
        return true;
      }
    } catch (_) {
      // Fall through to the index-based check below.
    }
    // iOS can re-resolve a security-scoped bookmark under a different
    // absolute container prefix between launches (the UUID segment in
    // `.../File Provider Storage/<UUID>/...` is not guaranteed stable).
    // When that happens the prefix check above spuriously fails even though
    // this is genuinely the linked RetroArch folder. A hit in our own
    // playlist-derived index is strong independent evidence of ownership,
    // so treat it as one instead of hard-failing and silently falling
    // through to the Share Sheet / "Resume Last Game" fallbacks.
    return _launchIds.containsKey(path.basename(romPath)) ||
        _launchIds.containsKey(path.basename(romPath).toLowerCase());
  }

  /// App Store sync stays local. It also refreshes the exact filename index
  /// from RetroArch's own .lpl files when the Playlist/Playlists directory is
  /// available under the linked RetroArch root.
  static Future<bool> syncLinkedLibrary() async {
    final root = ConfigService.linkedExternalFolderPath;
    if (root == null || root.trim().isEmpty) return false;
    try {
      if (!await Directory(root).exists()) return false;
      await _rebuildLaunchIndex(root);

      final context = rootNavigatorKey.currentContext;
      if (context != null) {
        await Provider.of<SqliteConfigProvider>(context, listen: false)
            .scanSystems();
      }
      return true;
    } catch (e) {
      _log.e('RetroArch App Store library scan failed: $e');
      return false;
    }
  }

  /// Returns the exact filename RetroArch 1.22.2 expects after
  /// `retroarch://game/` for this ROM.
  ///
  /// Important archive rule from RetroArch's own `path_basename()`:
  /// - `/roms/game.zip` -> `game.zip`
  /// - `/roms/game.zip#game.32x` -> `game.32x`
  ///
  /// The archive member is only used when RetroArch itself recorded it in its
  /// playlist. NeoStation never opens or inspects the ZIP to guess this value.
  static Future<String?> launchIdForRomPath(String romPath) async {
    await _loadCache();
    final currentRoot = _normalizedRoot();
    if (currentRoot != null && !_sameRoot(_cacheRoot, currentRoot)) {
      await _rebuildLaunchIndex(currentRoot);
    }

    final indexed = _lookup(romPath);
    if (indexed != null && indexed.isNotEmpty) return indexed;

    // If playlists are unavailable, the safest fallback is the physical
    // filename. This is exactly what RetroArch expects for playlist entries
    // that point to the archive/file itself.
    final fallback = path.basename(romPath);
    return fallback.isEmpty ? null : fallback;
  }

  /// Direct launch for the App Store build. No Share sheet, no Open In, no
  /// temporary copy, and no ZIP extraction: RetroArch resolves the playlist
  /// entry, full content path and core itself.
  static Future<bool> launchGameByRomPath(String romPath) async {
    if (!ownsRomPath(romPath)) return false;
    try {
      if (!await File(romPath).exists()) return false;

      final launchId = await launchIdForRomPath(romPath);
      if (launchId == null || launchId.isEmpty) {
        _log.w(
          'RetroArch App Store: no launch filename for ${path.basename(romPath)}.',
        );
        return true;
      }

      final uri = Uri(
        scheme: 'retroarch',
        host: 'game',
        pathSegments: <String>[launchId],
      );

      // TEMP DIAGNOSTIC LOGGING -- remove once ZIP launches are confirmed
      // working on-device. Format requested for comparing a working
      // non-archive launch against a failing archive launch side by side.
      // `containerFilename`/`fullPlaylistPath` are alternate candidates for
      // the deep link filename in case the "member only" theory is wrong;
      // they are NOT sent, only logged, so they can be hand-tested by
      // pasting `retroarch://game/<candidate>` directly into Safari's
      // address bar (bypasses NeoStation entirely, isolates whether the
      // bug is in this derivation or in RetroArch's own matching).
      final extension = path.extension(romPath).toLowerCase();
      final isArchive = extension == '.zip' ||
          extension == '.7z' ||
          extension == '.zst' ||
          extension == '.apk';
      final containerFilename = path.basename(romPath);
      final fullPlaylistPath = _fullPlaylistPathFor(romPath);
      await _writeDebugFile(
        'retroarch_appstore_launch_debug.txt',
        '[RetroArch Launch]\n'
        'variant=appstore\n'
        'sourcePath=$romPath\n'
        'extension=$extension\n'
        'isArchive=$isArchive\n'
        'launchPath(sent)=$launchId\n'
        'candidate_containerOnly=$containerFilename\n'
        'candidate_fullPlaylistPath=${fullPlaylistPath ?? '(not indexed)'}\n'
        'encodedPath=${Uri.encodeComponent(launchId)}\n'
        'finalURL=$uri\n',
      );

      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        _log.w('RetroArch App Store deeplink was not opened: $uri');
      }

      // This ROM belongs to RetroArch. A failed dispatch must never fall
      // through to NeoStation's generic iOS Share/Open-In path.
      return true;
    } catch (e) {
      _log.e('RetroArch App Store launch failed: $e');
      return true;
    }
  }

  static Future<void> _rebuildLaunchIndex(String root) async {
    final normalizedRoot = path.normalize(root);
    final index = <String, String>{};
    final fullPaths = <String, String>{};
    final playlists = await _findPlaylistsDirectory(normalizedRoot);

    if (playlists != null) {
      try {
        await for (final entity in playlists.list(followLinks: false)) {
          if (entity is! File ||
              path.extension(entity.path).toLowerCase() != '.lpl') {
            continue;
          }
          final playlistName = path.basename(entity.path).toLowerCase();
          if (_ignoredPlaylists.contains(playlistName)) continue;

          try {
            final decoded = jsonDecode(await entity.readAsString());
            if (decoded is! Map) continue;
            final items = decoded['items'];
            if (items is! List) continue;

            for (final raw in items) {
              if (raw is! Map) continue;
              final contentPath = raw['path']?.toString();
              if (contentPath == null || contentPath.isEmpty) continue;

              final mapping = _mappingFromPlaylistPath(contentPath);
              if (mapping == null) continue;
              final physicalPath = mapping.$1;
              final launchId = mapping.$2;

              // Exact path wins. Basename/stem aliases only provide resilience
              // when iOS presents the same security-scoped location through a
              // slightly different absolute container prefix.
              _put(index, physicalPath, launchId);
              _put(index, path.basename(physicalPath), launchId);
              _put(index, path.basenameWithoutExtension(physicalPath), launchId);

              // Diagnostic only: remember the raw, unsplit playlist path
              // (e.g. "game.zip#game.32x") so it can be surfaced in the
              // launch debug log without recomputing it at launch time.
              fullPaths.putIfAbsent(physicalPath, () => contentPath);
              fullPaths.putIfAbsent(
                path.basename(physicalPath),
                () => contentPath,
              );
            }
          } catch (e) {
            _log.w('RetroArch App Store: skipped playlist ${entity.path}: $e');
          }
        }
      } catch (e) {
        _log.w('RetroArch App Store: failed listing ${playlists.path}: $e');
      }
    }

    _launchIds = index;
    _fullPlaylistPaths = fullPaths;
    _cacheRoot = normalizedRoot;
    _loaded = true;
    await _persistCache();
    _log.i(
      'RetroArch App Store: indexed ${index.length} launch keys from '
      '${playlists?.path ?? 'no accessible Playlist directory'}.',
    );
  }

  /// Returns `(physical file/container path, deeplink filename)` using the
  /// same archive-basename semantics as RetroArch 1.22.2.
  static (String, String)? _mappingFromPlaylistPath(String value) {
    if (value.isEmpty) return null;
    final normalized = value.replaceAll('\\', '/');
    final archiveHash = _archiveDelimiterIndex(normalized);

    if (archiveHash >= 0 && archiveHash < normalized.length - 1) {
      final container = normalized.substring(0, archiveHash);
      final member = normalized.substring(archiveHash + 1);
      if (container.isEmpty || member.isEmpty) return null;
      // RetroArch path_basename() returns everything after the compression '#'.
      return (container, member);
    }

    final slash = normalized.lastIndexOf('/');
    final filename = slash >= 0 ? normalized.substring(slash + 1) : normalized;
    if (filename.isEmpty) return null;
    return (normalized, filename);
  }

  /// Mirrors `path_get_archive_delim()` in RetroArch 1.22.2's
  /// libretro-common/file/file_path.c *exactly*: only the first `#` that is
  /// directly preceded by a recognized archive extension counts. RetroArch
  /// recognizes four extensions here, not three -- `.zst` was missing from
  /// earlier revisions of this file, which silently mis-derived the launch
  /// filename (falling back to the raw `#`-joined string) for any content
  /// scanned from a `.zst` archive.
  static int _archiveDelimiterIndex(String value) {
    var searchFrom = 0;
    while (true) {
      final hash = value.indexOf('#', searchFrom);
      if (hash < 0) return -1;
      final before = value.substring(0, hash).toLowerCase();
      if (before.endsWith('.zip') ||
          before.endsWith('.7z') ||
          before.endsWith('.zst') ||
          before.endsWith('.apk')) {
        return hash;
      }
      searchFrom = hash + 1;
    }
  }

  static Future<Directory?> _findPlaylistsDirectory(String root) async {
    final rootDirectory = Directory(root);
    final rootName = path.basename(root).toLowerCase();
    if (rootName == 'playlist' || rootName == 'playlists') {
      return rootDirectory;
    }

    // RetroArch upstream uses "playlists"; App Store installations may expose
    // the folder as Playlist/Playlists in Files. Match case-insensitively and
    // support both singular and plural without traversing outside the granted
    // security-scoped root.
    try {
      await for (final entity in rootDirectory.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = path.basename(entity.path).toLowerCase();
        if (name == 'playlist' || name == 'playlists') return entity;
      }
    } catch (_) {
      // Fall through to direct candidates below.
    }

    for (final name in const <String>[
      'Playlist',
      'Playlists',
      'playlist',
      'playlists',
    ]) {
      try {
        final candidate = Directory(path.join(root, name));
        if (await candidate.exists()) return candidate;
      } catch (_) {
        // Security scope may not include the candidate.
      }
    }
    return null;
  }

  static void _put(Map<String, String> target, String key, String value) {
    if (key.isEmpty || value.isEmpty) return;
    target.putIfAbsent(key, () => value);
    target.putIfAbsent(key.toLowerCase(), () => value);
  }

  static String? _lookup(String romPath) {
    final normalized = path.normalize(romPath);
    final basename = path.basename(normalized);
    final stem = path.basenameWithoutExtension(normalized);
    return _launchIds[normalized] ??
        _launchIds[normalized.toLowerCase()] ??
        _launchIds[basename] ??
        _launchIds[basename.toLowerCase()] ??
        _launchIds[stem] ??
        _launchIds[stem.toLowerCase()];
  }

  /// Diagnostic-only: the raw, unsplit playlist `path` field RetroArch
  /// itself recorded for this ROM (e.g. `game.zip#game.32x`), if it was
  /// found in a playlist during the last index rebuild. Never sent in the
  /// deep link -- only surfaced in the launch debug log.
  static String? _fullPlaylistPathFor(String romPath) {
    final normalized = path.normalize(romPath);
    final basename = path.basename(normalized);
    return _fullPlaylistPaths[normalized] ?? _fullPlaylistPaths[basename];
  }

  static Future<void> _loadCache() async {
    if (_loaded) return;
    _launchIds = <String, String>{};
    _cacheRoot = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final root = prefs.getString(_rootKey);
      final raw = prefs.getString(_cacheKey);
      if (root != null && raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _launchIds = decoded.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          );
          _cacheRoot = path.normalize(root);
        }
      }
    } catch (e) {
      _log.e('RetroArch App Store: failed loading launch cache: $e');
    }
    _loaded = true;
  }

  static Future<void> _persistCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(_launchIds));
      if (_cacheRoot == null) {
        await prefs.remove(_rootKey);
      } else {
        await prefs.setString(_rootKey, _cacheRoot!);
      }
    } catch (e) {
      _log.e('RetroArch App Store: failed persisting launch cache: $e');
    }
  }

  static String? _normalizedRoot() {
    final root = ConfigService.linkedExternalFolderPath;
    if (root == null || root.trim().isEmpty) return null;
    return path.normalize(root.trim());
  }

  static bool _sameRoot(String? a, String? b) {
    if (a == null || b == null) return a == b;
    return path.normalize(a).toLowerCase() == path.normalize(b).toLowerCase();
  }

  static Future<void> _writeDebugFile(String name, String content) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      await File(path.join(docsDir.path, name))
          .writeAsString('--- ${DateTime.now()} ---\n$content');
    } catch (e) {
      _log.e('RetroArch App Store: failed writing debug file $name: $e');
    }
  }
}
