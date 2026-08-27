import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
  static const _hashTimeout = Duration(minutes: 2);
  static const _handoffTimeout = Duration(seconds: 10);
  static final _log = LoggerService.instance;
  static Map<String, Map<String, String>>? _idCache;
  static final Map<String, Future<String?>> _pendingGameIds = {};

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

    final jobKey = '$normalizedPath::$fingerprint';
    final computation = _pendingGameIds.putIfAbsent(
      jobKey,
      () => _startGameIdComputation(
        jobKey: jobKey,
        file: file,
        romPath: romPath,
        normalizedPath: normalizedPath,
        fingerprint: fingerprint,
        cache: cache,
        fileSize: stat.size,
      ),
    );

    try {
      return await computation.timeout(_hashTimeout);
    } on TimeoutException {
      _log.e(
        'Manic EMU identifier preparation timed out after '
        '${_hashTimeout.inSeconds} seconds.',
      );
      return null;
    }
  }

  /// Deduplicates identifier work for the same immutable file fingerprint.
  /// If a UI timeout is reached, the single native stream may finish and fill
  /// the cache in the background; another tap reuses it instead of starting a
  /// second multi-gigabyte read.
  static Future<String?> _startGameIdComputation({
    required String jobKey,
    required File file,
    required String romPath,
    required String normalizedPath,
    required String fingerprint,
    required Map<String, Map<String, String>> cache,
    required int fileSize,
  }) {
    late final Future<String?> computation;
    computation = _computeAndCacheGameId(
      file: file,
      romPath: romPath,
      normalizedPath: normalizedPath,
      fingerprint: fingerprint,
      cache: cache,
      fileSize: fileSize,
    );
    computation.whenComplete(() {
      if (identical(_pendingGameIds[jobKey], computation)) {
        _pendingGameIds.remove(jobKey);
      }
    }).ignore();
    return computation;
  }

  static Future<String?> _computeAndCacheGameId({
    required File file,
    required String romPath,
    required String normalizedPath,
    required String fingerprint,
    required Map<String, Map<String, String>> cache,
    required int fileSize,
  }) async {
    _log.i(
      'Preparing Manic EMU identifier '
      '(extension=${path.extension(romPath)}, bytes=$fileSize).',
    );

    String? digestValue;
    if (path.extension(romPath).toLowerCase() == '.zip') {
      // Manic extracts ZIP imports before hashing the contained ROM. Keep
      // matching that established behavior (validated by the ZIP launch
      // regression test) while ordinary large ROMs use the native streamer.
      digestValue = await _sha256OfLargestZipEntry(file);
    } else if (Platform.isIOS) {
      digestValue = await ExternalFolderAccess.sha256File(romPath);
    } else {
      digestValue = await _sha256FileInBackground(romPath);
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
  static Future<String> _sha256FileInBackground(String filePath) {
    return Isolate.run(() async {
      return (await sha256.bind(File(filePath).openRead()).first).toString();
    });
  }

  /// Streams the largest ROM from the ZIP straight into SHA-256 in a worker
  /// isolate. The previous implementation read both the complete archive and
  /// its extracted multi-gigabyte ROM into RAM, allowing iOS to terminate
  /// NeoStation during the launch overlay.
  static Future<String?> _sha256OfLargestZipEntry(File zipFile) async {
    try {
      final zipPath = zipFile.path;
      return await Isolate.run(() {
        final input = InputFileStream(zipPath);
        Archive? archive;

        try {
          archive = ZipDecoder().decodeStream(input);
          ArchiveFile? romEntry;
          for (final entry in archive) {
            if (!entry.isFile ||
                path.basename(entry.name).startsWith('.')) {
              continue;
            }
            if (romEntry == null || entry.size > romEntry.size) {
              romEntry = entry;
            }
          }
          if (romEntry == null) return null;

          final rawContent = romEntry.rawContent?.getStream(
            decompress: false,
          );
          if (rawContent == null) return null;

          final collector = _DigestCollector();
          final hashSink = sha256.startChunkedConversion(collector);
          late final Sink<List<int>> archiveSink;
          if (romEntry.compression == CompressionType.deflate) {
            archiveSink = ZLibCodec(
              raw: true,
            ).decoder.startChunkedConversion(hashSink);
          } else if (romEntry.compression == null ||
              romEntry.compression == CompressionType.none) {
            archiveSink = hashSink;
          } else {
            // BZip2-compressed ZIP entries are exceptionally rare for ROMs.
            // Refuse them safely instead of falling back to an unbounded
            // in-memory decompression.
            return null;
          }

          try {
            const chunkSize = 1024 * 1024;
            while (!rawContent.isEOS) {
              final nextSize = rawContent.length < chunkSize
                  ? rawContent.length
                  : chunkSize;
              if (nextSize <= 0) break;
              archiveSink.add(
                rawContent.readBytes(nextSize).toUint8List(),
              );
            }
          } finally {
            archiveSink.close();
          }
          return collector.value?.toString();
        } finally {
          archive?.clearSync();
          input.closeSync();
        }
      });
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
      final rawUrl = 'manicemu://launch/$gameId';
      final opened = Platform.isIOS
          ? await ExternalFolderAccess.openRawUrl(
                  rawUrl,
                ).timeout(_handoffTimeout, onTimeout: () => false) ??
                false
          : await launchUrl(
              Uri.parse(rawUrl),
              mode: LaunchMode.externalApplication,
            ).timeout(_handoffTimeout, onTimeout: () => false);
      _log.i('Manic EMU handoff result: opened=$opened, gameId=$gameId.');
      return opened;
    } catch (e) {
      _log.e('Manic EMU launch failed: $e');
      return false;
    }
  }
}

class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
