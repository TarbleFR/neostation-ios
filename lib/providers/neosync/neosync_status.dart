part of '../neo_sync_provider.dart';

extension NeoSyncStatus on NeoSyncProvider {
  Future<bool> loadFiles() async {
    if (!isNeoSyncAuthenticated) return false;
// DOLPHIN_ISOLATION_BEGIN: neosync_listing_account
    final listingAccount = _dolphinAccount;
// DOLPHIN_ISOLATION_END: neosync_listing_account

    _isLoadingOnlineFiles = true;
    _error = null;
    notify();

    try {
      final result = await _neoSyncService.getFiles();
// DOLPHIN_ISOLATION_BEGIN: neosync_listing_publication
      if (!isNeoSyncAuthenticated || listingAccount != _dolphinAccount) return false;
// DOLPHIN_ISOLATION_END: neosync_listing_publication
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

  // DOLPHIN_ISOLATION_BEGIN: neosync_current_inventory
  /// The v2 service is authoritative. Historical manual recovery is separate;
  /// an unavailable old deployment must not gate current saves or hide audits.
  Future<void> loadOnlineFiles() async {
    if (!isNeoSyncAuthenticated || _saveAuditInProgress) return;
    _saveAuditInProgress = true;
    final auditAccount = _dolphinAccount;
    _saveAuditMessage = null;
    _error = null;
    _isLoadingOnlineFiles = true;
    notify();
    try {
      final result = await _neoSyncService.auditAndPurge(
          resolveOrigins: _resolveNeoSyncOrigins);
      if (!isNeoSyncAuthenticated || auditAccount != _dolphinAccount) return;
      if (result['success'] != true) {
        if (result['phase'] == 'listing') _error = '${result['message']}';
        throw StateError('${result['message']}');
      }
      final deleted = result['deleted'] as int? ?? 0;
      final failed = result['failed'] as int? ?? 0;
      final unresolved = result['unresolved'] as int? ?? 0;
      var files = (result['files'] as List<NeoSyncFile>?) ?? <NeoSyncFile>[];
      files = await _dolphinDisplayFiles(files);
      if (!isNeoSyncAuthenticated || auditAccount != _dolphinAccount) return;
      _files = files;
      _onlineFiles = List<NeoSyncFile>.of(files)
        ..sort((a, b) => b.uploadedAt.compareTo(a.uploadedAt));
      final saves = NeoSyncSaveUnits.cloud(files).length;
      _processedItems.add('NeoSync v2: ${files.length} objects, $saves saves, '
          '$deleted non-save files removed, $failed failed, $unresolved unresolved');
      _saveAuditMessage = deleted + failed + unresolved > 0
          ? '$saves sauvegardes reconnues · $unresolved à identifier · '
              '$deleted fichiers hors sauvegardes supprimés · $failed suppressions échouées'
          : null;
      if (deleted > 0) await loadQuota();
    } catch (error) {
      NeoSyncProvider._log.e('Error loading online files: $error');
      _saveAuditMessage = 'Vérification NeoSync interrompue : $error';
    } finally {
      _saveAuditInProgress = false;
      _isLoadingOnlineFiles = false;
      notify();
    }
  }
  // DOLPHIN_ISOLATION_END: neosync_current_inventory

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
