import 'dart:io';

import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// RetroArch App Store integration only.
///
/// This service never reads or writes the TestFlight export cache and never
/// requests retroarch://library. Its library is the ordinary NeoStation scan of
/// the security-scoped folder selected for the App Store installation.
class RetroArchAppStoreService {
  RetroArchAppStoreService._();

  static final _log = LoggerService.instance;

  static bool ownsRomPath(String romPath) {
    final root = ConfigService.linkedExternalFolderPath;
    if (root == null || root.trim().isEmpty || romPath.trim().isEmpty) {
      return false;
    }
    try {
      return path.equals(root, romPath) || path.isWithin(root, romPath);
    } catch (_) {
      return false;
    }
  }

  /// App Store sync is intentionally local. No TestFlight callback is involved.
  static Future<bool> syncLinkedLibrary() async {
    final root = ConfigService.linkedExternalFolderPath;
    if (root == null || root.trim().isEmpty) return false;
    try {
      final directory = Directory(root);
      if (!await directory.exists()) return false;
      final context = rootNavigatorKey.currentContext;
      if (context != null) {
        await Provider.of<SqliteConfigProvider>(context, listen: false)
            .scanSystems();
      }
      return true;
    } catch (e) {
      _log.e('RetroArch App Store library scan failed: $e');
      return false;
    }
  }

  /// App Store direct launch is deliberately independent from the TestFlight
  /// cache. For a physical ROM inside the currently linked App Store folder,
  /// dispatch the filename directly. iOS/url_launcher can report false after a
  /// successful custom-scheme handoff, so a non-throwing dispatch is terminal
  /// and must not fall through to Open In / Share.
  static Future<bool> launchGameByRomPath(String romPath) async {
    if (!ownsRomPath(romPath)) return false;
    try {
      if (!await File(romPath).exists()) return false;
      final filename = path.basename(romPath);
      final uri = Uri(
        scheme: 'retroarch',
        host: 'game',
        pathSegments: [filename],
      );
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        _log.w(
          'RetroArch App Store handoff reported false for $uri; treating the '
          'dispatch as terminal to prevent Open In / Share.',
        );
      }
      return true;
    } catch (e) {
      _log.e('RetroArch App Store launch failed: $e');
      return false;
    }
  }
}
