import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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
/// therefore resolves launch identifiers locally, using RetroArch playlists
/// when accessible and inspecting one-ROM ZIP archives when they are not.
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

  /// Extensions that reliably identify a single ROM payload inside a ZIP.
  /// Deliberately excludes generic arcade-set members such as .bin/.rom so a
  /// multi-file arcade archive is never mistaken for a one-ROM archive.
  static const Set<String> _directRomExtensions = {
    '.32x',
    '.a26',
    '.a52',
    '.a78',
    '.col',
    '.fds',
    '.gb',
    '.gbc',
    '.gba',
    '.gen',
    '.gg',
    '.j64',
    '.lnx',
    '.md',
    '.n64',
    '.nds',
    '.nes',
    '.ngc',
    '.ngp',
    '.pce',
    '.sfc',
    '.sg',
    '.smc',
    '.sms',
    '.sv',
    '.vec',
    '.v64',
    '.vb',
    '.ws',
    '.wsc',
    '.z64',
    '.cue',
    '.m3u',
  };

  static const Set<String> _metadataExtensions = {
    '.txt',
    '.nfo',
    '.md5',
    '.sha1',
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.xml',
    '.dat',
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

  /// Visible for regression tests and diagnostics. Unlike 0.0.12, this also
  /// resolves ZIP contents locally when no accessible playlist entry exists.
  static Future<String?> launchIdForRomPath(String romPath) async {
    await _loadCache();
    final currentRoot = _normalizedRoot();
    if (!_sameRoot(_cacheRoot, currentRoot) && currentRoot != null) {
      await _rebuildLaunchIndex(currentRoot);
    }

    final indexed = _lookup(romPath);
    if (indexed != null) return indexed;
    if (path.extension(romPath).toLowerCase() == '.zip') {
      return _resolveZipLaunchId(romPath);
    }
    return path.basename(romPath);
  }

  /// Direct-launch path for the App Store distribution.
  ///
  /// TestFlight receives RetroArch's exact exported filename. App Store does
  /// not, so for an archive NeoStation reconstructs the same libretro form:
  /// `archive.zip#inner-rom.ext`.
  static Future<bool> launchGameByRomPath(String romPath) async {
    if (!ownsRomPath(romPath)) return false;
    try {
      if (!await File(romPath).exists()) return false;

      final launchId = await launchIdForRomPath(romPath);
      if (launchId == null || launchId.isEmpty) {
        _log.w(
          'RetroArch App Store: unable to resolve ${path.basename(romPath)}; '
          'suppressing Open In because this ROM belongs to the RetroArch library.',
        );
        // This is a terminal RetroArch-owned launch attempt. Returning false
        // would incorrectly send the ROM to iOS Open In / Share.
        return true;
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
      // The ROM is owned by the App Store backend. Never leak a failed
      // RetroArch handoff into the generic iOS share sheet.
      return true;
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
  /// Crucially, the direct-launch identifier preserves the full libretro
  /// archive notation. 0.0.12 incorrectly reduced it to only `game.ext`.
  static (String, String)? _mappingFromPlaylistPath(String value) {
    final normalized = value.replaceAll('\\', '/');
    final hash = normalized.indexOf('#');
    if (hash > 0 && hash < normalized.length - 1) {
      final container = normalized.substring(0, hash);
      final inner = normalized.substring(hash + 1).replaceFirst(RegExp(r'^/+'), '');
      final archiveName = path.basename(container);
      if (container.isEmpty || archiveName.isEmpty || inner.isEmpty) return null;
      return (container, '$archiveName#$inner');
    }

    final name = path.basename(normalized);
    if (name.isEmpty) return null;
    return (normalized, name);
  }

  /// Reconstructs RetroArch's archive content identifier directly from a ZIP.
  /// This removes the dependency on RetroArch's private playlists directory,
  /// which may sit outside the security-scoped folder selected by the user.
  static Future<String?> _resolveZipLaunchId(String romPath) async {
    try {
      final bytes = await File(romPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes, verify: false);
      final payloads = archive.files.where((entry) {
        if (!entry.isFile || entry.name.isEmpty) return false;
        final normalized = entry.name.replaceAll('\\', '/');
        if (normalized.startsWith('__MACOSX/')) return false;
        final ext = path.extension(normalized).toLowerCase();
        return !_metadataExtensions.contains(ext);
      }).toList();

      if (payloads.isEmpty) return null;

      final direct = payloads.where((entry) {
        final ext = path.extension(entry.name).toLowerCase();
        return _directRomExtensions.contains(ext);
      }).toList();

      ArchiveFile? selected;
      if (direct.length == 1) {
        selected = direct.single;
      } else if (direct.length > 1) {
        final archiveStem = path.basenameWithoutExtension(romPath).toLowerCase();
        for (final candidate in direct) {
          final candidateStem =
              path.basenameWithoutExtension(candidate.name).toLowerCase();
          if (candidateStem == archiveStem) {
            selected = candidate;
            break;
          }
        }
        // Disc sets commonly contain one cue/m3u plus track files. The cue or
        // m3u is the content RetroArch should load.
        selected ??= direct.cast<ArchiveFile?>().firstWhere(
              (entry) {
                if (entry == null) return false;
                final ext = path.extension(entry.name).toLowerCase();
                return ext == '.cue' || ext == '.m3u';
              },
              orElse: () => null,
            );
      } else if (payloads.length == 1) {
        // Covers valid one-ROM archives with an uncommon extension while still
        // refusing ambiguous multi-file arcade sets.
        selected = payloads.single;
      }

      if (selected == null) {
        _log.w(
          'RetroArch App Store: ZIP ${path.basename(romPath)} has '
          '${payloads.length} payload files and no unambiguous ROM entry.',
        );
        return null;
      }

      final inner = selected.name
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'^/+'), '');
      if (inner.isEmpty) return null;
      final launchId = '${path.basename(romPath)}#$inner';

      _put(_launchIds, romPath, launchId);
      _put(_launchIds, path.basename(romPath), launchId);
      _put(_launchIds, path.basenameWithoutExtension(romPath), launchId);
      await _persistCache();
      _log.i('RetroArch App Store: resolved ZIP launch id $launchId');
      return launchId;
    } catch (e) {
      _log.e('RetroArch App Store: failed inspecting ZIP $romPath: $e');
      return null;
    }
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
