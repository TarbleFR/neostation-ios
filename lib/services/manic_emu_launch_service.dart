import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:external_folder_access/external_folder_access.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'logger_service.dart';

class ManicEmuLaunchService {
  ManicEmuLaunchService._();

  static const bookmarkKey = 'manicemu';
  static const _cacheKey = 'manic_emu_game_id_cache_v1';
  static final _log = LoggerService.instance;
  static Map<String, Map<String, String>>? _idCache;

  static Future<bool> isInstalled() => canLaunchUrl(Uri.parse('manicemu://'));

  static Future<String?> gameIdForPath(String romPath) async {
    final file = File(romPath);
    if (!await file.exists()) return null;

    final stat = await file.stat();
    final fingerprint = '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
    final normalizedPath = path.normalize(romPath);
    final cache = await _loadCache();
    final cached = cache[normalizedPath];
    if (cached?['fingerprint'] == fingerprint) return cached?['gameId'];

    String? digestValue;
    if (path.extension(romPath).toLowerCase() == '.zip') {
      digestValue = (await _sha256OfLargestZipEntry(file))?.toString();
    } else {
      digestValue = await ExternalFolderAccess.sha256File(romPath);
      digestValue ??= (await sha256.bind(file.openRead()).first).toString();
    }
    if (digestValue == null) return null;

    final gameId = persistentHash(digestValue);
    cache[normalizedPath] = {
      'fingerprint': fingerprint,
      'gameId': gameId,
    };
    await _persistCache(cache);
    return gameId;
  }

  /// Prepares identifiers during the library scan so tapping a large 3DS game
  /// can immediately hand it to Manic EMU instead of hashing it at launch.
  static Future<void> prepareGameIds(Iterable<String> romPaths) async {
    for (final romPath in romPaths.toSet()) {
      try {
        await gameIdForPath(romPath);
      } catch (e) {
        _log.e('Unable to prepare Manic EMU ID for $romPath: $e');
      }
    }
  }

  static Future<Map<String, Map<String, String>>> _loadCache() async {
    if (_idCache != null) return _idCache!;
    final result = <String, Map<String, String>>{};
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_cacheKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.value is Map) {
              result[entry.key.toString()] = Map<String, String>.from(
                entry.value as Map,
              );
            }
          }
        }
      }
    } catch (e) {
      _log.e('Unable to load Manic EMU launch cache: $e');
    }
    _idCache = result;
    return result;
  }

  static Future<void> _persistCache(
    Map<String, Map<String, String>> cache,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(cache));
    } catch (e) {
      _log.e('Unable to persist Manic EMU launch cache: $e');
    }
  }

  /// Manic EMU extracts ZIP archives before importing games and builds the
  /// library identifier from the extracted ROM, not from the ZIP container.
  static Future<Digest?> _sha256OfLargestZipEntry(File zipFile) async {
    try {
      final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
      ArchiveFile? romEntry;
      for (final entry in archive) {
        if (!entry.isFile || entry.name.split('/').last.startsWith('.')) {
          continue;
        }
        if (romEntry == null || entry.size > romEntry.size) romEntry = entry;
      }
      if (romEntry == null) return null;
      return sha256.convert(romEntry.content as List<int>);
    } catch (e) {
      _log.e('Unable to calculate Manic EMU ID from ZIP: $e');
      return null;
    }
  }

  /// Matches Manic EMU's persistent djb2 hash of the ROM's SHA-256 string.
  static String persistentHash(String value) {
    var hash = 5381;
    for (final byte in value.codeUnits) {
      hash = (hash * 33 + byte).toSigned(64);
    }
    return hash.abs().toString();
  }

  static Future<bool> launchGame(String romPath) async {
    try {
      final gameId = await gameIdForPath(romPath);
      if (gameId == null) return false;
      final reportedOpened = await launchUrl(
        Uri(scheme: 'manicemu', host: 'launch', pathSegments: [gameId]),
        mode: LaunchMode.externalApplication,
      );
      if (!reportedOpened) {
        _log.w('Manic EMU handoff was dispatched but reported false.');
      }
      return true;
    } catch (e) {
      _log.e('Manic EMU launch failed: $e');
      return false;
    }
  }
}
