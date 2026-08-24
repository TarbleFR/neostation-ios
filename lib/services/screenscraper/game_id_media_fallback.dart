import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../logger_service.dart';
import 'media_downloader.dart';
import 'media_resolver.dart';
import 'rom_hasher.dart';
import 'screenscraper_client.dart';

/// Targeted ScreenScraper media fallback for URI-backed emulator libraries.
///
/// Once `jeuInfos.php` identifies a title, this helper uses the authoritative
/// ScreenScraper game id with `mediaJeu.php` / `mediaVideoJeu.php`. This avoids
/// relying solely on embedded media URLs and rejects textual HTTP-200 statuses.
class ScreenscraperGameIdMediaFallback {
  ScreenscraperGameIdMediaFallback._();

  static final _log = LoggerService.instance;
  static const String _baseUrl = 'https://api.screenscraper.fr/api2';
  static const Set<String> _supportedTypes = {
    'fanart',
    'ss',
    'wheel',
    'box2D',
    'video',
  };

  static Future<Map<String, dynamic>> ensureMediaByGameId({
    required String gameId,
    required String systemId,
    required String systemFolder,
    required String romName,
    required String appSystemId,
    required String devId,
    required String devPassword,
    required String softname,
    required String username,
    required String password,
    required List<String> allowedMediaTypes,
    required List<String> alreadyDownloadedTypes,
    required List<dynamic> sourceMedias,
    required String debugFileName,
    int? maxDailyRequests,
  }) async {
    final successful = <String>{...alreadyDownloadedTypes};
    final attempted = <String>[];
    final failures = <String>[];
    final requestedTypes = allowedMediaTypes
        .where(_supportedTypes.contains)
        .toList(growable: false);

    final sourceRegionsByType = <String, List<String>>{};
    for (final raw in sourceMedias) {
      if (raw is! Map) continue;
      final type = raw['type']?.toString() ?? '';
      final region = raw['region']?.toString() ?? '';
      if (type.isEmpty || region.isEmpty) continue;
      sourceRegionsByType.putIfAbsent(type, () => <String>[]);
      if (!sourceRegionsByType[type]!.contains(region)) {
        sourceRegionsByType[type]!.add(region);
      }
    }

    final mediaRoot = await ScreenscraperMediaResolver.getMediaDirectory();
    final mediaKey = await ScreenscraperRomHasher.getCleanRomName(
      romName,
      appSystemId,
    );

    await _writeDebug(
      debugFileName,
      'STATE: START\n'
      'Game ID: $gameId\n'
      'System ID: $systemId\n'
      'ROM key: $romName\n'
      'Media key: $mediaKey\n'
      'Requested media: ${requestedTypes.join(', ')}\n'
      'Normal downloader succeeded: ${alreadyDownloadedTypes.join(', ')}\n',
    );

    for (final mediaType in requestedTypes) {
      final folder = ScreenscraperMediaResolver.mapMediaTypeToFolder(mediaType);
      final extension = mediaType == 'video' ? 'mp4' : 'png';
      final target = File(
        path.join(mediaRoot, systemFolder, folder, '$mediaKey.$extension'),
      );
      await target.parent.create(recursive: true);

      final validExisting = await _findValidLocalMedia(
        mediaRoot,
        systemFolder,
        folder,
        mediaKey,
        mediaType,
      );
      if (successful.contains(mediaType) && validExisting != null) {
        await _appendDebug(
          debugFileName,
          '\nSKIP $mediaType: valid media already present '
          '(${validExisting.path}).\n',
        );
        continue;
      }
      if (mediaType == 'video' && validExisting != null) {
        successful.add(mediaType);
        await _appendDebug(
          debugFileName,
          '\nSKIP video: existing MP4 is valid (${validExisting.path}).\n',
        );
        continue;
      }

      successful.remove(mediaType);
      await _deleteInvalidLocalMedia(
        mediaRoot,
        systemFolder,
        folder,
        mediaKey,
        mediaType,
      );

      var downloaded = false;
      for (final token in _candidateMediaTokens(
        mediaType,
        sourceRegionsByType,
      )) {
        attempted.add('$mediaType:$token');
        final isVideo = mediaType == 'video';
        final query = <String, String>{
          'devid': devId,
          'devpassword': devPassword,
          'softname': softname,
          'ssid': username,
          'sspassword': password,
          'crc': '',
          'md5': '',
          'sha1': '',
          'systemeid': systemId,
          'jeuid': gameId,
          'media': token,
          if (isVideo) 'mediaformat': 'mp4' else 'outputformat': 'png',
        };
        final endpoint = isVideo ? 'mediaVideoJeu.php' : 'mediaJeu.php';
        final uri = Uri.parse('$_baseUrl/$endpoint')
            .replace(queryParameters: query);

        try {
          final response = await ScreenscraperClient.httpGetWithRetry(
            uri,
            timeout: const Duration(seconds: 60),
            maxRetries: 1,
            maxDailyRequests: maxDailyRequests,
          );
          final contentType = response.headers['content-type'] ?? '';
          final valid =
              response.statusCode == 200 &&
              ScreenscraperMediaDownloader.isValidMediaPayload(
                response.bodyBytes,
                mediaType: mediaType,
                contentType: contentType,
              );
          await _appendDebug(
            debugFileName,
            '\nTRY $mediaType -> $endpoint/$token\n'
            'HTTP: ${response.statusCode}\n'
            'Content-Type: $contentType\n'
            'Bytes: ${response.bodyBytes.length}\n'
            'Valid payload: $valid\n',
          );
          if (!valid) continue;

          final temp = File('${target.path}.part');
          if (await temp.exists()) await temp.delete();
          await temp.writeAsBytes(response.bodyBytes, flush: true);
          if (await target.exists()) await target.delete();
          await temp.rename(target.path);
          if (!isVideo) {
            await _removeCompetingImageVariants(target.path);
          }
          successful.add(mediaType);
          downloaded = true;
          await _appendDebug(debugFileName, 'Saved: ${target.path}\n');
          break;
        } catch (e) {
          failures.add('$mediaType/$token: $e');
          await _appendDebug(
            debugFileName,
            '\nERROR $mediaType -> $token: $e\n',
          );
        }
      }

      if (!downloaded && !successful.contains(mediaType)) {
        failures.add('$mediaType: no valid ScreenScraper media found');
        await _appendDebug(
          debugFileName,
          '\nFAILED $mediaType: no candidate returned valid media.\n',
        );
      }
    }

    await _appendDebug(
      debugFileName,
      '\nSTATE: DONE\n'
      'Successful types: ${successful.toList()..sort()}\n'
      'Attempts: ${attempted.length}\n'
      'Failures: ${failures.length}\n',
    );
    return {
      'successfulTypes': successful.toList(),
      'attempted': attempted,
      'failures': failures,
    };
  }

  static List<String> _candidateMediaTokens(
    String mediaType,
    Map<String, List<String>> sourceRegionsByType,
  ) {
    if (mediaType == 'video') return const ['video'];

    final regions = <String>[];
    void addRegion(String value) {
      final normalized = value.trim();
      if (normalized.isEmpty || regions.contains(normalized)) return;
      regions.add(normalized);
    }

    final relevantSourceTypes = switch (mediaType) {
      'wheel' => ['wheel-hd', 'wheel'],
      'ss' => ['ss-hd', 'ss'],
      'box2D' => ['box-2D'],
      'fanart' => ['fanart'],
      _ => [mediaType],
    };
    for (final sourceType in relevantSourceTypes) {
      for (final region
          in sourceRegionsByType[sourceType] ?? const <String>[]) {
        addRegion(region);
      }
    }
    for (final region in const ['wor', 'us', 'eu', 'jp', 'cus']) {
      addRegion(region);
    }

    return switch (mediaType) {
      'fanart' => ['fanart', ...regions.map((r) => 'fanart($r)')],
      'ss' => [
        ...regions.map((r) => 'ss-hd($r)'),
        ...regions.map((r) => 'ss($r)'),
        'ss',
      ],
      'wheel' => [
        ...regions.map((r) => 'wheel-hd($r)'),
        ...regions.map((r) => 'wheel($r)'),
        'wheel-hd',
        'wheel',
      ],
      'box2D' => [...regions.map((r) => 'box-2D($r)'), 'box-2D'],
      _ => [mediaType],
    };
  }

  static Future<File?> _findValidLocalMedia(
    String mediaRoot,
    String systemFolder,
    String folder,
    String mediaKey,
    String mediaType,
  ) async {
    final extensions = mediaType == 'video'
        ? const ['mp4']
        : const ['png', 'jpg', 'jpeg', 'webp'];
    for (final extension in extensions) {
      final file = File(
        path.join(mediaRoot, systemFolder, folder, '$mediaKey.$extension'),
      );
      if (await ScreenscraperMediaDownloader.isValidMediaFile(
        file,
        mediaType,
      )) {
        return file;
      }
    }
    return null;
  }

  static Future<void> _deleteInvalidLocalMedia(
    String mediaRoot,
    String systemFolder,
    String folder,
    String mediaKey,
    String mediaType,
  ) async {
    final extensions = mediaType == 'video'
        ? const ['mp4']
        : const ['png', 'jpg', 'jpeg', 'webp'];
    for (final extension in extensions) {
      final file = File(
        path.join(mediaRoot, systemFolder, folder, '$mediaKey.$extension'),
      );
      if (!await file.exists()) continue;
      if (await ScreenscraperMediaDownloader.isValidMediaFile(
        file,
        mediaType,
      )) {
        continue;
      }
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  static Future<void> _removeCompetingImageVariants(String targetPath) async {
    final base = path.withoutExtension(targetPath);
    final targetExtension = path.extension(targetPath).toLowerCase();
    for (final extension in const ['.png', '.jpg', '.jpeg', '.webp']) {
      if (extension == targetExtension) continue;
      final sibling = File('$base$extension');
      try {
        if (await sibling.exists()) await sibling.delete();
      } catch (_) {}
    }
  }

  static Future<void> _writeDebug(String fileName, String content) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      await File(path.join(docs.path, fileName))
          .writeAsString('--- ${DateTime.now()} ---\n$content');
    } catch (e) {
      _log.e('Game-id media fallback: failed writing debug file: $e');
    }
  }

  static Future<void> _appendDebug(String fileName, String content) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      await File(path.join(docs.path, fileName))
          .writeAsString(content, mode: FileMode.append);
    } catch (e) {
      _log.e('Game-id media fallback: failed appending debug file: $e');
    }
  }
}
