part of '../neo_sync_provider.dart';

/// Only the internal gc/wii route uses this adapter. Other sync implementations,
/// authentication, subscription/quota checks and cloud formats remain unchanged.
extension NeoSyncDolphin on NeoSyncProvider {
  bool _isDolphinGame(GameModel game) => Platform.isIOS &&
      DolphinInternalV2Service.isDolphinSystem(game.systemFolderName ?? '');

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

  /// Older unchanged snapshots may have no game_name; checksum skips must
  /// stay intact. Resolve their UI titles from the local playlist and DiscIO,
  /// without re-uploading saves, booting the core, or changing remote metadata.
  Future<List<NeoSyncFile>> _dolphinDisplayFiles(List<NeoSyncFile> files) async {
    if (!Platform.isIOS) return files;
    final missing = <String, DolphinSaveTarget>{};
    for (final file in files) {
      final target = file.dolphinTarget;
      if (target != null && target.isState && _dolphinTitles.titleFor(target) == null &&
          !file.hasDolphinGameTitle) {
        missing['${target.system}/${target.identity}'] = target;
      }
    }
    for (final system in ['gc', 'wii']) {
      if (!missing.values.any((target) => target.system == system)) continue;
      try {
        for (final row in await GameRepository.loadGamesForSystem(system)) {
          if (!missing.values.any((target) => target.system == system)) break;
          final game = GameModel.fromDatabaseModel(row);
          if (game.name.trim().isEmpty || game.romPath?.isNotEmpty != true) continue;
          try {
            final identity = await DolphinInternalV2Service.readSaveIdentity(system, game.romPath!);
            _dolphinTitles.remember(identity, game.name);
            missing.remove('${identity.system}/${identity.system == 'gc' ? identity.gameId : identity.titleId}');
          } catch (_) {
            // An unavailable imported ROM must not hide cloud saves or prevent
            // the remaining library entries from resolving their own titles.
          }
        }
      } catch (error) {
        NeoSyncProvider._log.w('[NeoSync][DolphiniOS][title.unavailable] $system: $error');
      }
    }
    return files.map((file) {
      final target = file.dolphinTarget;
      return target != null && target.isState
          ? file.withDolphinDisplayTitle(_dolphinTitles.titleFor(target)) : file;
    }).toList();
  }

  Future<List<NeoSyncFile>> _dolphinFetchCloud(String account, {required DolphinNeoSyncStore store}) async {
    final response = await _neoSyncService.getDolphinSaveFiles();
    if (!isNeoSyncAuthenticated || _dolphinAccount != account) {
      throw StateError('NeoSync account changed during Dolphin synchronization');
    }
    if (response['success'] != true) throw StateError('NeoSync cloud listing failed: ${response['message']}');
    final result = await _recoverDolphinOrigins(
        response['files'] as List<NeoSyncFile>, store, account: account);
    _files = result;
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

  /// Makes every snapshot of this game participate, not just the first file.
  /// The payload binds the console, native title ID, region and controller slot.
  Future<void> _syncDolphinGame(GameModel game, {
    bool upload = true, bool download = true, bool perform = true,
  }) async {
    if (!_isDolphinGame(game)) return;
    if (!isNeoSyncAuthenticated || _dolphinAccount.isEmpty || game.cloudSyncEnabled != true) {
      _dolphinState(game, neo_sync.GameSyncStatus.disabled);
      return;
    }
    final system = await _getSystemForGame(game);
    if (system == null || !system.neosync.sync) {
      _dolphinState(game, neo_sync.GameSyncStatus.disabled);
      return;
    }
    final account = _dolphinAccount;
    _dolphinState(game, neo_sync.GameSyncStatus.syncing);
    try {
      await _dolphinExclusive((store) async {
        final identity = await DolphinInternalV2Service.readSaveIdentity(system.folderName, game.romPath ?? '');
        _dolphinTitles.remember(identity, game.name);
        final cloudFiles = await _dolphinFetchCloud(account, store: store);
        final cloudByKey = <String, NeoSyncFile>{};
        for (final file in cloudFiles) {
          final target = file.dolphinTarget;
          if (target == null || !target.matches(identity)) continue;
          // Listings may separate the basename from its canonical source.
          // Local identity uses the verified path; API transfers keep file.id.
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
            // Existing NeoSync transport enforces the account's real quota.
            final displayTitle = target.isState ? game.name
                : target.system == 'gc' ? 'GC Memory cards' : 'Wii saves';
            final response = await _neoSyncService.syncFile(local!.file, displayTitle,
              customFilename: entry.key, systemId: target.system,
              emulatorId: DolphinSaveTarget.emulator, scope: target.shared ? 'shared' : 'game',
              isState: target.isState);
            if (_dolphinAccount != account) throw StateError('NeoSync account changed during upload');
            if (response['success'] != true) {
              final message = response['message']?.toString() ?? 'Dolphin upload failed';
              if (_checkQuotaExceeded(message)) throw QuotaExceededException(message, _quotaExceededAttempts);
              throw StateError(message);
            }
            // A successful HTTP request may be a skip because the cloud became
            // newer. Confirm its CONTENT before recording success/common history.
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
            // Re-snapshot after network access: a Files edit or other writer
            // must not be overwritten using the earlier comparison.
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
      _dolphinState(game, neo_sync.GameSyncStatus.error,
        error: 'Dolphin is running or another file operation is active. Save sync is deferred until the game has stopped.');
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

  Future<List<LocalSaveFile>> _allDolphinLocalSaves() async {
    if (!Platform.isIOS) return [];
    final files = <String, LocalSaveFile>{};
    for (final system in ['gc', 'wii']) {
      try {
        for (final data in await GameRepository.loadGamesForSystem(system)) {
          if (data.cloudSyncEnabled != true) continue;
          for (final file in await _dolphinLocalFiles(GameModel.fromDatabaseModel(data))) {
            files[file.relativePath] = file;
          }
        }
      } catch (error) { _dolphinLog('scan.deferred', '$system: $error'); }
    }
    return files.values.toList();
  }

  Future<void> _syncAllDolphinGames({bool upload = true, bool download = true}) async {
    _dolphinBulkChecked = 0;
    _dolphinBulkErrors = 0;
    if (!Platform.isIOS || !isNeoSyncAuthenticated) return;
    for (final system in ['gc', 'wii']) {
      try {
        final games = await GameRepository.loadGamesForSystem(system);
        for (final data in games) {
          if (data.cloudSyncEnabled != true) continue;
          _dolphinBulkChecked++;
          final game = GameModel.fromDatabaseModel(data);
          await _syncDolphinGame(game, upload: upload, download: download);
          if (dolphinSaveSyncError(game) != null) _dolphinBulkErrors++;
        }
      } catch (error) {
        // A Dolphin failure stays local: the caller continues syncing all
        // existing RetroArch/ARMSX2/MeloNX/RPCS3 integrations.
        _dolphinBulkErrors++;
        _dolphinLog('bulk.failed', '$system: $error');
      }
    }
  }

  void _finishDolphinBulkStatus() {
    if (_dolphinBulkErrors == 0) return;
    _error = 'Dolphin: $_dolphinBulkErrors save sync operation(s) failed or deferred; see per-game status. Other engines were not blocked.';
    _syncStatus = 'Synchronization finished with Dolphin warnings';
  }

  Future<void> _restoreDolphinCloud(NeoSyncFile cloudFile) async {
    if (!Platform.isIOS || !isNeoSyncAuthenticated || _dolphinAccount.isEmpty) throw StateError('NeoSync authentication required');
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
