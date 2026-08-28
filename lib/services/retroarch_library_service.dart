import 'dart:convert';
import 'dart:io';

import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/retroarch_appstore_service.dart';
import 'package:neostation/services/retroarch_distribution_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Stable facade used by the rest of NeoStation.
///
/// The two RetroArch distributions are intentionally isolated behind this
/// router. TestFlight never touches the App Store linked-folder state, and the
/// App Store path never reads or writes the TestFlight export cache.
class RetroArchLibraryService {
  RetroArchLibraryService._();

  static Future<bool> requestLibrarySync() async {
    final distribution = await RetroArchDistributionService.current();
    if (distribution == RetroArchDistribution.appStore) {
      return RetroArchAppStoreService.syncLinkedLibrary();
    }
    return _RetroArchTestFlightBackend.requestLibrarySync();
  }

  /// Incoming neostation://retroarch callbacks belong exclusively to
  /// TestFlight. Receiving one also reasserts TestFlight mode, which protects
  /// users who update from an older build with stale App Store preferences.
  static Future<bool> handleIncomingUri(Uri uri) async {
    if (uri.scheme == 'neostation' && uri.host == 'retroarch') {
      await RetroArchDistributionService.useTestFlight();
    }
    return _RetroArchTestFlightBackend.handleIncomingUri(uri);
  }

  static Future<void> loadCachedLibrary() =>
      _RetroArchTestFlightBackend.loadCachedLibrary();

  static bool get hasSyncedLibrary =>
      _RetroArchTestFlightBackend.hasSyncedLibrary;

  static bool hasGameForRomPath(String romPath) {
    // This synchronous helper is used only for launch-choice UI. App Store
    // ownership is filesystem-based and does not need the TestFlight cache.
    return RetroArchAppStoreService.ownsRomPath(romPath) ||
        _RetroArchTestFlightBackend.hasGameForRomPath(romPath);
  }

  static Future<bool> launchGameByRomPath(String romPath) async {
    final distribution = await RetroArchDistributionService.current();
    if (distribution == RetroArchDistribution.appStore) {
      return RetroArchAppStoreService.launchGameByRomPath(romPath);
    }
    return _RetroArchTestFlightBackend.launchGameByRomPath(romPath);
  }
}

/// Known-good TestFlight implementation restored from the 2026-08-23 backup.
/// Keep this backend free of every App Store concept.
class _RetroArchTestFlightBackend {
  _RetroArchTestFlightBackend._();

  static final _log = LoggerService.instance;
  static const String _callbackScheme = 'neostation';
  static const String _prefsKey = 'retroarch_testflight_library_cache_v1';
  static const String _legacyPrefsKey = 'retroarch_library_cache_v1';
  static Map<String, Map<String, dynamic>>? _cache;

  static Future<bool> requestLibrarySync() async {
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
    target[filename] = entry;
    target[path.basename(filename)] = entry;
    final hashIndex = filename.indexOf('#');
    if (hashIndex > 0) {
      final archivePart = filename.substring(0, hashIndex);
      target[path.basename(archivePart)] = entry;
      target[path.basenameWithoutExtension(archivePart)] = entry;
    }
    final stem = path.basenameWithoutExtension(filename);
    target.putIfAbsent(stem, () => entry);
  }

  static Future<void> loadCachedLibrary() async {
    if (_cache != null) return;
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

  static Future<void> _persist(Map<String, Map<String, dynamic>> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(data));
  }

  static bool get hasSyncedLibrary => (_cache?.isNotEmpty ?? false);

  static bool hasGameForRomPath(String romPath) {
    final cache = _cache;
    if (cache == null || cache.isEmpty) return false;
    final basename = path.basename(romPath);
    final stem = path.basenameWithoutExtension(romPath);
    return cache.containsKey(basename) ||
        cache.containsKey(romPath) ||
        cache.containsKey(stem);
  }

  static Future<bool> launchGameByRomPath(String romPath) async {
    final cache = _cache;
    if (cache == null || cache.isEmpty) return false;
    final basename = path.basename(romPath);
    final stem = path.basenameWithoutExtension(romPath);
    final entry = cache[basename] ?? cache[romPath] ?? cache[stem];
    if (entry == null) return false;

    final filename = (entry['filename'] ?? entry['titleId'])?.toString();
    if (filename == null || filename.isEmpty) return false;
    final uri = Uri(
      scheme: 'retroarch',
      host: 'game',
      pathSegments: [filename],
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
