import 'dart:convert';
import 'dart:io';

import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// RetroArch integration for iOS.
///
/// NeoStation now supports only the RetroArch TestFlight/beta integration.
/// The App Store distribution path, local playlist parsing and distribution
/// selector have been removed permanently. Library synchronization always uses
/// RetroArch's exported callback and game launches always use the exported
/// TestFlight filename/title identifier.
class RetroArchLibraryService {
  RetroArchLibraryService._();

  static final _log = LoggerService.instance;
  static const String _callbackScheme = 'neostation';
  static const String _prefsKey = 'retroarch_testflight_library_cache_v1';
  static const String _legacyPrefsKey = 'retroarch_library_cache_v1';

  static const List<String> _removedAppStorePreferenceKeys = <String>[
    'retroarch_ios_distribution_v1',
    'retroarch_appstore_launch_cache_v1',
    'retroarch_appstore_launch_cache_v2',
    'retroarch_appstore_launch_cache_v3',
    'retroarch_appstore_launch_root_v1',
    'retroarch_appstore_launch_root_v2',
    'retroarch_appstore_launch_root_v3',
    'retroarch_hard_split_offer_seen_v1',
  ];

  static Map<String, Map<String, dynamic>>? _cache;

  static Future<bool> requestLibrarySync() async {
    await _cleanupRemovedAppStoreState();
    try {
      return await launchUrl(
        Uri.parse('retroarch://library?scheme=$_callbackScheme'),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      _log.e('RetroArch TestFlight sync request failed: $e');
      return false;
    }
  }

  static Future<bool> handleIncomingUri(Uri uri) async {
    if (uri.scheme != _callbackScheme || uri.host != 'retroarch') return false;
    final gamesParam = uri.queryParameters['games'];
    if (gamesParam == null) return false;

    await _cleanupRemovedAppStoreState();

    try {
      final normalized = base64Url.normalize(gamesParam);
      final decoded = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      if (decoded is! List) return false;

      final byFilename = <String, Map<String, dynamic>>{};
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final entry = Map<String, dynamic>.from(raw);
        final filename = (entry['filename'] ?? entry['titleId'])?.toString();
        if (filename == null || filename.isEmpty) continue;
        _index(byFilename, filename, entry);

        // The playlist label normally matches the archive basename. Indexing
        // it as an alias makes ZIP launches resilient when RetroArch exports
        // the archive member (`game.32x`) while NeoStation stores `game.zip`.
        final titleName = entry['titleName']?.toString();
        if (titleName != null && titleName.trim().isNotEmpty) {
          _put(byFilename, titleName.trim(), entry);
          _put(byFilename, path.basenameWithoutExtension(titleName.trim()), entry);
        }
      }

      _cache = byFilename;
      await _persist(byFilename);
      await _writeDebugFile(
        'retroarch_testflight_sync_debug.txt',
        'Synced ${decoded.length} games.\n\n'
            '${const JsonEncoder.withIndent('  ').convert(decoded)}',
      );

      try {
        final context = rootNavigatorKey.currentContext;
        if (context != null) {
          await Provider.of<SqliteConfigProvider>(context, listen: false)
              .scanSystems();
        }
      } catch (e) {
        _log.e('RetroArch TestFlight post-sync rescan failed: $e');
      }
      return true;
    } catch (e) {
      _log.e('RetroArch TestFlight callback parse failed: $e');
      return false;
    }
  }

  static void _index(
    Map<String, Map<String, dynamic>> target,
    String filename,
    Map<String, dynamic> entry,
  ) {
    _put(target, filename, entry);
    _put(target, path.basename(filename), entry);

    final hashIndex = filename.indexOf('#');
    if (hashIndex > 0) {
      final archivePart = filename.substring(0, hashIndex);
      _put(target, path.basename(archivePart), entry);
      _put(target, path.basenameWithoutExtension(archivePart), entry);
    }

    _put(target, path.basenameWithoutExtension(filename), entry);
  }

  static void _put(
    Map<String, Map<String, dynamic>> target,
    String key,
    Map<String, dynamic> entry,
  ) {
    if (key.isEmpty) return;
    target.putIfAbsent(key, () => entry);
    target.putIfAbsent(key.toLowerCase(), () => entry);
  }

  static Future<void> loadCachedLibrary() async {
    if (_cache != null) return;
    await _cleanupRemovedAppStoreState();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey) ?? prefs.getString(_legacyPrefsKey);
      if (raw == null) {
        _cache = {};
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _cache = decoded.map(
          (key, value) => MapEntry(
            key.toString(),
            Map<String, dynamic>.from(value as Map),
          ),
        );
        await prefs.setString(_prefsKey, raw);
      } else {
        _cache = {};
      }
    } catch (e) {
      _log.e('RetroArch TestFlight cache load failed: $e');
      _cache = {};
    }
  }

  static bool get hasSyncedLibrary => (_cache?.isNotEmpty ?? false);

  static bool hasGameForRomPath(String romPath) {
    final cache = _cache;
    if (cache == null || cache.isEmpty) return false;
    return _entryForRomPath(cache, romPath) != null;
  }

  static Future<bool> launchGameByRomPath(String romPath) async {
    await _cleanupRemovedAppStoreState();
    final cache = _cache;
    if (cache == null || cache.isEmpty) return false;

    final entry = _entryForRomPath(cache, romPath);
    if (entry == null) return false;

    final filename = (entry['filename'] ?? entry['titleId'])?.toString();
    if (filename == null || filename.isEmpty) return false;

    final uri = Uri(
      scheme: 'retroarch',
      host: 'game',
      pathSegments: <String>[filename],
    );

    await _writeDebugFile(
      'retroarch_testflight_launch_debug.txt',
      'romPath: $romPath\nfilename: $filename\nuri: $uri',
    );

    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      _log.e('RetroArch TestFlight launch failed: $e');
      return false;
    }
  }

  static Map<String, dynamic>? _entryForRomPath(
    Map<String, Map<String, dynamic>> cache,
    String romPath,
  ) {
    final basename = path.basename(romPath);
    final stem = path.basenameWithoutExtension(romPath);
    return cache[romPath] ??
        cache[romPath.toLowerCase()] ??
        cache[basename] ??
        cache[basename.toLowerCase()] ??
        cache[stem] ??
        cache[stem.toLowerCase()];
  }

  static Future<void> _persist(Map<String, Map<String, dynamic>> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(data));
  }

  static Future<void> _cleanupRemovedAppStoreState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in _removedAppStorePreferenceKeys) {
        if (prefs.containsKey(key)) await prefs.remove(key);
      }
    } catch (e) {
      _log.w('RetroArch TestFlight legacy preference cleanup failed: $e');
    }

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final debugFile = File(
        path.join(docsDir.path, 'retroarch_appstore_launch_debug.txt'),
      );
      if (await debugFile.exists()) await debugFile.delete();
    } catch (_) {
      // Non-critical cleanup only.
    }
  }

  static Future<void> _writeDebugFile(String name, String content) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      await File(path.join(docsDir.path, name))
          .writeAsString('--- ${DateTime.now()} ---\n$content');
    } catch (e) {
      _log.e('RetroArch TestFlight debug write failed: $e');
    }
  }
}
