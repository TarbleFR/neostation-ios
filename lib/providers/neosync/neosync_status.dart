part of '../neo_sync_provider.dart';

extension NeoSyncStatus on NeoSyncProvider {
  Future<bool> loadFiles() async {
    if (!isNeoSyncAuthenticated) return false;

    _isLoadingOnlineFiles = true;
    _error = null;
    notify();

    try {
      final result = await _neoSyncService.getFiles();
      if (result['success'] == true) {
        _files = (result['files'] as List<NeoSyncFile>?) ?? <NeoSyncFile>[];
        notify();
        return true;
      }
      _error = result['message']?.toString();
      notify();
      return false;
    } catch (e) {
      _error = 'Error loading files: $e';
      notify();
      return false;
    } finally {
      _isLoadingOnlineFiles = false;
      notify();
    }
  }

  Future<bool> loadQuota() async {
    if (!isNeoSyncAuthenticated) return false;
    try {
      final result = await _neoSyncService.getQuota();
      if (result['success'] == true) {
        _quota = result['quota'] as NeoSyncQuota;
        notify();
        return true;
      }
      NeoSyncProvider._log.e('Failed to load quota: ${result['message']}');
      return false;
    } catch (e) {
      NeoSyncProvider._log.e('Error loading quota: $e');
      return false;
    }
  }

  Future<bool> deleteFile(NeoSyncFile file) async {
    if (!isNeoSyncAuthenticated) return false;
    try {
      final result = LegacyNeoSyncService.isLegacyId(file.id)
          ? await _legacyNeoSyncService.deleteFile(file.id)
          : await _neoSyncService.deleteFile(file.id);
      if (result['success'] == true) {
        _files.removeWhere((f) => f.id == file.id);
        _onlineFiles.removeWhere((f) => f.id == file.id);
        notify();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Loads v2 files and also probes the historical v1 account. Recognizable v1
  /// files are copied into v2 without deleting their originals. Any legacy file
  /// that cannot be mapped safely remains visible as a `[V1]` entry in the UI.
  Future<void> loadOnlineFiles() async {
    _isLoadingOnlineFiles = true;
    notify();

    try {
      final v2Result = await _neoSyncService.getFiles();
      var v2Files = v2Result['success'] == true
          ? ((v2Result['files'] as List<NeoSyncFile>?) ?? <NeoSyncFile>[])
          : <NeoSyncFile>[];

      final legacyResult = await _legacyNeoSyncService.getFiles();
      final legacyFiles = legacyResult['success'] == true
          ? ((legacyResult['files'] as List<NeoSyncFile>?) ?? <NeoSyncFile>[])
          : <NeoSyncFile>[];

      Set<String> migratedLegacyIds = <String>{};
      if (legacyFiles.isNotEmpty) {
        migratedLegacyIds = await _migrateLegacyFilesToV2(legacyFiles);
        if (migratedLegacyIds.isNotEmpty) {
          final refreshed = await _neoSyncService.getFiles();
          if (refreshed['success'] == true) {
            v2Files =
                (refreshed['files'] as List<NeoSyncFile>?) ?? <NeoSyncFile>[];
          }
          final quotaResult = await _neoSyncService.getQuota();
          if (quotaResult['success'] == true) {
            _quota = quotaResult['quota'] as NeoSyncQuota;
          }
        }
      }

      final unresolvedLegacy = legacyFiles
          .where((file) => !migratedLegacyIds.contains(file.id))
          .toList();
      _onlineFiles = <NeoSyncFile>[...v2Files, ...unresolvedLegacy]
        ..sort((a, b) => b.uploadedAt.compareTo(a.uploadedAt));

      if (legacyFiles.isNotEmpty) {
        NeoSyncProvider._log.i(
          'NeoSync v1 bridge: ${legacyFiles.length} found, '
          '${migratedLegacyIds.length} copied to v2, '
          '${unresolvedLegacy.length} kept as legacy entries',
        );
      }
    } catch (e) {
      NeoSyncProvider._log.e('Error loading online files: $e');
      _onlineFiles = <NeoSyncFile>[];
    } finally {
      _isLoadingOnlineFiles = false;
      notify();
    }
  }

  Future<bool> deleteOnlineFile(String fileId) async {
    try {
      final result = LegacyNeoSyncService.isLegacyId(fileId)
          ? await _legacyNeoSyncService.deleteFile(fileId)
          : await _neoSyncService.deleteFile(fileId);
      if (result['success'] == true) {
        _onlineFiles.removeWhere((file) => file.id == fileId);
        notify();
        return true;
      }
      NeoSyncProvider._log.e(
        'Failed to delete online file: ${result['message']}',
      );
      return false;
    } catch (e) {
      NeoSyncProvider._log.e('Error deleting online file: $e');
      return false;
    }
  }
}
