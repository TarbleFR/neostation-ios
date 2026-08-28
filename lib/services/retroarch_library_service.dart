import 'dart:convert';
import 'dart:io';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/logger_service.dart';

/// RetroArch TestFlight integration only.
///
/// TestFlight protocol:
///   retroarch://library?scheme=neostation
///   -> neostation://retroarch?games=<base64url>
///   -> retroarch://game/<filename>
///
/// App Store integration deliberately lives in RetroArchAppStoreService so
/// changing App Store support can never alter this known-good TestFlight path.
class RetroArchLibraryService {
  RetroArchLibraryService._();

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
    if (gamesParam == null) {
      _log.w('RetroArch TestFlight callback with no games parameter');
      return false;
    }

    try {
      final normalized = base64Url.normalize(gamesParam);
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(normalized)),
      );
      if (decoded is! List) return false;

      final byFilename = <String, Map<String, dynamic>>{};
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry);
        final filename = (map['filename'] ?? map['titleId'])?.toString();
        if (filename == null || filename.isEmpty) continue;
        _index(byFilename, filename, map);
      }

      _cache = byFilename;
      await _persist(byFilename);
      await _writeDebugFile(
        'retroarch_testflight_sync_debug.txt',
        'Synced ${decoded.length} games.\n\n'
            '${const JsonEncoder.withIndent('  ').convert(decoded)}',
      );

      // Preserve the exact known-good backup behavior: after a TestFlight
      // callback, rescan the ordinary NeoStation ROM folders. No App Store
      // cache, folder association or local index participates here.
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
      // Migrate the old pre-App-Store cache once, because that cache came from
      // the original TestFlight-only implementation.
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
      final file = File(path.join(docsDir.path, name));
      await file.writeAsString('--- ${DateTime.now()} ---\n$content');
    } catch (e) {
      _log.e('RetroArch TestFlight debug write failed: $e');
    }
  }
}
