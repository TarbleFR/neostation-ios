import 'dart:io';

import 'package:archive/archive.dart';
import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

/// RetroArch App Store integration only.
///
/// The App Store build registers ROM/document UTIs and supports opening
/// documents in place. It does not expose the TestFlight library callback/API,
/// so this backend deliberately does not use `retroarch://game/...`.
class RetroArchAppStoreService {
  RetroArchAppStoreService._();

  static final _log = LoggerService.instance;

  static const Set<String> _directRomExtensions = {
    '.32x', '.a26', '.a52', '.a78', '.col', '.fds', '.gb', '.gbc', '.gba',
    '.gen', '.gg', '.j64', '.lnx', '.md', '.n64', '.nds', '.nes', '.ngc',
    '.ngp', '.pce', '.sfc', '.sg', '.smc', '.sms', '.sv', '.vec', '.v64',
    '.vb', '.ws', '.wsc', '.z64', '.cue', '.m3u', '.iso', '.chd', '.bin',
  };

  static const Set<String> _metadataExtensions = {
    '.txt', '.nfo', '.md5', '.sha1', '.jpg', '.jpeg', '.png', '.gif', '.xml',
    '.dat',
  };

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

  /// App Store synchronization stays local. RetroArch App Store has no
  /// TestFlight-style library export callback.
  static Future<bool> syncLinkedLibrary() async {
    final root = ConfigService.linkedExternalFolderPath;
    if (root == null || root.trim().isEmpty) return false;
    try {
      if (!await Directory(root).exists()) return false;
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

  /// Returns the actual document that iOS should hand to RetroArch App Store.
  /// ZIP cartridge ROMs are extracted to a stable NeoStation cache first,
  /// because iOS document handoff cannot address `archive.zip#inner.rom`.
  static Future<String?> launchDocumentForRomPath(String romPath) async {
    if (!ownsRomPath(romPath)) return null;
    final file = File(romPath);
    if (!await file.exists()) return null;

    if (path.extension(romPath).toLowerCase() != '.zip') return romPath;
    return _extractSingleRomFromZip(file);
  }

  /// App Store direct launch uses Apple's document-opening contract rather than
  /// the TestFlight-only `retroarch://game/...` route.
  ///
  /// `Share.shareXFiles` is intentional here: it asks iOS for applications that
  /// declare the document type. RetroArch App Store declares ROM/public.data
  /// document handling and opening-in-place, so it can receive the real file.
  static Future<bool> launchGameByRomPath(String romPath) async {
    if (!ownsRomPath(romPath)) return false;
    try {
      final documentPath = await launchDocumentForRomPath(romPath);
      if (documentPath == null || documentPath.isEmpty) {
        _log.w(
          'RetroArch App Store: unable to produce an unambiguous launch '
          'document for ${path.basename(romPath)}.',
        );
        return true;
      }

      await Share.shareXFiles(
        <XFile>[XFile(documentPath)],
        subject: 'Open in RetroArch',
      );
      return true;
    } catch (e) {
      _log.e('RetroArch App Store document handoff failed: $e');
      return true;
    }
  }

  static Future<String?> _extractSingleRomFromZip(File zipFile) async {
    try {
      final archive = ZipDecoder().decodeBytes(
        await zipFile.readAsBytes(),
        verify: false,
      );
      final payloads = archive.files.where((entry) {
        if (!entry.isFile || entry.name.isEmpty) return false;
        final normalized = entry.name.replaceAll('\\', '/');
        if (normalized.startsWith('__MACOSX/')) return false;
        return !_metadataExtensions
            .contains(path.extension(normalized).toLowerCase());
      }).toList();

      if (payloads.isEmpty) return null;
      final direct = payloads.where((entry) => _directRomExtensions
          .contains(path.extension(entry.name).toLowerCase())).toList();

      ArchiveFile? selected;
      if (direct.length == 1) {
        selected = direct.single;
      } else if (direct.length > 1) {
        final archiveStem =
            path.basenameWithoutExtension(zipFile.path).toLowerCase();
        for (final candidate in direct) {
          if (path.basenameWithoutExtension(candidate.name).toLowerCase() ==
              archiveStem) {
            selected = candidate;
            break;
          }
        }
        for (final candidate in direct) {
          if (selected != null) break;
          final ext = path.extension(candidate.name).toLowerCase();
          if (ext == '.cue' || ext == '.m3u') selected = candidate;
        }
      } else if (payloads.length == 1) {
        selected = payloads.single;
      }

      if (selected == null) {
        _log.w(
          'RetroArch App Store: ${path.basename(zipFile.path)} contains '
          '${payloads.length} payloads and cannot be opened unambiguously.',
        );
        return null;
      }

      final outputName = path.basename(selected.name.replaceAll('\\', '/'));
      if (outputName.isEmpty) return null;
      final cacheDirectory = Directory(path.join(
        Directory.systemTemp.path,
        'neostation_retroarch_appstore',
      ));
      await cacheDirectory.create(recursive: true);
      final output = File(path.join(cacheDirectory.path, outputName));

      final content = selected.content;
      if (content is List<int>) {
        await output.writeAsBytes(content, flush: true);
      } else {
        _log.w('RetroArch App Store: unsupported ZIP payload representation.');
        return null;
      }

      _log.i(
        'RetroArch App Store: extracted ${path.basename(zipFile.path)} -> '
        '${output.path}',
      );
      return output.path;
    } catch (e) {
      _log.e('RetroArch App Store ZIP extraction failed: $e');
      return null;
    }
  }
}
