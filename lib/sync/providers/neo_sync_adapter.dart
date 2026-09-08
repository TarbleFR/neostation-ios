/// Adapts the existing [NeoSyncProvider] to the [ISyncProvider] interface.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/services/neosync/neo_sync_save_policy.dart';
import '../i_sync_provider.dart';

/// Official & Recommended — maintained by NeoGameLab.
class NeoSyncAdapter extends ChangeNotifier implements ISyncProvider {
  static const String kProviderId = 'neosync';

  final NeoSyncProvider _provider;

  NeoSyncAdapter(this._provider) {
    _provider.addListener(notifyListeners);
  }

  @override
  String get providerId => kProviderId;

  @override
  SyncProviderMeta get meta => const SyncProviderMeta(
    id: kProviderId,
    name: 'NeoSync',
    description:
        'Official NeoStation cloud sync. On iOS, supports RetroArch only.',
    author: 'NeoGameLab',
    isOfficial: true,
    isRecommended: true,
    iconAssetPath: 'assets/icons/neosync.png',
  );

  @override
  SyncProviderStatus get status {
    if (_provider.isSyncing) return SyncProviderStatus.syncing;
    if (_provider.error != null) return SyncProviderStatus.error;
    if (_provider.isNeoSyncAuthenticated) return SyncProviderStatus.connected;
    return SyncProviderStatus.disconnected;
  }

  @override
  bool get isAuthenticated => _provider.isNeoSyncAuthenticated;

  @override
  String? get lastError => _provider.error;

  @override
  Future<void> initialize() async {}

  @override
  void dispose() {
    _provider.removeListener(notifyListeners);
    super.dispose();
  }

  @override
  Future<SyncResult> login() async {
    if (_provider.isNeoSyncAuthenticated) return SyncResult.ok();
    return SyncResult.fail(
      SyncError.authRequired,
      message: 'Open Settings → NeoSync to sign in',
    );
  }

  @override
  Future<void> logout() async {}

  @override
  Future<SyncResult> uploadSave(
    String gameId,
    File file, {
    String? customFileName,
  }) async {
    try {
      await _provider.autoSyncUploads();
      if (_provider.error != null) {
        return SyncResult.fail(SyncError.unknown, message: _provider.error);
      }
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  Future<SyncResult> downloadSave(String gameId, String fileId) async {
    try {
      await _provider.autoSyncDownloads();
      if (_provider.error != null) {
        return SyncResult.fail(SyncError.unknown, message: _provider.error);
      }
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  Future<List<SyncFile>> listSaves({String? gameId}) async {
    if (!await _provider.loadFiles()) {
      throw StateError(_provider.error ?? 'NeoSync cloud inventory unavailable');
    }
    return _provider.files
        .where(
          (f) =>
              f.saveKind == NeoSyncSaveKind.save &&
              (gameId == null || f.gameName == gameId),
        )
        .map(
          (f) => SyncFile(
            id: f.id,
            fileName: f.fileName,
            gameName: f.gameName,
            fileSize: f.fileSize,
            uploadedAt: f.uploadedAt,
            modifiedAt: f.fileModifiedAt,
            checksum: f.checksum,
          ),
        )
        .toList();
  }

  @override
  Future<SyncResult> fullSync() async {
    try {
      await _provider.syncWithConflictResolution();
      if (_provider.error != null) {
        return SyncResult.fail(SyncError.unknown, message: _provider.error);
      }
      return SyncResult.ok(
        message:
            '${_provider.uploadedFiles} uploaded, '
            '${_provider.downloadedFiles} downloaded',
      );
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  Future<SyncResult> detectGameSaveFiles(GameModel game) async {
    try {
      await _provider.detectGameSaveFiles(game);
      final dolphinError = _provider.dolphinSaveSyncError(game);
      if (dolphinError != null) {
        return SyncResult.fail(SyncError.unknown, message: dolphinError);
      }
      final gameFailure = _gameFailure(game.romname);
      if (gameFailure != null) return gameFailure;
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  GameSyncState? getGameSyncState(String gameId) =>
      _provider.getGameSyncState(gameId);

  @override
  bool supportsGame(GameModel game, SystemModel system) =>
      _provider.supportsGame(game, system);

  @override
  Future<SyncResult> syncGameSavesBeforeLaunch(GameModel game) async {
    try {
      await _provider.syncGameSavesBeforeLaunch(game);
      final dolphinError = _provider.dolphinSaveSyncError(game);
      if (dolphinError != null) {
        return SyncResult.fail(SyncError.unknown, message: dolphinError);
      }
      final gameFailure = _gameFailure(game.romname);
      if (gameFailure != null) return gameFailure;
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async {
    try {
      await _provider.syncGameSavesAfterClose(game);
      final dolphinError = _provider.dolphinSaveSyncError(game);
      if (dolphinError != null) {
        return SyncResult.fail(SyncError.unknown, message: dolphinError);
      }
      final gameFailure = _gameFailure(game.romname);
      if (gameFailure != null) return gameFailure;
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {
    await _provider.updateGameCloudSyncEnabled(gameId, enabled);
  }

  SyncResult? _gameFailure(String gameId) {
    final state = _provider.getGameSyncState(gameId);
    if (state?.status == GameSyncStatus.quotaExceeded) {
      return SyncResult.fail(
        SyncError.quotaExceeded,
        message: state?.errorMessage ?? 'NeoSync storage quota exceeded',
      );
    }
    if (state?.status == GameSyncStatus.error) {
      return SyncResult.fail(
        SyncError.unknown,
        message: state?.errorMessage ?? 'Save synchronization failed',
      );
    }
    return null;
  }

  @override
  Future<SyncQuota?> getQuota() async {
    await _provider.loadQuota();
    final q = _provider.quota;
    if (q == null) return null;
    return SyncQuota(usedBytes: q.usedQuota, totalBytes: q.totalQuota);
  }

  @override
  Future<SyncResult> deleteRemote(String fileId) async {
    try {
      final deleted = await _provider.deleteOnlineFile(fileId);
      return deleted
          ? SyncResult.ok()
          : SyncResult.fail(SyncError.unknown, message: 'Delete failed');
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }
}
