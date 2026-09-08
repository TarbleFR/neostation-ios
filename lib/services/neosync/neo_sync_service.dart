import 'dart:async';
import 'dart:io';

import 'package:external_folder_access/external_folder_access.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/neosync/neo_sync_save_policy.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'neo_sync_service_base.dart' as base;

/// Public NeoSync service boundary.
///
/// On iOS, NeoSync is intentionally limited to RetroArch. Objects and upload
/// requests owned by the embedded DolphiniOS engine or the standalone ARMSX2,
/// RPCS3 and MeloNX integrations are filtered at the transport boundary so an
/// old caller cannot accidentally re-enable those save routes.
class NeoSyncService extends base.NeoSyncService {
  static const Set<String> _blockedIosEmulators = <String>{
    'dolphinios',
    'armsx2',
    'rpcs3',
    'melonx',
  };

  NeoSyncService() : super() {
    if (Platform.isIOS) unawaited(_cleanupLegacyIosArtifacts());
  }

  /// Removes only artifacts created for the retired native-emulator NeoSync
  /// routes. Emulator library bookmarks and actual save data are never removed.
  Future<void> _cleanupLegacyIosArtifacts() async {
    for (final key in const <String>[
      'neosync-armsx2-saves',
      'neosync-melonx-saves',
    ]) {
      try {
        await ExternalFolderAccess.clearBookmark(key: key);
      } catch (_) {}
    }

    try {
      final support = await getApplicationSupportDirectory();
      final dolphin = Directory(
        path.join(support.path, 'NeoStation', 'Dolphin'),
      );
      final cache = Directory(path.join(dolphin.path, 'NeoSync'));
      if (await cache.exists()) await cache.delete(recursive: true);

      final user = Directory(path.join(dolphin.path, 'User'));
      if (!await user.exists()) return;
      final stale = <FileSystemEntity>[];
      await for (final entity in user.list(recursive: true, followLinks: false)) {
        final name = path.basename(entity.path).toLowerCase();
        if (name.contains('.neosync-previous-') ||
            name.contains('.neosync-stage-')) {
          stale.add(entity);
        }
      }
      stale.sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final entity in stale) {
        try {
          if (entity is Directory) {
            if (await entity.exists()) await entity.delete(recursive: true);
          } else if (entity is File) {
            if (await entity.exists()) await entity.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  bool _blockedKey(String? value) {
    if (!Platform.isIOS) return false;
    final normalized = (value ?? '').replaceAll('\\', '/').toLowerCase();
    if (normalized.isEmpty) return false;
    for (final emulator in _blockedIosEmulators) {
      if (normalized.contains('/$emulator/')) return true;
    }
    return false;
  }

  bool _blockedFile(NeoSyncFile file) {
    if (!Platform.isIOS) return false;
    final emulator = file.emulator?.trim().toLowerCase() ?? '';
    return _blockedIosEmulators.contains(emulator) ||
        _blockedKey(file.fileName) ||
        _blockedKey(file.sourceSavePath);
  }

  Map<String, dynamic> _filterListing(Map<String, dynamic> result) {
    if (!Platform.isIOS || result['success'] != true) return result;
    final files = (result['files'] as List<NeoSyncFile>? ?? <NeoSyncFile>[])
        .where((file) => !_blockedFile(file))
        .toList();
    return <String, dynamic>{...result, 'files': files};
  }

  @override
  Future<Map<String, dynamic>> getDolphinSaveFiles() async {
    return _filterListing(await super.getDolphinSaveFiles());
  }

  @override
  Future<Map<String, dynamic>> getFiles() async {
    return _filterListing(await super.getDolphinSaveFiles());
  }

  @override
  Future<Map<String, dynamic>> syncFile(
    File file,
    String gameName, {
    String? customFilename,
    String? systemId,
    String? emulatorId,
    String? gameHash,
    bool? isState,
    String? scope,
    bool contentHashOnly = false,
    NeoSyncSaveSource? source,
  }) async {
    final emulator = emulatorId?.trim().toLowerCase() ?? '';
    if (Platform.isIOS &&
        (_blockedIosEmulators.contains(emulator) ||
            _blockedKey(customFilename))) {
      return <String, dynamic>{
        'success': true,
        'skipped': true,
        'excluded': true,
        'synced': false,
        'message': 'NeoSync is disabled for this iOS emulator integration',
      };
    }
    return super.syncFile(
      file,
      gameName,
      customFilename: customFilename,
      systemId: systemId,
      emulatorId: emulatorId,
      gameHash: gameHash,
      isState: isState,
      scope: scope,
      contentHashOnly: contentHashOnly,
      source: source,
    );
  }

  @override
  Future<Map<String, dynamic>> uploadFile(
    File file,
    String gameName, {
    String? customFilename,
    NeoSyncSaveSource? source,
  }) async {
    if (Platform.isIOS && _blockedKey(customFilename)) {
      return <String, dynamic>{
        'success': true,
        'skipped': true,
        'excluded': true,
        'synced': false,
        'message': 'NeoSync is disabled for this iOS emulator integration',
      };
    }
    return super.uploadFile(
      file,
      gameName,
      customFilename: customFilename,
      source: source,
    );
  }

  /// The iOS fork no longer performs automatic server-side cleanup while
  /// listing NeoSync. This prevents historical native-emulator objects from
  /// being modified or deleted after their integrations were retired.
  @override
  Future<Map<String, dynamic>> auditAndPurge({
    required Future<List<NeoSyncFile>> Function(List<NeoSyncFile>) resolveOrigins,
  }) async {
    if (!Platform.isIOS) {
      return super.auditAndPurge(resolveOrigins: resolveOrigins);
    }
    final listing = await getFiles();
    if (listing['success'] != true) return listing;
    return <String, dynamic>{
      'success': true,
      'files': listing['files'] as List<NeoSyncFile>,
      'deleted': 0,
      'failed': 0,
      'unresolved': 0,
    };
  }
}
