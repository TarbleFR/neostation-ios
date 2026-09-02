import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:path/path.dart' as path;

/// Resolves PlayStation 3 serial numbers to human-readable game titles.
///
/// The primary source is GameDB-PS3's GPL-3.0 `PS3.titles.json` release asset.
/// A downloaded copy is cached in NeoStation's user-data directory for thirty
/// days and remains usable offline. A tiny built-in seed covers titles used by
/// the RPCS3 integration diagnostics before the first successful download.
abstract final class Rpcs3TitleCatalogService {
  static const String sourceUrl =
      'https://github.com/niemasd/GameDB-PS3/releases/latest/download/PS3.titles.json';
  static const Duration _cacheLifetime = Duration(days: 30);
  static const Duration _networkTimeout = Duration(seconds: 12);
  static const String _cacheRelativePath = 'cache/rpcs3/PS3.titles.json';

  static const Map<String, String> _seedTitles = <String, String>{
    'BLES00412': 'The Lord of the Rings: Conquest',
    'BLES01484': 'Two Worlds II: Game of the Year Edition',
  };

  static final _log = LoggerService.instance;
  static Map<String, String>? _memoryCache;
  static bool _networkAttemptedThisSession = false;
  static DateTime? _diskCacheModifiedAt;

  static String normalizeTitleId(String value) {
    return value.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  @visibleForTesting
  static Map<String, String> parseCatalogForTesting(String source) {
    return _parseCatalog(source);
  }

  static String? resolveFromCatalog(
    String titleId,
    Map<String, String> catalog,
  ) {
    final normalized = normalizeTitleId(titleId);
    final title = catalog[normalized]?.trim();
    return title == null || title.isEmpty ? null : title;
  }

  @visibleForTesting
  static String? resolveFromCatalogForTesting(
    String titleId,
    Map<String, String> catalog,
  ) => resolveFromCatalog(titleId, catalog);

  static Future<Map<String, String>> loadTitles({
    bool allowNetwork = true,
  }) async {
    await _ensureDiskCacheLoaded();

    final cacheIsFresh =
        _diskCacheModifiedAt != null &&
        DateTime.now().difference(_diskCacheModifiedAt!) < _cacheLifetime;
    if (allowNetwork &&
        !_networkAttemptedThisSession &&
        (!cacheIsFresh || (_memoryCache?.length ?? 0) <= _seedTitles.length)) {
      _networkAttemptedThisSession = true;
      await _refreshFromNetwork();
    }

    return Map<String, String>.unmodifiable(
      _memoryCache ?? Map<String, String>.from(_seedTitles),
    );
  }

  static Future<String?> resolveTitle(
    String titleId, {
    bool allowNetwork = true,
  }) async {
    final catalog = await loadTitles(allowNetwork: allowNetwork);
    return resolveFromCatalog(titleId, catalog);
  }

  static Future<void> _ensureDiskCacheLoaded() async {
    if (_memoryCache != null) return;

    final titles = Map<String, String>.from(_seedTitles);
    try {
      final file = await _cacheFile();
      if (await file.exists()) {
        final parsed = _parseCatalog(await file.readAsString());
        titles.addAll(parsed);
        _diskCacheModifiedAt = (await file.stat()).modified;
      }
    } catch (error) {
      _log.w('RPCS3 title catalog: could not read disk cache: $error');
    }
    _memoryCache = titles;
  }

  static Future<void> _refreshFromNetwork() async {
    try {
      final response = await http
          .get(
            Uri.parse(sourceUrl),
            headers: const {
              'Accept': 'application/json',
              'User-Agent': 'NeoStation-iOS/RPCS3-title-catalog',
            },
          )
          .timeout(_networkTimeout);
      if (response.statusCode != 200) {
        _log.w(
          'RPCS3 title catalog: HTTP ${response.statusCode}; keeping cache.',
        );
        return;
      }

      final parsed = _parseCatalog(response.body);
      // A complete PS3 title catalog contains thousands of records. Reject a
      // truncated/error document before it can replace a useful stale cache.
      if (parsed.length < 1000) {
        _log.w(
          'RPCS3 title catalog: rejected unexpectedly small catalog '
          '(${parsed.length} entries).',
        );
        return;
      }

      final file = await _cacheFile();
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.part');
      await temp.writeAsString(response.body, flush: true);
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);

      _memoryCache = <String, String>{..._seedTitles, ...parsed};
      _diskCacheModifiedAt = DateTime.now();
      _log.i(
        'RPCS3 title catalog: cached ${parsed.length} serial/title records.',
      );
    } catch (error) {
      _log.w('RPCS3 title catalog: network refresh failed: $error');
    }
  }

  static Future<File> _cacheFile() async {
    final userData = await ConfigService.getUserDataPath();
    return File(path.join(userData, _cacheRelativePath));
  }

  static Map<String, String> _parseCatalog(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('PS3 title catalog is not a JSON object.');
    }

    final result = <String, String>{};
    for (final entry in decoded.entries) {
      final titleId = normalizeTitleId(entry.key.toString());
      final title = entry.value?.toString().trim() ?? '';
      if (titleId.isEmpty || title.isEmpty) continue;
      result[titleId] = title;
    }
    return result;
  }
}
