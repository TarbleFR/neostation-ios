import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/cloud_save_models.dart';
import '../models/game_model.dart';
import '../repositories/game_repository.dart';
import '../services/cloud_saves/cloud_folder_access.dart';
import '../services/cloud_saves/native_save_ownership.dart';
import '../services/cloud_saves/save_revision.dart';
import '../services/cloud_saves/save_snapshot.dart';
import '../services/cloud_saves/save_source_registry.dart';
import '../services/game/game_session_manager.dart';
import '../sync/i_sync_provider.dart';

/// The only built-in cloud provider. iOS handles network replication; this
/// class owns immutable revisions and a durable per-folder outbox. It never
/// treats a filesystem copy as proof of a completed iCloud upload.
class ICloudSaveProvider extends ChangeNotifier implements ISyncProvider {
  final CloudFolderAccess access;
  final SaveSourceRegistry sources;
  final Future<Directory> Function() supportDirectory;
  final bool Function() gameIsRunning;
  final Future<List<GameModel>> Function() loadGames;
  Completer<void>? _restoring;
  bool _rescanRequested = false;
  final Set<String> _deleted = {};
  static String _deletedKey(String unit, String hash) => '$unit\n$hash';
  ICloudSaveProvider({CloudFolderAccess? access, SaveSourceRegistry? sources,
      Future<Directory> Function()? supportDirectory, bool Function()? gameIsRunning,
      Future<List<GameModel>> Function()? loadGames})
      : access = access ?? IOSCloudFolderAccess(), sources = sources ?? SaveSourceRegistry(),
        supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
        gameIsRunning = gameIsRunning ?? (() => GameSessionManager.isGameLaunchInProgress),
        loadGames = loadGames ?? (() async => (await GameRepository.getAllGames()).map(GameModel.fromDatabaseModel).toList());
  @override String get providerId => 'icloud';
  @override SyncProviderMeta get meta => const SyncProviderMeta(id: 'icloud', name: 'iCloud Saves',
    description: 'Personal iCloud Drive save folder', author: 'NeoStation iOS', isRecommended: true);
  @override SyncProviderStatus status = SyncProviderStatus.disconnected;
  @override String? lastError;
  bool connected = false, enabled = false, _busy = false, _disposed = false;
  String _scope = '';
  int pendingCount = 0, invalidCount = 0, _epoch = 0;
  final Map<String, SaveRevision> _revisions = {};
  final Map<String, GameSyncState> _games = {};
  final Map<String, bool> _overrides = {};
  final Map<String, String> sourceWarnings = {};
  List<SaveRevision> get revisions => _revisions.values.toList()..sort((a, b) => b.modified.compareTo(a.modified));
  int get usedBytes => _revisions.values.fold(0, (sum, item) => sum + item.size);
  bool get busy => _busy;
  @override bool get isAuthenticated => connected && enabled && _scope.isNotEmpty;
  void _notify() { if (!_disposed) notifyListeners(); }
  @override Future<void> initialize() async {
    access.onAvailabilityChanged = () { _epoch++; connected = false; enabled = false;
      status = SyncProviderStatus.disconnected; _revisions.clear(); _games.clear(); _deleted.clear(); _notify(); };
    try {
      final text = (await SharedPreferences.getInstance()).getString('icloud_saves.game_switches.v1');
      if (text != null) _overrides.addAll(Map<String, bool>.from(jsonDecode(text) as Map));
      await sources.loadIdentities();
      try { await access.call('recoverRestores'); } catch (error) { sourceWarnings['Recovery'] = error.toString(); }
      await _connection();
    } catch (error) { lastError = error.toString(); status = SyncProviderStatus.disconnected; }
    _notify();
  }
  Future<void> _connection() async {
    final result = await access.call('status');
    final scope = result['scope'] as String? ?? '';
    if (scope != _scope) { _epoch++; _scope = scope; _revisions.clear(); _games.clear(); _deleted.clear(); }
    connected = result['connected'] == true;
    enabled = result['enabled'] == true;
    status = isAuthenticated ? SyncProviderStatus.connected : enabled ? SyncProviderStatus.disconnected : SyncProviderStatus.paused;
  }
  void _check(int epoch, String scope) {
    if (_epoch != epoch || _scope != scope || !isAuthenticated || _disposed) {
      throw PlatformException(code: 'CANCELLED', message: 'Cloud folder changed or synchronization was disabled.');
    }
  }
  @override Future<SyncResult> login() async {
    if (_busy) return SyncResult.fail(SyncError.configInvalid, message: 'Wait for the current save operation.');
    try {
      status = SyncProviderStatus.connecting; _notify();
      await access.call('connect'); await _connection();
      if (!isAuthenticated) return SyncResult.fail(SyncError.authRequired, message: 'No iCloud Drive folder was authorized.');
      lastError = null; await refresh();
      return SyncResult.ok(message: 'iCloud Drive folder authorized.');
    } catch (error) { lastError = error.toString(); status = SyncProviderStatus.disconnected;
      return SyncResult.fail(SyncError.authRequired, message: lastError);
    } finally { _notify(); }
  }
  Future<void> setEnabled(bool value) async {
    _epoch++;
    if (!value) { enabled = false; status = SyncProviderStatus.paused; _notify(); }
    await access.call('setEnabled', {'enabled': value});
    await _connection(); _notify();
    if (value) await fullSync();
  }
  @override Future<void> logout() async {
    _epoch++; connected = false; enabled = false; _revisions.clear(); _games.clear(); _deleted.clear();
    status = SyncProviderStatus.disconnected; _notify();
    await access.call('disconnect'); _scope = '';
    // Native saves, published revisions, and unsent private backups are retained.
  }
  Future<Directory> _outbox(String scope) async {
    if (!RegExp(r'^[a-zA-Z0-9-]{1,100}$').hasMatch(scope)) throw const FormatException('Invalid cloud scope');
    final root = Directory(p.join((await supportDirectory()).path, 'ICloudSaves', 'outbox', scope));
    await root.create(recursive: true); return root;
  }
  Future<void> refresh() async {
    if (!isAuthenticated) return;
    final epoch = _epoch, scope = _scope;
    final result = await access.call('list', {'scope': scope});
    _check(epoch, scope);
    for (final entry in result['deleted'] as List? ?? const []) {
      if (entry is Map && entry['unit'] is String && entry['contentHash'] is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(entry['contentHash'] as String)) {
        _deleted.add(_deletedKey(entry['unit'] as String, entry['contentHash'] as String));
      }
    }
    final parsed = <String, SaveRevision>{};
    var invalid = result['invalid'] as int? ?? 0;
    for (final row in result['revisions'] as List? ?? const []) {
      try {
        final value = Map<String, dynamic>.from(row as Map);
        final revision = SaveRevision.fromJson(Map<String, dynamic>.from(value['manifest'] as Map), state: value['state'] as String? ?? 'pending');
        if (value['path'] != revision.manifestPath) throw const FormatException('Manifest path does not match identity');
        if (!_deleted.contains(_deletedKey(revision.unitKey, revision.contentHash))) parsed[revision.id] = revision;
      } catch (_) { invalid++; }
    }
    pendingCount = result['pending'] as int? ?? 0;
    invalidCount = invalid;
    // A partial provider inventory cannot prove a previous revision disappeared.
    if (pendingCount == 0 && invalid == 0) _revisions.clear();
    _revisions.addAll(parsed);
    _revisions.removeWhere((_, r) => _deleted.contains(_deletedKey(r.unitKey, r.contentHash)));
    pendingCount += parsed.values.where((e) => e.transferState != 'uploaded').length;
    await _drain(scope, epoch, publish: false);
    _notify();
  }
  Future<void> _drain(String scope, int epoch, {required bool publish}) async {
    final root = await _outbox(scope);
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      _check(epoch, scope);
      final rev = SaveRevision.fromJson(Map<String, dynamic>.from(jsonDecode(await entry.readAsString()) as Map));
      final file = File(p.join(root.path, '${rev.storageKey}.nssave'));
      if (!await file.exists()) throw const FileSystemException('Pending save payload is missing');
      if (_deleted.contains(_deletedKey(rev.unitKey, rev.contentHash))) {
        await file.delete(); await entry.delete(); continue;
      }
      final confirmed = _revisions[rev.id];
      if (confirmed?.transferState == 'uploaded' && confirmed?.payloadHash == rev.payloadHash) {
        await file.delete(); await entry.delete(); continue;
      }
      if (!publish || confirmed != null) continue;
      if (await SaveSnapshot.hash(file) != rev.payloadHash) throw const FormatException('Pending save checksum mismatch');
      _check(epoch, scope);
      final result = await access.call('put', {'scope': scope, 'source': file.path, 'manifest': rev.toJson()});
      _check(epoch, scope);
      if (result['state'] == 'deleted') {
        _deleted.add(_deletedKey(rev.unitKey, rev.contentHash));
        await file.delete(); await entry.delete();
      }
      // Do not publish an optimistic "uploaded" state. The next coordinated
      // listing must confirm both the payload and its commit marker.
    }
  }
  static String _switchKey(GameModel game) => '${game.systemFolderName ?? game.systemId ?? "unknown"}/${game.romname}';
  bool _enabled(GameModel game) => (_overrides[_switchKey(game)] ?? game.cloudSyncEnabled ?? true);
  bool _belongs(NativeSaveUnit unit, GameModel game) {
    final system = (game.systemFolderName ?? game.systemId ?? '').toLowerCase();
    if (unit.emulator == 'DolphiniOS') {
      if (!(system == 'gc' && unit.system == 'GameCube' || system == 'wii' && unit.system == 'Wii')) return false;
      return unit.owner.startsWith('Shared') || unit.owner == sources.nativeIdentity(game);
    }
    if (unit.emulator == 'ARMSX2') return system == 'ps2' && (unit.owner == 'Shared' ||
      NativeSaveOwnership.ps2StateMatches(unit.source, romName: game.romname, gameName: game.name, titleId: game.titleId));
    if (unit.emulator == 'MeloNX') return system == 'switch' && NativeSaveOwnership.switchTitleMatches(game.titleId, unit.owner);
    if (unit.emulator == 'RPCS3') return system == 'ps3' && game.titleId?.isNotEmpty == true && unit.owner.toUpperCase().startsWith(game.titleId!.toUpperCase());
    if (unit.emulator == 'RetroArch') return unit.owner == p.basenameWithoutExtension(game.romname) || unit.title == game.name;
    // Explicit folder integrations are shared units, never attached to one game.
    return false;
  }
  void _state(GameModel game, GameSyncStatus state, {String? error}) {
    final value = GameSyncState(gameId: _switchKey(game), gameName: game.name, status: state,
      cloudEnabled: _enabled(game), errorMessage: error);
    _games[_switchKey(game)] = value;

  }
  @override Future<SyncResult> fullSync() => _backup();
  Future<SyncResult> _backup({GameModel? game}) async {
    if (_busy || gameIsRunning()) {
      if (_busy) _rescanRequested = true;
      if (game != null) _state(game, GameSyncStatus.pending);
      _notify(); return SyncResult.ok(message: 'Waiting for emulator files to close.');
    }
    if (!isAuthenticated) return SyncResult.fail(SyncError.authRequired, message: 'Authorize iCloud Drive first.');
    if (game != null && !_enabled(game)) { _state(game, GameSyncStatus.disabled); return SyncResult.ok(); }
    _busy = true; status = SyncProviderStatus.syncing; lastError = null; sourceWarnings.clear();
    final epoch = _epoch, scope = _scope;
    var changed = 0;
    try {
      try { await access.call('recoverRestores'); } catch (error) {
        sourceWarnings['Recovery'] = error.toString(); rethrow;
      }
      // An offline provider must not prevent a durable private snapshot.
      // Publishing may fail below, but the next startup retries the same outbox.
      try { await refresh(); } catch (error) { lastError = error.toString(); }
      _check(epoch, scope);
      final games = await loadGames();
      final disabledGames = games.where((g) => !_enabled(g)).toList();
      for (final knownGame in games) { await sources.remember(knownGame); }
      final discovery = await sources.discover();
      sourceWarnings.addAll(discovery.warnings);
      final root = await _outbox(scope);
      final localOutbox = <String, Set<String>>{};
      await for (final e in root.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        final revision = SaveRevision.fromJson(Map<String, dynamic>.from(jsonDecode(await e.readAsString()) as Map));
        localOutbox.putIfAbsent(revision.unitKey, () => {}).add(revision.contentHash);
      }
      final matched = <NativeSaveUnit>[];
      for (final unit in discovery.units) {
        // Scan every registered source after return as well as startup. Only
        // changed content creates a revision; rows retain their native identity
        // and modification date, not the name/date of the last played game.
        if (disabledGames.any((g) => _belongs(unit, g))) continue;
        _check(epoch, scope);
        if (gameIsRunning()) throw PlatformException(code: 'BUSY', message: 'Emulation started; remaining backups are deferred.');
        final temporary = File(p.join(root.path, '.snapshot-${DateTime.now().microsecondsSinceEpoch}'));
        try {
          final snapshot = await unit.snapshot(access, temporary);
          if (snapshot == null) continue;
          if (game == null || _belongs(unit, game)) matched.add(unit);
          _check(epoch, scope);
          if (_deleted.contains(_deletedKey(unit.key, snapshot.contentHash))) continue;
          if (_revisions.values.any((r) => r.unitKey == unit.key && r.contentHash == snapshot.contentHash) ||
              localOutbox[unit.key]?.contains(snapshot.contentHash) == true) continue;
          final revision = unit.revision(snapshot);
          final payload = File(p.join(root.path, '${revision.storageKey}.nssave'));
          await temporary.rename(payload.path);
          final manifest = File(p.join(root.path, '${revision.storageKey}.json'));
          final tmp = File('${manifest.path}.tmp');
          await tmp.writeAsString(jsonEncode(revision.toJson()), flush: true);
          await tmp.rename(manifest.path);
          localOutbox.putIfAbsent(unit.key, () => {}).add(revision.contentHash);
          changed++;
        } catch (error) { sourceWarnings['${unit.emulator}: ${unit.title}'] = error.toString(); }
        finally { if (await temporary.exists()) await temporary.delete(); }
      }
      _check(epoch, scope);
      await _drain(scope, epoch, publish: true);
      await refresh();
      if (game != null) {
        final adapter = switch (game.systemFolderName) { 'gc' || 'wii' => 'DolphiniOS',
          'ps2' => 'ARMSX2', 'switch' => 'MeloNX', 'ps3' => 'RPCS3', _ => 'RetroArch' };
        final failed = sourceWarnings.keys.any((k) => k == adapter || k.startsWith('$adapter:'));
        final relevant = _revisions.values.where((r) => matched.any((u) => u.key == r.unitKey));
        final waiting = relevant.isEmpty && matched.isNotEmpty || relevant.any((r) => r.transferState != 'uploaded');
        _state(game, failed ? GameSyncStatus.error : matched.isEmpty ? GameSyncStatus.noSaveFound :
          waiting ? GameSyncStatus.pending : GameSyncStatus.upToDate,
          error: failed ? sourceWarnings.values.join('\n') : null);
      }
      if (sourceWarnings.isNotEmpty) return SyncResult.fail(SyncError.unknown,
        message: '$changed new revisions; ${sourceWarnings.length} source(s) need attention.');
      return SyncResult.ok(message: '$changed new save revisions.', data: changed);
    } catch (error) {
      lastError = error.toString();
      if (game != null) _state(game, error is PlatformException && const {'PENDING', 'BUSY', 'CANCELLED'}.contains(error.code)
        ? GameSyncStatus.pending : GameSyncStatus.error, error: lastError);
      return SyncResult.fail(SyncError.unknown, message: lastError);
    } finally {
      _busy = false; status = isAuthenticated ? SyncProviderStatus.connected : SyncProviderStatus.disconnected; _notify();
      if (_rescanRequested && isAuthenticated && !gameIsRunning() && !_disposed) {
        _rescanRequested = false;
        unawaited(Future<void>(() async { await fullSync(); }));
      }
    }
  }
  /// Called on application startup/re-entry, not on a fictitious background
  /// event while another app owns the foreground.
  Future<void> onAppStart() async {
    try { await _connection(); if (isAuthenticated) await fullSync(); }
    catch (error) { lastError = error.toString(); _notify(); }
  }
  @override Future<SyncResult> syncGameSavesBeforeLaunch(GameModel game) async {
    await _restoring?.future;
    await sources.remember(game);
    // No automatic cloud -> native overwrite. Restore is an explicit action.
    return SyncResult.ok();
  }
  @override Future<SyncResult> syncGameSavesAfterClose(GameModel game) async {
    await sources.remember(game);
    return _backup(game: game);
  }
  @override Future<SyncResult> detectGameSaveFiles(GameModel game) async {
    if (!_enabled(game)) _state(game, GameSyncStatus.disabled);
    else if (_games[_switchKey(game)] == null) _state(game, GameSyncStatus.pending);
    _notify(); return SyncResult.ok();
  }
  @override GameSyncState? getGameSyncState(String gameId) => _games[gameId];
  @override Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {
    _overrides[gameId] = enabled;
    await (await SharedPreferences.getInstance()).setString('icloud_saves.game_switches.v1', jsonEncode(_overrides));
    _notify();
  }
  @override Future<List<SyncFile>> listSaves({String? gameId}) async {
    await refresh();
    return [for (final r in revisions) if (gameId == null || r.unitKey == gameId)
      SyncFile(id: r.id, fileName: r.owner, gameName: r.title, gameId: r.unitKey,
        fileSize: r.size, uploadedAt: r.modified, modifiedAt: r.modified, checksum: r.payloadHash)];
  }
  @override Future<SyncResult> uploadSave(String gameId, File file, {String? customFileName}) async {
    // No generic raw-path escape hatch: discovery owns what may be uploaded.
    return SyncResult.fail(SyncError.configInvalid, message: 'Use the registered emulator save adapter.');
  }
  @override Future<SyncResult> downloadSave(String gameId, String fileId) => restoreRevision(fileId);
  Future<SyncResult> restoreRevision(String id) async {
    if (_busy || gameIsRunning()) return SyncResult.fail(SyncError.conflictDetected, message: 'Close the game before restoring.');
    if (!isAuthenticated) return SyncResult.fail(SyncError.authRequired);
    final revision = _revisions[id];
    if (revision == null) return SyncResult.fail(SyncError.fileNotFound);
    _restoring = Completer<void>();
    _busy = true; _notify(); final epoch = _epoch, scope = _scope;
    File? payload;
    try {
      await access.call('recoverRestores');
      final discovery = await sources.discover();
      final unit = await sources.resolveRevision(revision, discovery.units);
      if (unit == null) throw const FileSystemException('Link the matching emulator save folder/profile before restoring.');
      final expected = await unit.currentFingerprint(access);
      _check(epoch, scope);
      final result = await access.call('get', {'scope': scope, 'path': revision.payloadPath, 'hash': revision.payloadHash});
      payload = File(result['path'] as String);
      _check(epoch, scope);
      if (gameIsRunning()) throw const FileSystemException('Close the game before restoring.');
      await unit.restore(access, payload, revision, expected: expected, scope: scope);
      return SyncResult.ok(message: 'Save restored. Previous native data was preserved.');
    } catch (error) { lastError = error.toString(); return SyncResult.fail(SyncError.conflictDetected, message: lastError); }
    finally {
      try { if (payload != null && await payload.exists()) await payload.delete(); }
      finally { _restoring?.complete(); _restoring = null; _busy = false; _notify(); }
    }
  }
  @override Future<SyncResult> deleteRemote(String fileId) async {
    if (_busy || !isAuthenticated || !_revisions.containsKey(fileId)) return SyncResult.fail(SyncError.configInvalid);
    final scope = _scope; _busy = true;
    try {
      final revision = _revisions[fileId]!;
      await access.call('trash', {'scope': scope, 'id': fileId});
      _deleted.add(_deletedKey(revision.unitKey, revision.contentHash));
      _revisions.removeWhere((_, r) => r.unitKey == revision.unitKey && r.contentHash == revision.contentHash);
      await refresh();
      return SyncResult.ok(message: 'Cloud revision moved to .Trash. Local saves are unchanged.');
    } catch (error) { return SyncResult.fail(SyncError.unknown, message: error.toString()); }
    finally { _busy = false; _notify(); }
  }
  @override Future<SyncQuota?> getQuota() async => null;
  @override void dispose() { _disposed = true; _epoch++; access.onAvailabilityChanged = null; super.dispose(); }
}
