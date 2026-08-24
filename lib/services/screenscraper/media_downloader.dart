import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:neostation/services/logger_service.dart';

import 'region_config.dart';
import 'rom_hasher.dart';
import 'media_resolver.dart';
import 'screenscraper_client.dart';

/// Media asset downloader for ScreenScraper.
///
/// ScreenScraper can legitimately return HTTP 200 with a small textual status
/// such as `NOMEDIA`, `CRCOK`, `MD5OK` or `SHA1OK`. Those responses must never
/// be written as PNG/MP4/PDF files. Every payload is therefore signature-checked
/// before it replaces an existing media file.
class ScreenscraperMediaDownloader {
  ScreenscraperMediaDownloader._();

  static final _log = LoggerService.instance;

  static Future<void> _removeCompetingImageVariants(String fullPath) async {
    final targetExt = path
        .extension(fullPath)
        .replaceFirst('.', '')
        .toLowerCase();
    if (!const {'png', 'jpg', 'jpeg', 'webp'}.contains(targetExt)) return;

    final base = path.withoutExtension(fullPath);
    for (final ext in const ['png', 'jpg', 'jpeg', 'webp']) {
      if (ext == targetExt) continue;
      final sibling = File('$base.$ext');
      try {
        if (await sibling.exists()) await sibling.delete();
      } catch (_) {
        // A stale sibling that cannot be removed must not abort a scrape.
      }
    }
  }

  static Future<({bool success, bool wasExisting})> _downloadMediaFileSmart(
    String url,
    String relativePath,
    String userDataDir, {
    required String mediaType,
    bool forceOverwrite = false,
    int? maxDailyRequests,
  }) async {
    final fullPath = path.join(userDataDir, relativePath);
    final file = File(fullPath);

    try {
      final existed = await file.exists();
      if (existed) {
        final validExisting = await isValidMediaFile(file, mediaType);
        if (validExisting && !forceOverwrite) {
          await _removeCompetingImageVariants(fullPath);
          return (success: true, wasExisting: true);
        }
        if (!validExisting) {
          try {
            await file.delete();
          } catch (_) {}
        }
      }

      final response = await ScreenscraperClient.httpGetWithRetry(
        Uri.parse(url),
        timeout: const Duration(seconds: 60),
        maxRetries: 2,
        maxDailyRequests: maxDailyRequests,
      );
      if (response.statusCode != 200) {
        _log.e('Error downloading media (${response.statusCode}): $url');
        return (success: false, wasExisting: false);
      }

      final contentType = response.headers['content-type'] ?? '';
      if (!isValidMediaPayload(
        response.bodyBytes,
        mediaType: mediaType,
        contentType: contentType,
      )) {
        _log.w(
          'Rejected invalid ScreenScraper $mediaType payload '
          '(${response.bodyBytes.length} bytes, $contentType): '
          '${_safeBodyPrefix(response.bodyBytes)}',
        );
        return (success: false, wasExisting: false);
      }

      await file.parent.create(recursive: true);
      final temp = File('$fullPath.part');
      try {
        if (await temp.exists()) await temp.delete();
        await temp.writeAsBytes(response.bodyBytes, flush: true);
        if (await file.exists()) await file.delete();
        await temp.rename(fullPath);
      } finally {
        if (await temp.exists()) {
          try {
            await temp.delete();
          } catch (_) {}
        }
      }

      await _removeCompetingImageVariants(fullPath);
      return (success: true, wasExisting: false);
    } catch (e) {
      _log.e('Error downloading media: $e');
      return (success: false, wasExisting: false);
    }
  }

  /// Returns whether an on-disk media file matches the expected media type.
  static Future<bool> isValidMediaFile(File file, String mediaType) async {
    try {
      if (!await file.exists()) return false;
      final bytes = await file.readAsBytes();
      return isValidMediaPayload(bytes, mediaType: mediaType);
    } catch (_) {
      return false;
    }
  }

  /// Signature validation shared by the normal downloader, game-id fallback
  /// and unit tests.
  @visibleForTesting
  static bool isValidMediaPayload(
    List<int> bytes, {
    required String mediaType,
    String contentType = '',
  }) {
    if (bytes.length < 4) return false;
    if (_isTextStatus(bytes)) return false;

    switch (mediaType) {
      case 'video':
        return _looksLikeMp4(bytes);
      case 'manuel':
        return bytes.length >= 5 &&
            bytes[0] == 0x25 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x44 &&
            bytes[3] == 0x46 &&
            bytes[4] == 0x2d;
      default:
        return _looksLikeImage(bytes);
    }
  }

  static bool _isTextStatus(List<int> bytes) {
    final prefix = _safeBodyPrefix(bytes).toUpperCase();
    return prefix.startsWith('NOMEDIA') ||
        prefix.startsWith('CRCOK') ||
        prefix.startsWith('MD5OK') ||
        prefix.startsWith('SHA1OK') ||
        prefix.startsWith('<!DOCTYPE') ||
        prefix.startsWith('<HTML') ||
        prefix.startsWith('{"ERROR"') ||
        prefix.startsWith('{"HEADER"');
  }

  static bool _looksLikeImage(List<int> bytes) {
    final isPng =
        bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a;
    if (isPng) return true;

    final isJpeg =
        bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    if (isJpeg) return true;

    final isGif =
        bytes.length >= 6 &&
        ascii
            .decode(bytes.sublist(0, 6), allowInvalid: true)
            .startsWith('GIF8');
    if (isGif) return true;

    return bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP';
  }

  static bool _looksLikeMp4(List<int> bytes) {
    if (bytes.length < 12) return false;
    final limit = bytes.length < 96 ? bytes.length - 4 : 92;
    for (var index = 4; index <= limit; index++) {
      if (bytes[index] == 0x66 &&
          bytes[index + 1] == 0x74 &&
          bytes[index + 2] == 0x79 &&
          bytes[index + 3] == 0x70) {
        return true;
      }
    }
    return false;
  }

  static String _safeBodyPrefix(List<int> bytes) {
    if (bytes.isEmpty) return '<empty>';
    final take = bytes.length > 48 ? 48 : bytes.length;
    return utf8
        .decode(bytes.sublist(0, take), allowMalformed: true)
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .trim();
  }

  static Future<Map<String, dynamic>> downloadGameMedia(
    String systemFolder,
    String romName,
    List<dynamic> medias,
    int maxThreads, {
    String? appSystemId,
    String? preferredLanguage,
    bool Function()? shouldCancel,
    Function(double progress)? onProgress,
    List<String>? allowedMediaTypes,
    bool forceOverwrite = false,
    int? maxDailyRequests,
  }) async {
    if (medias.isEmpty) {
      return {
        'success': true,
        'downloadedTypes': <String>[],
        'existingTypes': <String>[],
        'cancelled': false,
      };
    }

    final userDataDir = await ScreenscraperMediaResolver.getMediaDirectory();
    final regionPriority = await ScreenscraperRegionConfig.getRegionPriority();
    final mediaTypes =
        allowedMediaTypes ?? ['fanart', 'ss', 'video', 'wheel', 'box2D'];

    final downloadTasks = <Map<String, dynamic>>[];
    for (final mediaType in mediaTypes) {
      final bestMedia = ScreenscraperMediaResolver.selectBestMedia(
        medias,
        mediaType,
        preferredLanguage: preferredLanguage,
        regionPriority: regionPriority,
      );
      if (bestMedia == null) continue;

      final folderName = ScreenscraperMediaResolver.mapMediaTypeToFolder(
        mediaType,
      );
      final romBaseName = await ScreenscraperRomHasher.getCleanRomName(
        romName,
        appSystemId,
      );
      final rawFormat = bestMedia['format']?.toString().toLowerCase();
      final fileFormat = switch (mediaType) {
        'video' => 'mp4',
        'manuel' => 'pdf',
        _ => (rawFormat == null || rawFormat.isEmpty) ? 'png' : rawFormat,
      };
      downloadTasks.add({
        'url': bestMedia['url'].toString(),
        'relativePath': '$systemFolder/$folderName/$romBaseName.$fileFormat',
        'mediaType': mediaType,
      });
    }

    if (downloadTasks.isEmpty) {
      return {
        'success': true,
        'downloadedTypes': <String>[],
        'existingTypes': <String>[],
        'cancelled': false,
      };
    }

    final batches = <List<Map<String, dynamic>>>[];
    for (var i = 0; i < downloadTasks.length; i += maxThreads) {
      final end = (i + maxThreads < downloadTasks.length)
          ? i + maxThreads
          : downloadTasks.length;
      batches.add(downloadTasks.sublist(i, end));
    }

    final downloadedTypes = <String>[];
    final existingTypes = <String>[];
    var wasCancelled = false;
    var completedTasks = 0;

    for (final batch in batches) {
      if (shouldCancel != null && shouldCancel()) {
        wasCancelled = true;
        break;
      }

      final results = await Future.wait(
        batch.map((task) async {
          final outcome = await _downloadMediaFileSmart(
            task['url'] as String,
            task['relativePath'] as String,
            userDataDir,
            mediaType: task['mediaType'] as String,
            forceOverwrite: forceOverwrite,
            maxDailyRequests: maxDailyRequests,
          );
          return {
            'mediaType': task['mediaType'],
            'success': outcome.success,
            'wasExisting': outcome.wasExisting,
          };
        }),
      );

      for (final result in results) {
        if (result['success'] != true) continue;
        final mediaType = result['mediaType'] as String;
        if (result['wasExisting'] == true) {
          existingTypes.add(mediaType);
        } else {
          downloadedTypes.add(mediaType);
        }
      }

      completedTasks += batch.length;
      onProgress?.call(completedTasks / downloadTasks.length);
      if (batches.length > 1) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    final totalAvailable = downloadedTypes.length + existingTypes.length;
    return {
      'success': totalAvailable == downloadTasks.length && !wasCancelled,
      'downloadedTypes': downloadedTypes,
      'existingTypes': existingTypes,
      'cancelled': wasCancelled,
    };
  }
}
