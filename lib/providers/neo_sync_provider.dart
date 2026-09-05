// DOLPHIN_ISOLATION_BEGIN: neosync_imports
import 'dart:async';
import '../services/dolphin_internal_v2_service.dart';
import '../services/dolphin_neosync_store.dart';
import '../services/dolphin_system_files.dart';
import '../services/neosync/neo_sync_save_policy.dart';
import '../services/neosync/neo_sync_cloud_cleanup.dart';
import '../services/neosync/neo_sync_restore_transaction.dart';
import '../services/neosync/neo_sync_status_rules.dart';
import '../models/neo_sync_save_units.dart';
import 'package:crypto/crypto.dart' as saveCrypto;
// DOLPHIN_ISOLATION_END: neosync_imports
import 'package:flutter/material.dart';

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;
import 'package:neostation/services/logger_service.dart';

import '../services/neosync/neo_sync_service.dart';
import '../services/neosync/legacy_neo_sync_service.dart';
import '../services/neosync/auth_service.dart';
import '../models/neo_sync_models.dart';
import '../widgets/quota_exceeded_dialog.dart';
import '../models/neo_sync_models.dart' as neo_sync;
import '../models/system_model.dart';
import '../models/game_model.dart';
import '../utils/switch_save_detector.dart';
import '../utils/switch_title_extractor.dart';
import '../repositories/system_repository.dart';
import '../repositories/sync_repository.dart';
import '../repositories/game_repository.dart';
import '../repositories/emulator_repository.dart';
import '../services/config_service.dart';
import '../services/armsx2_folder_service.dart';
import '../services/retroarch_config_service.dart';
import '../services/rpcs3_library_service.dart';
import '../utils/cloud_path_builder.dart';

part 'neosync/neosync_exceptions.dart';
part 'neosync/neosync_status.dart';
part 'neosync/neosync_path_resolver.dart';
part 'neosync/neosync_upload.dart';
part 'neosync/neosync_download.dart';
part 'neosync/neosync_core.dart';
// DOLPHIN_ISOLATION_BEGIN: neosync_part
part 'neosync/neosync_dolphin.dart';
part 'neosync/neosync_save_audit.dart';
// DOLPHIN_ISOLATION_END: neosync_part

/// Provider responsible for managing the NeoSync cloud save synchronization service.
///
/// Coordinates background synchronization, conflict resolution, storage quota
/// tracking, and per-game sync status. Splitted into multiple part files to
/// manage the complexity of filesystem resolution and network operations.
class NeoSyncProvider extends ChangeNotifier {
  /// Local cache of user files currently stored in the cloud.
  List<NeoSyncFile> _onlineFiles = [];

  /// Whether a network request to fetch the cloud file list is active.
  bool _isLoadingOnlineFiles = false;

  List<NeoSyncFile> get onlineFiles => _onlineFiles;
  bool get isLoadingOnlineFiles => _isLoadingOnlineFiles;

  static final _log = LoggerService.instance;

  /// Optional reference to [AuthService] for credential verification.
  AuthService? _authService;

  /// Low-level network service for NeoSync API interactions.
  final NeoSyncService _neoSyncService;
  final LegacyNeoSyncService _legacyNeoSyncService = LegacyNeoSyncService();

  NeoSyncProvider(this._neoSyncService);
  // DOLPHIN_ISOLATION_BEGIN: neosync_queue
  Future<void> _dolphinSyncTail = Future<void>.value();
  int _dolphinBulkChecked = 0;
  int _dolphinBulkErrors = 0;
  final DolphinSaveTitleCache _dolphinTitles = DolphinSaveTitleCache();
  String? _saveAuditMessage;
  bool _saveAuditInProgress = false;
  final Set<String> _processedNativeDownloads = {};
  String? get saveAuditMessage => _saveAuditMessage;
  // DOLPHIN_ISOLATION_END: neosync_queue

  /// Whether a global synchronization task is currently active.
  bool _isSyncing = false;

  /// Overall progress of the current sync operation (0.0 to 1.0).
  double _syncProgress = 0.0;

  /// Human-readable status message for the sync operation.
  String _syncStatus = '';

  /// Total number of files identified for processing in the current task.
  int _totalFiles = 0;

  /// Count of files that have been analyzed (scanned).
  int _processedFiles = 0;

  /// Count of files successfully uploaded to the cloud.
  int _uploadedFiles = 0;

  /// Count of files skipped (already up to date).
  int _skippedFiles = 0;

  /// Count of files successfully downloaded from the cloud.
  int _downloadedFiles = 0;

  /// History of item identifiers processed in the current session.
  List<String> _processedItems = [];

  /// Whether background synchronization is globally enabled.
  bool _autoSyncEnabled = true;

  /// Whether a background (non-interactive) sync is currently active.
  bool _isAutoSyncing = false;

  /// Consecutive failed upload attempts due to storage quota limits.
  int _quotaExceededAttempts = 0;

  /// Whether the user has already been notified of a quota issue in the current session.
  bool _quotaExceededDialogShown = false;

  /// Global flag indicating that a quota limit was recently hit.
  bool _quotaExceededActive = false;

  /// Real-time synchronization state for individual games, keyed by unique ID.
  final Map<String, neo_sync.GameSyncState> _gameSyncStates = {};

  /// Cache of local save file metadata, grouped by game.
  final Map<String, List<LocalSaveFile>> _gameLocalSaves = {};

  /// Cache of cloud save file metadata, grouped by game.
  final Map<String, List<NeoSyncFile>> _gameCloudSaves = {};

  /// Set of platform-specific files (e.g., PS2 memory cards, Switch user saves) already handled.
  final Set<String> _processedMultiEmulatorFilesInSession = {};

  /// Identifier of the game ROM currently targeted for per-game sync UI.
  String? _selectedGameRomname;

  /// Human-readable name of the game currently targeted.
  String? _selectedGameName;

  /// All metadata for files discovered during the sync process.
  List<NeoSyncFile> _files = [];

  /// Current user's storage quota and usage metadata.
  NeoSyncQuota? _quota;

  /// Last error message encountered during synchronization.
  String? _error;

  // Getters
  bool get isSyncing => _isSyncing;
  double get syncProgress => _syncProgress;
  String get syncStatus => _syncStatus;
  int get totalFiles => _totalFiles;
  int get processedFiles => _processedFiles;
  int get uploadedFiles => _uploadedFiles;
  int get skippedFiles => _skippedFiles;
  int get downloadedFiles => _downloadedFiles;
  List<String> get processedItems => _processedItems;

  bool get autoSyncEnabled => _autoSyncEnabled;
  bool get isAutoSyncing => _isAutoSyncing;

  int get quotaExceededAttempts => _quotaExceededAttempts;
  bool get quotaExceededDialogShown => _quotaExceededDialogShown;

  String? get error => _error;
  NeoSyncQuota? get quota => _quota;
  List<NeoSyncFile> get files => _files;
  bool get isLoading => false;

  /// Retrieves the current sync state for a specific game.
  neo_sync.GameSyncState? getGameSyncState(String gameId) =>
      _gameSyncStates[gameId];

  /// Returns the list of local save files detected for a specific game.
  List<LocalSaveFile> getGameLocalSaves(String gameId) =>
      _gameLocalSaves[gameId] ?? [];

  /// Returns the list of cloud save files found for a specific game.
  List<NeoSyncFile> getGameCloudSaves(String gameId) =>
      _gameCloudSaves[gameId] ?? [];

  // DOLPHIN_ISOLATION_BEGIN: neosync_native_units
  List<NeoSyncLocalSaveUnit> getGameLocalSaveUnits(String gameId) =>
      NeoSyncSaveUnits.local(getGameLocalSaves(gameId));

  List<NeoSyncCloudSaveUnit> getGameCloudSaveUnits(String gameId) =>
      NeoSyncSaveUnits.cloud(getGameCloudSaves(gameId));

  bool _supportsNeoSync(SystemModel system) =>
      NeoSyncSavePolicy.supportsSystem(system.folderName, system.neosync.sync);

  /// Source ownership comes from the configured emulator folders, never from
  /// a ROM title or a filename extension alone.
  Future<NeoSyncSaveSource?> _sourceForLocalFile(File file) async {
    final roots = <({String? root, NeoSyncSaveFamily family})>[
      (root: ConfigService.linkedArmsx2FolderPath, family: NeoSyncSaveFamily.armsx2),
      (root: Rpcs3LibraryService.linkedDataPath, family: NeoSyncSaveFamily.rpcs3),
      (root: ConfigService.linkedMelonxSaveFolderPath, family: NeoSyncSaveFamily.melonx),
      (root: await _getRetroArchStatesPath(), family: NeoSyncSaveFamily.retroArchStates),
      (root: await _getRetroArchSavesPath(), family: NeoSyncSaveFamily.retroArchSaves),
      (root: await _flycastSystemSaveRoot(), family: NeoSyncSaveFamily.retroArchFlycastSystem),
    ];
    for (final entry in roots) {
      if (entry.root == null || entry.root!.isEmpty) continue;
      if (!path.isWithin(entry.root!, file.path)) continue;
      return NeoSyncSaveSource.resolve(
        filePath: file.path, rootPath: entry.root!, family: entry.family,
      );
    }
    return null;
  }
  Future<String?> _flycastSystemSaveRoot() async {
    final system = await _getRetroArchSystemPath();
    return system == null ? null : path.join(system, 'dc');
  }
  // DOLPHIN_ISOLATION_END: neosync_native_units

  /// Internal bridge to allow [part] files to trigger UI updates.
  void notify() {
    notifyListeners();
  }

  /// Internal helper to update the global sync state.
  void _setSyncing(bool syncing) {
    _isSyncing = syncing;
    notifyListeners();
  }

  /// Internal helper to update the background sync state.
  void _setAutoSyncing(bool autoSyncing) {
    _isAutoSyncing = autoSyncing;
    notifyListeners();
  }

  /// Derives a game identifier or title from its filesystem path.
  String _extractGameNameFromPath(String filePath) {
    final fileName = path.basename(filePath);
    if (fileName.contains('.')) {
      return fileName.substring(0, fileName.lastIndexOf('.'));
    }
    return fileName;
  }

  /// Analyzes an error message to determine if it represents a storage quota violation.
  ///
  /// Increments failure counters if a quota issue is detected.
  bool _checkQuotaExceeded(String errorMessage) {
    final lowerMessage = errorMessage.toLowerCase();
    if (lowerMessage.contains('quota') ||
        lowerMessage.contains('storage') ||
        lowerMessage.contains('413') ||
        lowerMessage.contains('full')) {
      _quotaExceededAttempts++;
      return true;
    }
    return false;
  }

  /// Resets quota-related failure counters and status flags.
  void _resetQuotaAttempts() {
    _quotaExceededAttempts = 0;
    _quotaExceededActive = false;
  }

  /// Downloads one cloud save for an explicit user export.
  ///
  /// NeoSync stores some payloads as `.neosync.gz`; exports must contain the
  /// original emulator save bytes so the archive is independently recoverable.
  Future<List<int>> downloadOnlineFileBytes(NeoSyncFile cloudFile) async {
    final result = LegacyNeoSyncService.isLegacyId(cloudFile.id)
        ? await _legacyNeoSyncService.downloadFile(cloudFile.id)
        : await _neoSyncService.downloadFile(cloudFile.id);
    if (result['success'] != true || result['data'] == null) {
      throw Exception(result['message'] ?? 'Failed to download file');
    }
    final rawData = result['data'];
    if (rawData is! List) {
      throw const FormatException('NeoSync returned invalid file data');
    }
    final bytes = List<int>.from(rawData);
    // DOLPHIN_ISOLATION_BEGIN: neosync_verified_payload
    final expectedHash = cloudFile.checksum?.trim().toLowerCase();
    if (expectedHash != null && expectedHash.isNotEmpty &&
        _neoSyncService.calculateFileHash(bytes) != expectedHash) {
      throw StateError('NeoSync download checksum mismatch: ${cloudFile.displayName}');
    }
    if (cloudFile.fileSize > 0 && bytes.length != cloudFile.fileSize) {
      throw StateError('NeoSync download is incomplete: ${cloudFile.displayName}');
    }
    // DOLPHIN_ISOLATION_END: neosync_verified_payload
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_0
    return (cloudFile.fileName.toLowerCase().endsWith('.neosync.gz') ||
        cloudFile.sourceSavePath.toLowerCase().endsWith('.neosync.gz'))
// DOLPHIN_ISOLATION_END: neosync_repair205_0
        ? gzip.decode(bytes)
        : bytes;
  }

  /// Downloads a file from NeoSync storage and writes it to the local filesystem.
  ///
  /// Upon successful download, it synchronizes the local database sync state
  /// to match the cloud version.
  Future<void> _downloadCloudFile(NeoSyncFile cloudFile, File localFile) async {
// DOLPHIN_ISOLATION_BEGIN: neosync_save_only_restore
    if (cloudFile.saveKind != NeoSyncSaveKind.save) {
      throw StateError('NeoSync refuses to restore an unverified save');
    }

// DOLPHIN_ISOLATION_END: neosync_save_only_restore
    // DOLPHIN_ISOLATION_BEGIN: dolphin_download_writer
    if (DolphinSaveTarget.ownsCloudPath(cloudFile.fileName) ||
        DolphinSaveTarget.ownsCloudPath(cloudFile.sourceSavePath)) {
      await _restoreDolphinCloud(cloudFile); return;
    }
    // DOLPHIN_ISOLATION_END: dolphin_download_writer

    // DOLPHIN_ISOLATION_BEGIN: neosync_staged_write
    final account = _dolphinAccount;
    await NeoSyncRestoreTransaction.restore([
      NeoSyncRestoreEntry(destination: localFile,
        root: await _restoreRoot(cloudFile, localFile),
        loadVerifiedBytes: () => downloadOnlineFileBytes(cloudFile),
        modified: cloudFile.fileModifiedAt),
    ], isCurrentAccount: () => isNeoSyncAuthenticated && _dolphinAccount == account);
    // DOLPHIN_ISOLATION_END: neosync_staged_write

    try {
      final stat = await localFile.stat();
      await SyncRepository.saveSyncState(
        localFile.path,
        stat.modified.millisecondsSinceEpoch,
        cloudFile.fileModifiedAtTimestamp ?? 0,
        stat.size,
        fileHash: cloudFile.checksum,
      );
    } catch (e) {
      _log.w('Could not save sync state for ${localFile.path}: $e');
    }
  }

  // DOLPHIN_ISOLATION_BEGIN: neosync_native_restore
  Future<Directory> _restoreRoot(NeoSyncFile cloud, File destination) async {
    final parsed = NeoSyncSavePolicy.canonical(cloud.sourceSavePath);
    final String? root;
    if (Platform.isIOS && parsed?.emulatorSlug == 'armsx2') {
      root = ConfigService.linkedArmsx2FolderPath;
    } else if (Platform.isIOS && parsed?.emulatorSlug == 'rpcs3') {
      root = Rpcs3LibraryService.linkedDataPath;
    } else if (Platform.isIOS && parsed?.emulatorSlug == 'melonx') {
      root = ConfigService.linkedMelonxSaveFolderPath;
    } else if (parsed?.system == 'dc' && parsed?.filePath.startsWith('system/dc/') == true) {
      root = await _flycastSystemSaveRoot();
    } else {
      root = parsed?.isState == true || cloud.sourceSavePath.startsWith('states/')
          ? await _getRetroArchStatesPath() : await _getRetroArchSavesPath();
    }
    if (root == null || !path.isWithin(root, destination.path)) {
      throw StateError('NeoSync destination is outside the linked save folder');
    }
    return Directory(root);
  }

  /// Restores all members as one operation, preserving their native paths.
  /// No destination changes until every download has been checked.
  Future<void> restoreCloudSaveUnit(List<NeoSyncFile> members, {GameModel? game}) async {
    if (!isNeoSyncAuthenticated) throw StateError('NeoSync authentication required');
    if (members.isEmpty) return;
    final units = NeoSyncSaveUnits.cloud(members);
    if (units.length != 1) throw StateError('Select one native save at a time');
    final account = _dolphinAccount;
    final entries = <NeoSyncRestoreEntry>[];
    final byDestination = <String, List<NeoSyncFile>>{};
    final targets = <({NeoSyncFile cloud, File file})>[];
    for (final cloud in members) {
      if (cloud.saveKind != NeoSyncSaveKind.save) {
        throw StateError('NeoSync refuses an unverified save');
      }
      if (cloud.dolphinTarget != null) {
        if (members.length != 1) throw StateError('Invalid Dolphin save unit');
        await _restoreDolphinCloud(cloud);
        return;
      }
      final owner = game ?? await _findGameForCloudFile(cloud);
      if (owner == null) throw StateError('Cannot identify the owner of this save');
      final destinations = await resolveCloudFileToLocalPath(owner, cloud);
      if (destinations.isEmpty) throw StateError('The native save folder is unavailable');
      for (final target in destinations) {
        final file = File(target);
        final identity = path.normalize(file.absolute.path);
        final duplicates = byDestination.putIfAbsent(identity, () => []);
        duplicates.add(cloud);
        if (duplicates.length > 1) continue;
        entries.add(NeoSyncRestoreEntry(destination: file,
          root: await _restoreRoot(cloud, file), modified: cloud.fileModifiedAt,
          loadVerifiedBytes: () async {
            final bytes = await downloadOnlineFileBytes(duplicates.first);
            final hash = saveCrypto.sha256.convert(bytes);
            for (final duplicate in duplicates.skip(1)) {
              final other = await downloadOnlineFileBytes(duplicate);
              if (other.length != bytes.length || saveCrypto.sha256.convert(other) != hash) {
                throw StateError('Conflicting cloud copies of one native save member');
              }
            }
            return bytes;
          }));
        targets.add((cloud: cloud, file: file));
      }
    }
    await NeoSyncRestoreTransaction.restore(entries,
      isCurrentAccount: () => isNeoSyncAuthenticated && _dolphinAccount == account);
    for (final target in targets) {
      final stat = await target.file.stat();
      await SyncRepository.saveSyncState(target.file.path,
        stat.modified.millisecondsSinceEpoch,
        target.cloud.fileModifiedAtTimestamp ?? 0, stat.size,
        fileHash: target.cloud.checksum);
    }
  }
  // DOLPHIN_ISOLATION_END: neosync_native_restore

  /// Resolves the [SystemModel] associated with a specific game.
  ///
  /// Performs a database lookup if system metadata is missing from the [GameModel].
  Future<SystemModel?> _getSystemForGame(GameModel game) async {
    try {
      String? folderName = game.systemFolderName;

      folderName ??= await GameRepository.getSystemFolderForGame(game.romname);

      if (folderName == null) return null;

      try {
        return await SystemRepository.getSystemByFolderName(folderName);
      } catch (e) {
        _log.e('System $folderName not found in database: $e');
        return null;
      }
    } catch (e) {
      _log.e('Error getting system for game: $e');
    }
    return null;
  }
}
