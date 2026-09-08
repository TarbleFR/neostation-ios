part of '../neo_sync_provider.dart';

/// Only the internal gc/wii route uses this adapter. Other sync implementations,
/// authentication, subscription/quota checks and cloud formats remain unchanged.
extension NeoSyncDolphin on NeoSyncProvider {
  // DolphiniOS remains available as an emulator, but NeoSync is intentionally
  // disabled for it. RetroArch is the only NeoSync backend on iOS.
  bool _isDolphinGame(GameModel game) => false;

  String get _dolphinAccount => _authService?.currentUser?.id ?? '';

  void _dolphinLog(String stage, String message) {
    NeoSyncProvider._log.i('[NeoSync][DolphiniOS][$stage] $message');
    _processedItems.add('DolphiniOS: $message');
    unawaited(DolphinInternalV2Service.logSaveSync(stage, message).catchError((Object _) {}));
  }

  void _dolphinState(GameModel game, neo_sync.GameSyncStatus status, {
    String? error, LocalSaveFile? local, NeoSyncFile? cloud,
  }) {
    _gameSyncStates[game.romname] = neo_sync.GameSyncState(
      gameId: game.romname, gameName: game.name, status: status,
      cloudEnabled: game.cloudSyncEnabled == true, localSave: local,
      cloudSave: cloud, errorMessage: error,
      lastSync: status == neo_sync.GameSyncStatus.upToDate ? DateTime.now() : null,
    );
    notify();
  }

  LocalSaveFile _dolphinLocal(DolphinSaveSnapshot snapshot, String gameName, {bool synced = false}) => LocalSaveFile(
    filePath: snapshot.file.path, fileName: snapshot.target.objectName,
    fileSize: snapshot.size, lastModified: snapshot.modified, gameName: gameName,
    isSynced: synced, relativePath: snapshot.target.cloudPath,
  );

  Future<T> _dolphinExclusive<T>(Future<T> Function(DolphinNeoSyncStore) action) async {
    // Per-provider serialization plus the native/Dart launch exclusion. This
    // never holds a shared audio, controller or external-emulator launch lock.
    final previous = _dolphinSyncTail;
    final complete = Completer<void>();
    _dolphinSyncTail = complete.future;
    await previous;
    try { return await DolphinInternalV2Service.withSaveAccess(action); }
    finally { complete.complete(); }
  }

  /// V1 objects already carry their complete display identity: a regional GC
  /// card name or an exact Wii Title ID. No ROM-title inference is needed.
  Future<List<NeoSyncFile>> _dolphinDisplayFiles(List<NeoSyncFile> files) =>
      Future.value(files);

  Future<List<NeoSyncFile>> _dolphinFetchCloud(String account, {required DolphinNeoSyncStore store}) async {
    final response = await _neoSyncService.getDolphinSaveFiles();
    if (!isNeoSyncAuthenticated || _dolphinAccount != account) {
      throw StateError('NeoSync account changed during Dolphin synchronization');
    }
    if (response['success'] != true) throw StateError('NeoSync cloud listing failed: ${response['message']}');
    final result = await _recoverDolphinOrigins(
        response['files'] as List<NeoSyncFile>, store, account: account);
    _publishCloudInventory(result);
    return result;
  }

  Future<List<LocalSaveFile>> _dolphinLocalFiles(GameModel game) async {
    if (!_isDolphinGame(game) || game.cloudSyncEnabled != true) return [];
    return _dolphinExclusive((store) async {
      final identity = await DolphinInternalV2Service.readSaveIdentity(game.systemFolderName!, game.romPath ?? '');
      _dolphinTitles.remember(identity, game.name);
      final result = <LocalSaveFile>[];
      for (final target in await store.targetsForGame(identity)) {
        final snapshot = await store.snapshot(target);
        if (snapshot != null) result.add(_dolphinLocal(snapshot, game.name,
          synced: _files.any((remote) => remote.dolphinTarget?.cloudPath == target.cloudPath && remote.checksum?.toLowerCase() == snapshot.checksum)));
      }
      return result;
    });
  }

  Future<List<NeoSyncFile>> _dolphinCloudFiles(GameModel game) async {
    if (!_isDolphinGame(game) || !isNeoSyncAuthenticated || game.cloudSyncEnabled != true) return [];
    return _dolphinExclusive((store) async {
      final identity = await DolphinInternalV2Service.readSaveIdentity(game.systemFolderName!, game.romPath ?? '');
      _dolphinTitles.remember(identity, game.name);
      return (await _dolphinFetchCloud(_dolphinAccount, store: store)).where((file) =>
        file.dolphinTarget?.matches(identity) == true).toList();
    });
  }

  /// Makes every V1 snapshot participate: both regional GC cards, or the one
  /// Wii data tree bound to the verified native Title ID.
  Future<void> _syncDolphinGame(GameModel game, {
    bool upload = true, bool download = true, bool perform = true,
  }) async {
    if (!_isDolphinGame(game)) return;
    if (!isNeoSyncAuthenticated || _dolphinAccount.isEmpty || game.cloudSyncEnabled != true) {
      _dolphinLog('disabled', '${game.name}: authentication=${isNeoSyncAuthenticated && _dolphinAccount.isNotEmpty}; gameSync=${game.cloudSyncEnabled == true}');
      _dolphinState(game, neo_sync.GameSyncStatus.disabled);
      return;
    }
    final system = await _getSystemForGame(game);
    if (system == null || !system.neosync.sync) {
      _dolphinLog('disabled.system', '${game.name}: system=${system?.folderName ?? "missing"}; sync=${system?.neosync.sync}');
      _dolphinState(game, neo_sync.GameSyncStatus.disabled);
      return;
    }
    final account = _dolphinAccount;
    _dolphinState(game, neo_sync.GameSyncStatus.syncing);
    try {
      await _dolphinExclusive((store) async {
        final identity = await DolphinInternalV2Service.readSaveIdentity(system.folderName, game.romPath ?? '');
        _dolphinTitles.remember(identity, game.name);
        _dolphinLog('identity', '${identity.system}: ${identity.gameId}; title=${identity.titleId ?? "n/a"}; region=${identity.region}');
        final cloudFiles = await _dolphinFetchCloud(account, store: store);
        final cloudByKey = <String, NeoSyncFile>{};
        for (final file in cloudFiles) {
          final target = file.dolphinTarget;
          if (target == null || !target.matches(identity)) continue;
          if (cloudByKey.containsKey(target.cloudPath)) throw StateError('Duplicate Dolphin cloud save key');
          cloudByKey[target.cloudPath] = file;
        }
        final targets = <String, DolphinSaveTarget>{
          for (final target in await store.targetsForGame(identity)) target.cloudPath: target,
          for (final key in cloudByKey.keys) key: DolphinSaveTarget.parse(key)!,
        };
        var aggregate = neo_sync.GameSyncStatus.noSaveFound;
        var hasPendingUpload = false;
        var hasPendingDownload = false;
        final localSaves = <LocalSaveFile>[];
        _gameCloudSaves[game.romname] = cloudByKey.values.toList();
        for (final entry in targets.entries) {
          if (!isNeoSyncAuthenticated || _dolphinAccount != account) throw StateError('NeoSync account changed');
          final target = entry.value;
          final local = await store.snapshot(target);
          final remote = cloudByKey[entry.key];
          final remoteHash = remote?.checksum?.toLowerCase();
          if (remote != null && (remoteHash == null || !RegExp(r'^[a-f0-9]{32}$').hasMatch(remoteHash))) {
            throw StateError('Missing checksum for Dolphin cloud save');
          }
          final common = await store.lastCommonHash(account, target);
          final decision = dolphinSyncDecision(local?.checksum, remoteHash, common);
          _dolphinLog('compare', '${target.relativeNativePath}: local=${local?.size ?? 0} B; remote=${remote?.fileSize ?? 0} B; decision=${decision.name}');
          if (local != null) localSaves.add(_dolphinLocal(local, game.name,
            synced: decision == DolphinSyncDecision.equal));
          if (decision == DolphinSyncDecision.empty) continue;
          if (decision == DolphinSyncDecision.conflict) {
            throw StateError('Save conflict: local and cloud Dolphin data differ. Neither copy was overwritten. '
                'Use the explicit cloud restore action to choose the cloud copy (a local backup is kept).');
          }
          aggregate = neo_sync.GameSyncStatus.upToDate;
          if (decision == DolphinSyncDecision.equal) {
            if (perform) await store.remember(account, target, local!.checksum);
            _skippedFiles++;
            continue;
          }
          if (decision == DolphinSyncDecision.upload) {
            if (!perform || !upload) { hasPendingUpload = true; continue; }
            final displayTitle =
                target.system == 'gc' ? 'GC Memory cards' : 'Wii saves';
            final response = await _neoSyncService.syncFile(local!.file, displayTitle,
              customFilename: entry.key, systemId: target.system,
              emulatorId: DolphinSaveTarget.emulator, scope: target.shared ? 'shared' : 'game',
              isState: false);
            if (_dolphinAccount != account) throw StateError('NeoSync account changed during upload');
            if (response['success'] != true) {
              final message = response['message']?.toString() ?? 'Dolphin upload failed';
              if (_checkQuotaExceeded(message)) throw QuotaExceededException(message, _quotaExceededAttempts);
              throw StateError(message);
            }
            final refreshed = await _dolphinFetchCloud(account, store: store);
            final confirmed = refreshed.where((f) => f.dolphinTarget?.cloudPath == entry.key && f.checksum?.toLowerCase() == local.checksum);
            if (confirmed.length != 1) throw StateError('Dolphin upload not confirmed; cloud may have changed');
            cloudByKey[entry.key] = confirmed.single;
            await store.remember(account, target, local.checksum);
            _uploadedFiles++;
            _dolphinLog('upload.complete', '${game.name}: ${target.objectName}');
          } else {
            if (!perform || !download) { hasPendingDownload = true; continue; }
            if (remote!.fileSize > DolphinNeoSyncStore.payloadLimit(target)) throw StateError('Dolphin cloud snapshot exceeds size limit');
            final payload = await downloadOnlineFileBytes(remote);
            if (!isNeoSyncAuthenticated || _dolphinAccount != account) throw StateError('NeoSync account changed during download');
            final current = await store.snapshot(target);
            if (current?.checksum != local?.checksum) throw StateError('Dolphin save changed during download');
            await store.restore(target, payload, checksum: remoteHash!);
            final restored = await store.snapshot(target);
            if (restored?.checksum != remoteHash) throw StateError('Restored Dolphin save failed read-back verification');
            await store.remember(account, target, remoteHash);
            _downloadedFiles++;
            _dolphinLog('restore.complete', '${game.name}: ${target.objectName} (previous native data retained)');
          }
        }
        if (perform) {
          localSaves.clear();
          for (final target in targets.values) {
            final snapshot = await store.snapshot(target);
            if (snapshot != null) {
              final common = await store.lastCommonHash(account, target);
              localSaves.add(_dolphinLocal(snapshot, game.name, synced: common == snapshot.checksum));
            }
          }
        }
        _gameLocalSaves[game.romname] = localSaves;
        _gameCloudSaves[game.romname] = cloudByKey.values.toList();
        if (hasPendingUpload) aggregate = neo_sync.GameSyncStatus.localOnly;
        else if (hasPendingDownload) aggregate = neo_sync.GameSyncStatus.cloudOnly;
        _dolphinState(game, aggregate,
          local: localSaves.isNotEmpty ? localSaves.first : null,
          cloud: cloudByKey.isNotEmpty ? cloudByKey.values.first : null);
      });
    } on DolphinSystemFilesException catch (error) {
      _dolphinLog('deferred', '${game.name}: ${error.code}; no live save touched');
      if (error.code == 'busy') {
        _dolphinState(game, neo_sync.GameSyncStatus.pending);
      } else {
        _dolphinState(game, neo_sync.GameSyncStatus.error, error: '${error.code}');
      }
    } on QuotaExceededException catch (error) {
      _quotaExceededActive = true;
      _dolphinState(game, neo_sync.GameSyncStatus.quotaExceeded, error: error.message);
      _dolphinLog('quota', error.message);
    } catch (error) {
      _dolphinState(game, neo_sync.GameSyncStatus.error, error: '$error');
      _dolphinLog('failed', '${game.name}: $error');
    }
  }

  String? dolphinSaveSyncError(GameModel game) {
    if (!_isDolphinGame(game)) return null;
    return _gameSyncStates[game.romname]?.errorMessage;
  }

  Future<List<LocalSaveFile>> _allDolphinLocalSaves() async => const [];

  Future<void> _syncAllDolphinGames({bool upload = true, bool download = true}) async {
    _dolphinBulkChecked = 0;
    _dolphinBulkErrors = 0;
  }

  void _finishDolphinBulkStatus() {
    if (_dolphinBulkErrors == 0) return;
    _dolphinLog('bulk.warning', '$_dolphinBulkErrors operation(s) failed; see per-game status.');
    _syncStatus = 'Synchronization finished with Dolphin warnings';
  }

  Future<void> _restoreDolphinCloud(NeoSyncFile cloudFile) async {
    if (Platform.isIOS) {
      throw UnsupportedError('DolphiniOS NeoSync is disabled on iOS');
    }
    if (!isNeoSyncAuthenticated || _dolphinAccount.isEmpty) throw StateError('NeoSync authentication required');
    final target = cloudFile.dolphinTarget;
    if (target == null) throw const FormatException('Unsupported Dolphin save snapshot');
    final account = _dolphinAccount;
    await _dolphinExclusive((store) async {
      final current = await _dolphinFetchCloud(account, store: store);
      if (!current.any((file) => file.id == cloudFile.id &&
          file.fileName == cloudFile.fileName && file.checksum == cloudFile.checksum &&
          file.dolphinTarget?.cloudPath == target.cloudPath)) {
        throw StateError('Cloud save changed; refresh NeoSync before restoring');
      }
      if (cloudFile.fileSize > DolphinNeoSyncStore.payloadLimit(target)) throw const FormatException('Dolphin snapshot too large');
      final payload = await downloadOnlineFileBytes(cloudFile);
      if (_dolphinAccount != account || !isNeoSyncAuthenticated) throw StateError('NeoSync account changed');
      await store.restore(target, payload, checksum: cloudFile.checksum?.toLowerCase() ?? '');
      final restored = await store.snapshot(target);
      if (restored?.checksum != cloudFile.checksum?.toLowerCase()) throw StateError('Dolphin restore read-back failed');
      await store.remember(account, target, restored!.checksum);
      _dolphinLog('restore.explicit', '${target.objectName}; previous local snapshot retained');
    });
  }
}
