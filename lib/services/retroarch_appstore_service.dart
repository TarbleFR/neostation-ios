import 'dart:convert';
import 'dart:io';

import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// RetroArch App Store integration only.
///
/// The App Store build has no TestFlight library-export callback. NeoStation
/// therefore reads RetroArch's own playlists from the linked security-scoped
/// folder and keeps a private App Store-only mapping from physical ROM path to
/// the content identifier expected by `retroarch://game/...`.
class RetroArchAppStoreService {
  RetroArchAppStoreService._();

  static final _log = LoggerService.instance;

  static const String _cacheKey = 'retroarch_appstore_launch_cache_v1';
  static const String _rootKey = 'retroarch_appstore_launch_root_v1';
  static const Set<String> _ignoredPlaylists = {
    'content_history.lpl',
    'content_image_history.lpl',
    'content_music_history.lpl',
    'content_video_history.lpl',
    'favorites.lpl',
  };

  static Map<String, String> _launchIds = <String, String>{};
  static String? _cacheRoot;
  static bool _loaded = false;

  static bool ownsRomPath(String romPath) {
    final root = ConfigService.linkedExternalFolderPath;
    if (root == null || root.trim().isEmpty || romPath.trim().isEmpty) {
      return false;
    }
    try {
      return path.equals(root, romPath) || path.isWithin(root, romPath);
    } catch (_) {
      return false;
    }
  }

  /// App Store sync is intentionally local. No TestFlight callback is involved.
  /// Besides refreshing NeoStation's scanner, it rebuilds the App Store launch
  /// index from RetroArch's `.lpl` playlists so archived ROMs can be translated
  /// from `game.zip` to the inner content identifier RetroArch registered.
  static Future<bool> syncLinkedLibrary() async {
    final root = ConfigService.linkedExternalFolderPath;
    if (root == null || root.trim().isEmpty) return false;
    try {
      final directory = Directory(root);
      if (!await directory.exists()) return false;

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

  /// Visible for regression tests and diagnostics.
  static Future<String?> launchIdForRomPath(String romPath) async {
    await _loadCache();
    final currentRoot = _normalizedRoot();
    if (!_sameRoot(_cacheRoot, currentRoot)) return null;
    return _lookup(romPath);
  }

  /// Direct-launch path for the App Store distribution.
  ///
  /// Non-archived files can safely fall back to their own basename. ZIP files
  /// must come from the playlist index: sending the archive basename itself
  /// opens RetroArch but leaves it at the main menu with no core/content.
  static Future<bool> launchGameByRomPath(String romPath) async {
    if (!ownsRomPath(romPath)) return false;
    try {
      if (!await File(romPath).exists()) return false;

      await _loadCache();
      final currentRoot = _normalizedRoot();
      if (!_sameRoot(_cacheRoot, currentRoot)) {
        await _rebuildLaunchIndex(currentRoot!);
      }

      final extension = path.extension(romPath).toLowerCase();
      final indexedLaunchId = _lookup(romPath);
      final launchId = indexedLaunchId ??
          (extension == '.zip' ? null : path.basename(romPath));

      if (launchId == null || launchId.isEmpty) {
        _log.w(
          'RetroArch App Store: no playlist launch id for ZIP ${path.basename(romPath)}; '
          'refusing the bad archive-basename deeplink so the caller can use its '
          'playlist/Open In fallback instead.',
        );
        return false;
      }

      final uri = Uri(
        scheme: 'retroarch',
        host: 'game',
        pathSegments: [launchId],
      );
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        _log.w(
          'RetroArch App Store handoff reported false for $uri; treating the '
          'dispatch as terminal to prevent Open In / Share.',
        );
      }
      return true;
    } catch (e) {
      _log.e('RetroArch App Store launch failed: $e');
      return false;
    }
  }

  static Future<void> _rebuildLaunchIndex(String root) async {
    final normalizedRoot = path.normalize(root);
    final index = <String, String>{};
    final playlists = await _findPlaylistsDirectory(normalizedRoot);

    if (playlists != null) {
      try {
        await for (final entity in playlists.list(followLinks: false)) {
          if (entity is! File ||
              path.extension(entity.path).toLowerCase() != '.lpl') {
            continue;
          }
          final name = path.basename(entity.path).toLowerCase();
          if (_ignoredPlaylists.contains(name)) continue;

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

              _put(index, physicalPath, launchId);
              _put(index, path.basename(physicalPath), launchId);
              _put(index, path.basenameWithoutExtension(physicalPath), launchId);
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
    _cacheRoot = normalizedRoot;
    _loaded = true;
    await _persistCache();
    _log.i(
      'RetroArch App Store: indexed ${index.length} launch lookup keys from '
      '${playlists?.path ?? 'no accessible playlists directory'}',
    );
  }

  /// Returns `(physical container path, direct-launch identifier)`.
  /// For libretro archive syntax `archive.zip#game.ext`, the physical file is
  /// the ZIP while the launch id is `game.ext`, matching the TestFlight-side
  /// filename behavior NeoStation already handles.
  static (String, String)? _mappingFromPlaylistPath(String value) {
    final normalized = value.replaceAll('\\', '/');
    final hash = normalized.indexOf('#');
    if (hash > 0 && hash < normalized.length - 1) {
      final container = normalized.substring(0, hash);
      final inner = normalized.substring(hash + 1);
      final innerName = path.basename(inner);
      if (container.isEmpty || innerName.isEmpty) return null;
      return (container, innerName);
    }

    final name = path.basename(normalized);
    if (name.isEmpty) return null;
    return (normalized, name);
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
      try {
        final directory = Directory(normalized);
        if (await directory.exists()) return directory;
      } catch (_) {
        // Security scope may not include this candidate.
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
    final basename = path.basename(romPath);
    final stem = path.basenameWithoutExtension(romPath);
    return _launchIds[romPath] ??
        _launchIds[romPath.toLowerCase()] ??
        _launchIds[basename] ??
        _launchIds[basename.toLowerCase()] ??
        _launchIds[stem] ??
        _launchIds[stem.toLowerCase()];
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
}
