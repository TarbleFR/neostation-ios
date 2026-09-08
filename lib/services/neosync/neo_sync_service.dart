import 'dart:io';

import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/neosync/neo_sync_save_policy.dart';

import 'neo_sync_service_base.dart' as base;

/// Public NeoSync service boundary.
///
/// On iOS, NeoSync supports RetroArch plus the strict DolphiniOS V1 save
/// contract. Objects and upload requests owned by the standalone ARMSX2,
/// RPCS3 and MeloNX integrations are filtered at the transport boundary so an
/// old caller cannot accidentally re-enable those save routes.
class NeoSyncService extends base.NeoSyncService {
  static const Set<String> _blockedIosEmulators = <String>{
    'armsx2',
    'rpcs3',
    'melonx',
  };

  bool _blockedKey(String? value) {
    return NeoSyncSavePolicy.isIosCloudPathExcluded(value ?? '');
  }

  bool _blockedNativeKey(String? value) {
    if (!Platform.isIOS) return false;
    final normalized = (value ?? '').replaceAll('\\', '/').toLowerCase();
    if (normalized.isEmpty) return false;
    return _blockedIosEmulators.any(
      (emulator) => normalized.contains('/$emulator/'),
    );
  }

  bool _blockedIdentity(String? value) {
    if (!Platform.isIOS) return false;
    final normalized = value?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty) return false;
    final tokens = normalized.split(RegExp(r'[^a-z0-9]+'));
    return _blockedIosEmulators.any(
      (emulator) => normalized == emulator || tokens.contains(emulator),
    );
  }

  bool _blockedFile(NeoSyncFile file) {
    if (!Platform.isIOS) return false;
    return _blockedIdentity(file.emulator) ||
        _blockedNativeKey(file.fileName) ||
        _blockedNativeKey(file.filePath) ||
        _blockedNativeKey(file.sourceSavePath);
  }

  bool _inactiveFile(NeoSyncFile file) =>
      NeoSyncSavePolicy.isIosCloudFileExcluded(file);

  bool _blockedSource(NeoSyncSaveSource? source) =>
      Platform.isIOS &&
      const {
        NeoSyncSaveFamily.armsx2,
        NeoSyncSaveFamily.rpcs3,
        NeoSyncSaveFamily.melonx,
      }.contains(source?.family);

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
    if (Platform.isIOS &&
        (_blockedIdentity(emulatorId) ||
            _blockedNativeKey(file.path) ||
            _blockedSource(source) ||
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
    if (Platform.isIOS &&
        (_blockedNativeKey(file.path) ||
            _blockedSource(source) ||
            _blockedKey(customFilename))) {
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

  /// Audits the complete inventory while preserving inactive iOS emulator
  /// objects and filtering them from the public listing. On iOS, historical
  /// objects may be identified but are never automatically deleted.
  @override
  Future<Map<String, dynamic>> auditAndPurge({
    required Future<List<NeoSyncFile>> Function(List<NeoSyncFile>) resolveOrigins,
    bool Function(NeoSyncFile)? preserve,
  }) async {
    final bool Function(NeoSyncFile)? effectivePreserve;
    if (!Platform.isIOS) {
      effectivePreserve = preserve;
    } else {
      effectivePreserve = (file) =>
          file.saveKind == NeoSyncSaveKind.foreign ||
          _blockedFile(file) ||
          (preserve?.call(file) ?? _inactiveFile(file));
    }
    return _filterListing(
      await super.auditAndPurge(
        resolveOrigins: resolveOrigins,
        preserve: effectivePreserve,
      ),
    );
  }
}
