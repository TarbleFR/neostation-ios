import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

import 'logger_service.dart';

class ManicEmuLaunchService {
  ManicEmuLaunchService._();

  static const bookmarkKey = 'manicemu';
  static final _log = LoggerService.instance;

  static Future<bool> isInstalled() => canLaunchUrl(Uri.parse('manicemu://'));

  static Future<String?> gameIdForPath(String romPath) async {
    final file = File(romPath);
    if (!await file.exists()) return null;

    final digest = path.extension(romPath).toLowerCase() == '.zip'
        ? await _sha256OfLargestZipEntry(file)
        : await sha256.bind(file.openRead()).first;
    if (digest == null) return null;
    return persistentHash(digest.toString());
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
