import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/rpcs3_config_adapter.dart';
import 'package:path/path.dart' as path;

enum Rpcs3ProfileFamily {
  balanced,
  compatibility,
  gpuBound,
  shaderHeavy,
  spuHeavy,
}

@immutable
class Rpcs3GameDatabaseEntry {
  const Rpcs3GameDatabaseEntry({
    required this.serial,
    required this.config,
    required this.family,
  });

  final String serial;
  final String config;
  final Rpcs3ProfileFamily family;
}

/// Versioned RPCS3 recommendations with an offline seed and atomic refresh.
///
/// ARMSX3 proved that RPCS3's official configuration endpoint is useful on a
/// mobile port when desktop-only values are filtered. NeoStation keeps the
/// same source, adapts it for Vulkan/MoltenVK, and retains the last valid copy
/// so configuration never depends on connectivity at launch.
abstract final class Rpcs3GameProfileDatabase {
  static const String sourceUrl = 'https://api.rpcs3.net/config/?api=v1';
  static const String assetPath = 'assets/data/rpcs3_ios_profiles.json';
  static const String _cacheRelativePath =
      'cache/rpcs3/rpcs3_ios_profiles.json';
  static const Duration _cacheLifetime = Duration(days: 7);
  static const Duration _networkTimeout = Duration(seconds: 12);
  static const int _minimumCompleteDatabaseSize = 1000;

  static final LoggerService _log = LoggerService.instance;
  static Map<String, Rpcs3GameDatabaseEntry>? _entries;
  static DateTime? _diskModifiedAt;
  static bool _refreshAttemptedThisSession = false;

  static Future<Map<String, Rpcs3GameDatabaseEntry>> load({
    bool allowNetwork = false,
  }) async {
    await _ensureLoaded();
    if (allowNetwork) await refreshIfStale();
    return Map<String, Rpcs3GameDatabaseEntry>.unmodifiable(_entries!);
  }

  static Future<Rpcs3GameDatabaseEntry?> entryFor(
    String serial, {
    bool allowNetwork = false,
  }) async {
    final entries = await load(allowNetwork: allowNetwork);
    return entries[serial.trim().toUpperCase()];
  }

  static bool get _cacheIsFresh =>
      _diskModifiedAt != null &&
      DateTime.now().difference(_diskModifiedAt!) < _cacheLifetime;

  /// Refreshes the complete database. Invalid/truncated responses never
  /// replace the bundled or cached copy.
  static Future<bool> refresh() async {
    await _ensureLoaded();
    try {
      final response = await http
          .get(
            Uri.parse(sourceUrl),
            headers: const <String, String>{
              'Accept': 'application/json',
              'User-Agent': 'NeoStation-iOS/RPCS3-profile-engine',
            },
          )
          .timeout(_networkTimeout);
      if (response.statusCode != 200) {
        _log.w('RPCS3 GameDB: HTTP ${response.statusCode}; keeping cache.');
        return false;
      }

      final parsed = parseDatabaseForTesting(response.body);
      if (parsed.length < _minimumCompleteDatabaseSize) {
        _log.w(
          'RPCS3 GameDB: rejected unexpectedly small response '
          '(${parsed.length} profiles).',
        );
        return false;
      }

      final normalized = _encodeCache(parsed);
      final file = await _cacheFile();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.part');
      await temporary.writeAsString(normalized, flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
      _entries = parsed;
      _diskModifiedAt = DateTime.now();
      _log.i('RPCS3 GameDB: cached ${parsed.length} iOS-safe profiles.');
      return true;
    } catch (error) {
      _log.w('RPCS3 GameDB refresh failed; keeping offline profiles: $error');
      return false;
    }
  }

  static Future<bool> refreshIfStale() async {
    await _ensureLoaded();
    if (_refreshAttemptedThisSession || _cacheIsFresh) return false;
    _refreshAttemptedThisSession = true;
    return refresh();
  }

  static Future<void> _ensureLoaded() async {
    if (_entries != null) return;

    Map<String, Rpcs3GameDatabaseEntry>? selected;
    try {
      selected = parseDatabaseForTesting(await rootBundle.loadString(assetPath));
    } catch (error) {
      _log.w('RPCS3 GameDB bundled seed could not be loaded: $error');
    }

    try {
      final file = await _cacheFile();
      if (await file.exists()) {
        final cached = parseDatabaseForTesting(await file.readAsString());
        if (cached.length >= _minimumCompleteDatabaseSize) {
          selected = cached;
          _diskModifiedAt = (await file.stat()).modified;
        }
      }
    } catch (error) {
      _log.w('RPCS3 GameDB disk cache could not be loaded: $error');
    }

    _entries = selected ?? <String, Rpcs3GameDatabaseEntry>{};
  }

  static Future<File> _cacheFile() async {
    final userData = await ConfigService.getUserDataPath();
    return File(path.join(userData, _cacheRelativePath));
  }

  @visibleForTesting
  static Map<String, Rpcs3GameDatabaseEntry> parseDatabaseForTesting(
    String source,
  ) {
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded['return_code'] != 0) {
      throw const FormatException('RPCS3 GameDB is not a successful response.');
    }
    final games = decoded['games'];
    if (games is! Map) {
      throw const FormatException('RPCS3 GameDB has no game collection.');
    }

    final result = <String, Rpcs3GameDatabaseEntry>{};
    for (final item in games.entries) {
      final serial = item.key.toString().trim().toUpperCase();
      if (!RegExp(r'^[A-Z0-9]{9,16}$').hasMatch(serial)) continue;
      final record = item.value;
      if (record is! Map || record['config'] is! String) continue;
      final config = Rpcs3ConfigAdapter.sanitiseForIOS(
        record['config'] as String,
      );
      if (!Rpcs3ConfigAdapter.hasUsefulSetting(config)) continue;
      result[serial] = Rpcs3GameDatabaseEntry(
        serial: serial,
        config: config,
        family: _parseFamily(record['family']?.toString(), config),
      );
    }
    return result;
  }

  static Rpcs3ProfileFamily _parseFamily(String? value, String config) {
    return switch (value) {
      'compatibility' => Rpcs3ProfileFamily.compatibility,
      'gpu-bound' => Rpcs3ProfileFamily.gpuBound,
      'shader-heavy' => Rpcs3ProfileFamily.shaderHeavy,
      'spu-heavy' => Rpcs3ProfileFamily.spuHeavy,
      'balanced' => Rpcs3ProfileFamily.balanced,
      _ => _classify(config),
    };
  }

  static Rpcs3ProfileFamily _classify(String config) {
    const compatibility = <String>[
      'Strict Rendering Mode',
      'Write Color Buffers',
      'Read Color Buffers',
      'Accurate RSX reservation access',
      'RSX FIFO Fetch Accuracy',
      'Driver Wake-Up Delay',
      'Accurate Cache Line Stores',
    ];
    const shader = <String>[
      'Shader Precision',
      'Disable Vertex Cache',
      'Asynchronous Texture Streaming',
    ];
    const spu = <String>[
      'SPU Block Size',
      'SPU XFloat Accuracy',
      'Max SPURS Threads',
      'Preferred SPU Threads',
    ];
    if (compatibility.any(config.contains)) {
      return Rpcs3ProfileFamily.compatibility;
    }
    if (shader.where(config.contains).length >= 2) {
      return Rpcs3ProfileFamily.shaderHeavy;
    }
    if (spu.any(config.contains)) return Rpcs3ProfileFamily.spuHeavy;
    if (config.contains('Multithreaded RSX') || config.contains('ZCULL')) {
      return Rpcs3ProfileFamily.gpuBound;
    }
    return Rpcs3ProfileFamily.balanced;
  }

  static String _encodeCache(Map<String, Rpcs3GameDatabaseEntry> entries) {
    return jsonEncode(<String, dynamic>{
      'schema': 1,
      'return_code': 0,
      'source_url': sourceUrl,
      'games': <String, dynamic>{
        for (final item in entries.entries)
          item.key: <String, String>{
            'config': item.value.config,
            'family': switch (item.value.family) {
              Rpcs3ProfileFamily.compatibility => 'compatibility',
              Rpcs3ProfileFamily.gpuBound => 'gpu-bound',
              Rpcs3ProfileFamily.shaderHeavy => 'shader-heavy',
              Rpcs3ProfileFamily.spuHeavy => 'spu-heavy',
              Rpcs3ProfileFamily.balanced => 'balanced',
            },
          },
      },
    });
  }
}
