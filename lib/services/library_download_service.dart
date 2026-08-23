import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:neostation/services/library_catalog_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class LibraryDownloadResult {
  const LibraryDownloadResult({
    required this.filePath,
    required this.fileName,
    required this.bytesWritten,
    required this.format,
  });

  final String filePath;
  final String fileName;
  final int bytesWritten;
  final String format;
}

/// Downloads only URLs that were explicitly supplied by a Library source.
///
/// The service never searches the web for alternate copies. A provider or
/// user-installed Library source must expose the HTTPS acquisition URL itself.
/// Files are stored in NeoStation's Files-visible Documents/Library/Downloads
/// directory so the user keeps control of the downloaded copy.
class LibraryDownloadService {
  LibraryDownloadService._();

  static const int maxDownloadBytes = 512 * 1024 * 1024;
  static const Duration _requestTimeout = Duration(seconds: 30);
  static const Duration _streamTimeout = Duration(seconds: 45);

  static Future<LibraryDownloadResult> download({
    required LibraryAcquisitionLink acquisition,
    required String title,
    void Function(double progress)? onProgress,
  }) async {
    if (!acquisition.canDownload) {
      throw const FormatException('This acquisition link is not downloadable.');
    }

    final uri = Uri.tryParse(acquisition.url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('Library downloads require an HTTPS URL.');
    }

    final docs = await getApplicationDocumentsDirectory();
    final downloads = Directory(path.join(docs.path, 'Library', 'Downloads'));
    await downloads.create(recursive: true);

    final fileName = await _availableFileName(
      downloads,
      suggestedFileName(title: title, acquisition: acquisition),
    );
    final destination = File(path.join(downloads.path, fileName));

    final client = http.Client();
    IOSink? sink;
    var bytesWritten = 0;
    try {
      final request = http.Request('GET', uri)
        ..headers['Accept'] = _acceptHeader(acquisition)
        ..headers['User-Agent'] = 'NeoStation-iOS/1.0';
      final response = await client.send(request).timeout(_requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Download failed with HTTP ${response.statusCode}.',
          uri: uri,
        );
      }

      final expected = response.contentLength;
      if (expected != null && expected > maxDownloadBytes) {
        throw const FileSystemException(
          'The Library download is larger than the 512 MB safety limit.',
        );
      }

      sink = destination.openWrite(mode: FileMode.writeOnly);
      await for (final chunk in response.stream.timeout(_streamTimeout)) {
        bytesWritten += chunk.length;
        if (bytesWritten > maxDownloadBytes) {
          throw const FileSystemException(
            'The Library download exceeded the 512 MB safety limit.',
          );
        }
        sink.add(chunk);
        if (expected != null && expected > 0 && onProgress != null) {
          onProgress((bytesWritten / expected).clamp(0.0, 1.0));
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (bytesWritten == 0) {
        throw const FileSystemException('The downloaded file is empty.');
      }
      onProgress?.call(1.0);

      return LibraryDownloadResult(
        filePath: destination.path,
        fileName: fileName,
        bytesWritten: bytesWritten,
        format: _normalizedFormat(acquisition),
      );
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await destination.exists()) await destination.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  @visibleForTesting
  static String suggestedFileName({
    required String title,
    required LibraryAcquisitionLink acquisition,
  }) {
    var safeTitle = title.trim().replaceAll(
      RegExp(r'[^A-Za-z0-9À-ÿ._ -]+'),
      '_',
    );
    safeTitle = safeTitle.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (safeTitle.isEmpty) safeTitle = 'Library item';
    if (safeTitle.length > 120) safeTitle = safeTitle.substring(0, 120).trim();

    final uri = Uri.tryParse(acquisition.url);
    var extension = uri == null ? '' : path.extension(uri.path).toLowerCase();
    if (extension.length > 10 ||
        !RegExp(r'^\.[a-z0-9]{1,9}$').hasMatch(extension)) {
      extension = '';
    }
    if (extension.isEmpty) {
      extension = switch (_normalizedFormat(acquisition)) {
        'epub' => '.epub',
        'pdf' => '.pdf',
        'cbz' => '.cbz',
        'cbr' => '.cbr',
        'txt' => '.txt',
        _ => '.bin',
      };
    }
    return '$safeTitle$extension';
  }

  static String _normalizedFormat(LibraryAcquisitionLink acquisition) {
    final explicit = acquisition.format.trim().toLowerCase().replaceAll(
      '.',
      '',
    );
    if (explicit.isNotEmpty) return explicit;
    final mime = acquisition.mimeType.toLowerCase();
    if (mime.contains('epub')) return 'epub';
    if (mime.contains('pdf')) return 'pdf';
    if (mime.contains('zip')) return 'cbz';
    final uri = Uri.tryParse(acquisition.url);
    final ext = uri == null
        ? ''
        : path.extension(uri.path).toLowerCase().replaceAll('.', '');
    return ext;
  }

  static String _acceptHeader(LibraryAcquisitionLink acquisition) {
    if (acquisition.mimeType.trim().isNotEmpty) {
      return '${acquisition.mimeType}, application/octet-stream;q=0.8';
    }
    return 'application/epub+zip, application/pdf, application/octet-stream;q=0.8';
  }

  static Future<String> _availableFileName(
    Directory directory,
    String requested,
  ) async {
    final extension = path.extension(requested);
    final stem = path.basenameWithoutExtension(requested);
    var candidate = requested;
    var index = 2;
    while (await File(path.join(directory.path, candidate)).exists()) {
      candidate = '$stem ($index)$extension';
      index++;
    }
    return candidate;
  }
}
