part of '../neo_sync_provider.dart';

/// Compatibility surface retained for callers compiled against older iOS
/// builds. NeoSync no longer reads, writes, lists or restores DolphiniOS saves.
extension NeoSyncDolphin on NeoSyncProvider {
  bool _isDolphinGame(GameModel game) =>
      Platform.isIOS &&
      DolphinInternalV2Service.isDolphinSystem(game.systemFolderName ?? '');

  String get _dolphinAccount => _authService?.currentUser?.id ?? '';

  Future<T> _dolphinExclusive<T>(
    Future<T> Function(DolphinNeoSyncStore) action,
  ) => Future<T>.error(
    StateError('NeoSync is disabled for DolphiniOS on iOS'),
  );

  Future<List<NeoSyncFile>> _recoverDolphinOrigins(
    List<NeoSyncFile> files,
    DolphinNeoSyncStore store, {
    required String account,
  }) async => files;

  Future<List<NeoSyncFile>> _dolphinDisplayFiles(
    List<NeoSyncFile> files,
  ) async => files.where((file) => file.dolphinTarget == null).toList();

  Future<List<LocalSaveFile>> _dolphinLocalFiles(GameModel game) async =>
      const <LocalSaveFile>[];

  Future<List<NeoSyncFile>> _dolphinCloudFiles(GameModel game) async =>
      const <NeoSyncFile>[];

  Future<void> _syncDolphinGame(
    GameModel game, {
    bool upload = true,
    bool download = true,
    bool perform = true,
  }) async {
    if (!_isDolphinGame(game)) return;
    _updateGameSyncState(
      game.romname,
      game.name,
      neo_sync.GameSyncStatus.disabled,
    );
  }

  String? dolphinSaveSyncError(GameModel game) => null;

  Future<List<LocalSaveFile>> _allDolphinLocalSaves() async =>
      const <LocalSaveFile>[];

  Future<void> _syncAllDolphinGames({
    bool upload = true,
    bool download = true,
  }) async {
    _dolphinBulkChecked = 0;
    _dolphinBulkErrors = 0;
  }

  void _finishDolphinBulkStatus() {}

  Future<void> _restoreDolphinCloud(NeoSyncFile cloudFile) async {
    throw StateError('NeoSync is disabled for DolphiniOS on iOS');
  }
}
