import 'dart:convert';
import 'dart:io';

import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/retroarch_appstore_launch_target.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// RetroArch App Store integration only.
///
/// RetroArch 1.22.2 exposes `retroarch://game/<value>`. For ordinary playlist
/// entries, `<value>` is the filename RetroArch derives with `path_basename()`.
/// Archive entries require an extra workaround: when a playlist/default core
/// is still DETECT, sending only the archive member filename can enter
/// RetroArch's playlist shortcut branch without a usable core. In that case we
/// send RetroArch's own archive container path instead. Its fallback launcher
/// can validate the ZIP, inspect its members and select a compatible core.
class RetroArchAppStoreService {
  RetroArchAppStoreService._();

  static final _log = LoggerService.instance;

  // v3 persists the raw playlist path as well as the filename index. This is
  // required because archive launches need RetroArch's own `~/Documents/...`
  // container path even after NeoStation itself has been restarted.
  static const String _cacheKey = 'retroarch_appstore_launch_cache_v3';
  static const String _rootKey = 'retroarch_appstore_launch_root_v3';
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
    // playlist-derived index is strong independent evidence of ownership.
    final basename = path.basename(romPath);
    return _launchIds.containsKey(basename) ||
        _launchIds.containsKey(basename.toLowerCase());
  }

  /// App Store sync stays local. It also refreshes the exact launch index from
  /// RetroArch's own .lpl files when the Playlist/Playlists directory is
  /// available under the linked RetroArch root.
  static Future<bool> syncLinkedLibrary() async {
    final root = ConfigService.linkedExternalFolderPath;
    if (root == null || root.trim().isEmpty) {
      await _writeDebugFile(
        'retroarch_appstore_index_debug.txt',
        '[RetroArch Index Rebuild]\n'
        'result=ABORTED: linkedExternalFolderPath is null/empty\n',
      );
      return false;
    }
    try {
      final rootExists = await Directory(root).exists();
      if (!rootExists) {
        await _writeDebugFile(
          'retroarch_appstore_index_debug.txt',
          '[RetroArch Index Rebuild]\n'
          'result=ABORTED: Directory(root).exists() == false\n'
          'root=$root\n'
          '(this usually means the security-scoped bookmark for this '
          'folder is stale/unreachable -- try unlinking and relinking the '
          'RetroArch folder in Settings)\n',
        );
        return false;
      }
      await _rebuildLaunchIndex(root);

      final context = rootNavigatorKey.currentContext;
      if (context != null) {
        await Provider.of<SqliteConfigProvider>(context, listen: false)
            .scanSystems();
      }
      return true;
    } catch (e, st) {
      _log.e('RetroArch App Store library scan failed: $e');
      await _writeDebugFile(
        'retroarch_appstore_index_debug.txt',
        '[RetroArch Index Rebuild]\n'
        'result=EXCEPTION\n'
        'root=$root\n'
        'error=$e\n'
        'stackTrace=\n$st\n',
      );
      return false;
    }
  }

  /// Returns the exact filename RetroArch exposes for this playlist entry.
  ///
  /// Important archive rule from RetroArch's own `path_basename()`:
  /// - `/roms/game.zip` -> `game.zip`
  /// - `/roms/game.zip#game.32x` -> `game.32x`
  ///
  /// The archive member is derived only from RetroArch's own playlist. It is
  /// still useful as an index key even though archive *launches* now use the
  /// container path to force RetroArch's automatic core-detection fallback.
  static Future<String?> launchIdForRomPath(String romPath) async {
    await _loadCache();
    final currentRoot = _normalizedRoot();
    if (currentRoot != null && !_sameRoot(_cacheRoot, currentRoot)) {
      await _rebuildLaunchIndex(currentRoot);
    }

    final indexed = _lookup(_launchIds, romPath);
    if (indexed != null && indexed.isNotEmpty) return indexed;

    final fallback = path.basename(romPath);
    return fallback.isEmpty ? null : fallback;
  }

  /// Direct launch for the App Store build. No Share sheet, no Open In, no
  /// temporary copy, and no ZIP extraction in NeoStation.
  static Future<bool> launchGameByRomPath(String romPath) async {
    try {
      // Load/rebuild the index before the ownership check. This also handles
      // the case where iOS changed the security-scoped container prefix after
      // a restart and ownership has to fall back to the playlist basename.
      final launchId = await launchIdForRomPath(romPath);
      if (!ownsRomPath(romPath)) return false;
      if (!await File(romPath).exists()) return false;

      if (launchId == null || launchId.isEmpty) {
        _log.w(
          'RetroArch App Store: no launch filename for ${path.basename(romPath)}.',
        );
        return true;
      }

      final fullPlaylistPath = _fullPlaylistPathFor(romPath);
      final archiveContainerPath =
          RetroArchAppStoreLaunchTarget.archiveContainerPath(fullPlaylistPath);
      final launchTarget = RetroArchAppStoreLaunchTarget.select(
        launchId: launchId,
        fullPlaylistPath: fullPlaylistPath,
      );
      final uri = RetroArchAppStoreLaunchTarget.buildUri(launchTarget);

      // For a RetroArch playlist path such as:
      //   .../game.zip#game.32x
      // the shortcut receives the existing archive container:
      //   .../game.zip
      // This deliberately avoids the playlist-filename branch that can hand
      // `DETECT` to the loader as though it were an actual core path. The
      // fallback in cocoa_launch_game_by_filename() then validates the ZIP and
      // asks core_info_list_get_supported_cores() to inspect the archive.
      final isArchive = archiveContainerPath != null;
      final strategy = isArchive
          ? 'archive-container-auto-detect'
          : 'playlist-filename';

      await _writeDebugFile(
        'retroarch_appstore_launch_debug.txt',
        '[RetroArch Launch]\n'
        'variant=appstore\n'
        'sourcePath=$romPath\n'
        'playlistPath=${fullPlaylistPath ?? '(not indexed)'}\n'
        'playlistLaunchId=$launchId\n'
        'isArchive=$isArchive\n'
        'archiveContainerPath=${archiveContainerPath ?? '(none)'}\n'
        'strategy=$strategy\n'
        'launchPath(sent)=$launchTarget\n'
        'encodedPath=${Uri.encodeComponent(launchTarget)}\n'
        'finalURL=$uri\n',
      );

      _log.i(
        'RetroArch App Store: launching ${path.basename(romPath)} '
        'with $strategy.',
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

              final mapping =
                  RetroArchAppStoreLaunchTarget.mappingFromPlaylistPath(
                contentPath,
              );
              if (mapping == null) continue;
              final physicalPath = mapping.$1;
              final launchId = mapping.$2;

              // Exact path wins. Basename/stem aliases provide resilience when
              // iOS presents the same security-scoped location through a
              // different absolute container prefix.
              _put(index, physicalPath, launchId);
              _put(index, path.basename(physicalPath), launchId);
              _put(index, path.basenameWithoutExtension(physicalPath), launchId);

              // This path is launch-critical for archives, not diagnostic-only.
              // Keep RetroArch's raw string intact (`~`, accents, spaces and
              // `#member`) so the correct archive container can be reconstructed
              // inside RetroArch's own sandbox after an app restart.
              _put(fullPaths, physicalPath, contentPath);
              _put(fullPaths, path.basename(physicalPath), contentPath);
              _put(
                fullPaths,
                path.basenameWithoutExtension(physicalPath),
                contentPath,
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
      'RetroArch App Store: indexed ${index.length} launch keys and '
      '${fullPaths.length} playlist-path keys from '
      '${playlists?.path ?? 'no accessible Playlist directory'}.',
    );
    await _writeDebugFile(
      'retroarch_appstore_index_debug.txt',
      '[RetroArch Index Rebuild]\n'
      'root=$root\n'
      'playlistsDirFound=${playlists != null}\n'
      'playlistsDirPath=${playlists?.path ?? '(none found)'}\n'
      'indexedKeys=${index.length}\n'
      'fullPlaylistPathsRecorded=${fullPaths.length}\n',
    );
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

  static String? _lookup(Map<String, String> source, String romPath) {
    final normalized = path.normalize(romPath);
    final basename = path.basename(normalized);
    final stem = path.basenameWithoutExtension(normalized);
    return source[normalized] ??
        source[normalized.toLowerCase()] ??
        source[basename] ??
        source[basename.toLowerCase()] ??
        source[stem] ??
        source[stem.toLowerCase()];
  }

  /// Raw, unsplit playlist `path` field RetroArch recorded for this ROM, e.g.
  /// `~/Documents/.../game.zip#game.32x`.
  static String? _fullPlaylistPathFor(String romPath) {
    return _lookup(_fullPlaylistPaths, romPath);
  }

  static Future<void> _loadCache() async {
    if (_loaded) return;
    _launchIds = <String, String>{};
    _fullPlaylistPaths = <String, String>{};
    _cacheRoot = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final root = prefs.getString(_rootKey);
      final raw = prefs.getString(_cacheKey);
      if (root != null && raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final launchIds = decoded['launchIds'];
          final playlistPaths = decoded['fullPlaylistPaths'];

          if (launchIds is Map) {
            _launchIds = launchIds.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            );
          }
          if (playlistPaths is Map) {
            _fullPlaylistPaths = playlistPaths.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            );
          }
          _cacheRoot = path.normalize(root);
        }
      }
    } catch (e) {
      _log.e('RetroArch App Store: failed loading launch cache: $e');
      _launchIds = <String, String>{};
      _fullPlaylistPaths = <String, String>{};
      _cacheRoot = null;
    }
    _loaded = true;
  }

  static Future<void> _persistCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode(<String, Object>{
          'version': 3,
          'launchIds': _launchIds,
          'fullPlaylistPaths': _fullPlaylistPaths,
        }),
      );
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
