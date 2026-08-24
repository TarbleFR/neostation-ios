import 'dart:io';

import 'package:crypto/crypto.dart';
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

    final digest = await sha256.bind(file.openRead()).first;
    return persistentHash(digest.toString());
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
