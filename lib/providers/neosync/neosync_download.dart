part of '../neo_sync_provider.dart';

extension NeoSyncDownload on NeoSyncProvider {
  /// Auto-sync para descargas (archivos de la nube que no están localmente o son más nuevos)
  Future<void> autoSyncDownloads() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (_isSyncing) return;

    _setSyncing(true);
    _error = null;
    _syncProgress = 0.0;
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_0_0
    _processedNativeDownloads.clear();
// DOLPHIN_ISOLATION_END: neosync_repair205_0_0
    _syncStatus = 'Fetching cloud files...';
    _totalFiles = 0;
    _processedFiles = 0;
    _downloadedFiles = 0;
    _processedItems = [];
    notify();

    try {
      final result = await _neoSyncService.getFiles();
    // DOLPHIN_ISOLATION_BEGIN: dolphin_bulk_download
      await _syncAllDolphinGames(upload: false);
    // DOLPHIN_ISOLATION_END: dolphin_bulk_download

      if (!result['success']) {
        throw Exception('Failed to fetch cloud files: ${result['message']}');
      }

      final cloudFiles = result['files'] as List<NeoSyncFile>;
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_0_1
      _files = cloudFiles;
// DOLPHIN_ISOLATION_END: neosync_repair205_0_1
      if (cloudFiles.isEmpty) {
        _syncStatus = 'No cloud files found';
        _processedItems.add('No cloud files found for auto-sync');
        _setSyncing(false);
        return;
      }

      _totalFiles = cloudFiles.length;
      _processedItems.add('Auto-syncing $_totalFiles cloud files...');
      _syncStatus = 'Checking cloud files...';
      notify();

      // Collect RetroArch folders to resolve locally
      final savesPath = await _getRetroArchSavesPath();

      for (final cloudFile in cloudFiles) {
        await _processAutoDownloadFile(cloudFile, savesPath ?? '');
        _processedFiles++;
        _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
        notify();
      }

      _syncProgress = 1.0;
      _syncStatus =
          'Auto-download completed: $_downloadedFiles files downloaded';
      _processedItems.add(
        'Auto-download completed: $_downloadedFiles files downloaded',
      );
    } catch (e) {
      _error = 'Error during auto-sync download: $e';
      _syncStatus = 'Error: $_error';
      _processedItems.add('Auto-sync download error: $e');
      NeoSyncProvider._log.e('Auto-sync downloads error: $e');
    } finally {
      // DOLPHIN_ISOLATION_BEGIN: dolphin_bulk_status
      _finishDolphinBulkStatus();
      // DOLPHIN_ISOLATION_END: dolphin_bulk_status
      _setSyncing(false);
    }
  }

  /// Fase 2: Descargar archivos de la nube
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_0_2


// DOLPHIN_ISOLATION_END: neosync_repair205_0_2
  /// Procesa un archivo para auto-descarga (Universal)
  Future<void> _processAutoDownloadFile(
    NeoSyncFile cloudFile,
    String savesPath,
  ) async {
    // DOLPHIN_ISOLATION_BEGIN: dolphin_no_generic_download
    if (DolphinSaveTarget.ownsCloudPath(cloudFile.fileName) ||
        DolphinSaveTarget.ownsCloudPath(cloudFile.sourceSavePath)) return;
    // DOLPHIN_ISOLATION_END: dolphin_no_generic_download

    try {
      // DOLPHIN_ISOLATION_BEGIN: neosync_download_save_policy
if (cloudFile.saveKind != NeoSyncSaveKind.save) return;
      if (await _processNativeDirectoryDownload(cloudFile)) return;
      final parsed = NeoSyncSavePolicy.canonical(cloudFile.sourceSavePath);
// DOLPHIN_ISOLATION_END: neosync_download_save_policy
      if (Platform.isIOS &&
          parsed?.emulatorSlug == 'armsx2' &&
          parsed?.isShared == true) {
        final root = ConfigService.linkedArmsx2FolderPath;
        if (root == null || root.isEmpty) return;
        final localPath = _resolveArmsx2CloudFileToLocal(
          root,
          parsed!.filePath,
        );
        if (localPath == null) return;
        final localFile = File(localPath);
        final isMemoryCard = parsed.filePath.toLowerCase().startsWith(
          'memcards/',
        );
        if (isMemoryCard && localFile.existsSync()) {
          // Existing ARMSX2 cards are authoritative; stale mtimes are common.
          _skippedFiles++;
          return;
        }
        if (!localFile.existsSync()) {
          await localFile.parent.create(recursive: true);
          await _downloadCloudFileImpl(cloudFile, localFile);
          _downloadedFiles++;
        }
        return;
      }

      if (Platform.isIOS && parsed?.emulatorSlug == 'rpcs3') {
        final root = Rpcs3LibraryService.linkedDataPath;
        if (root == null || root.isEmpty) return;
        final localPath = _resolveRpcs3CloudFileToLocal(root, parsed!.filePath);
        if (localPath == null) return;
        final localFile = File(localPath);
        if (localFile.existsSync()) {
          final stat = await localFile.stat();
          if (cloudFile.checksum != null && cloudFile.checksum!.isNotEmpty) {
            final hash = _neoSyncService.calculateFileHash(
              await localFile.readAsBytes(),
            );
            if (hash == cloudFile.checksum) {
              _skippedFiles++;
              return;
            }
          }
          final cloudTime = cloudFile.fileModifiedAtTimestamp ?? 0;
          if (cloudTime <= stat.modified.millisecondsSinceEpoch) {
            _skippedFiles++;
            return;
          }
        } else {
          await localFile.parent.create(recursive: true);
        }
        await _downloadCloudFileImpl(cloudFile, localFile);
        _downloadedFiles++;
        _processedItems.add('RPCS3 restored: ${cloudFile.gameName}');
        return;
      }

      // 1. Resolve the game associated with the file
      GameModel? game = await _findGameForCloudFile(cloudFile);

      if (game == null) {
        NeoSyncProvider._log.w(
          'Could not identify game for cloud file: ${cloudFile.fileName}',
        );
        return;
      }

      // 2. Resolve local path using the universal system
      final localPaths = await resolveCloudFileToLocalPath(game, cloudFile);

      if (localPaths.isEmpty) return;

      for (final localPath in localPaths) {
        final localFile = File(localPath);
        if (localFile.existsSync()) {
          final localStat = await localFile.stat();
          if (cloudFile.uploadedAt.isAfter(localStat.modified)) {
            await _downloadCloudFileImpl(cloudFile, localFile);
            _downloadedFiles++;
            _processedItems.add('⬇️ Auto-updated: ${cloudFile.fileName}');
          } else {
            _skippedFiles++;
          }
        } else {
          await localFile.parent.create(recursive: true);
          await _downloadCloudFileImpl(cloudFile, localFile);
          _downloadedFiles++;
          _processedItems.add('✨ Auto-downloaded new: ${cloudFile.fileName}');
        }
      }
    } catch (e) {
      _processedItems.add('Error downloading ${cloudFile.fileName}: $e');
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_0_3
      _error = 'Native save download failed: $e';
// DOLPHIN_ISOLATION_END: neosync_repair205_0_3
    }
  }

  // DOLPHIN_ISOLATION_BEGIN: neosync_whole_directory_download
  Future<bool> _processNativeDirectoryDownload(NeoSyncFile cloudFile) async {
    final selected = NeoSyncSaveUnits.cloud(_files).where((unit) =>
        unit.members.any((file) => file.id == cloudFile.id));
    if (selected.length != 1) return false;
    final unit = selected.single;
    if (!unit.descriptor.isDirectory && unit.members.length <= 1) return false;
    if (!_processedNativeDownloads.add(unit.key)) return true;
    final game = await _findGameForCloudFile(cloudFile);
    if (game == null) throw StateError('Cannot identify the native save owner');
    final members = unit.members;
    final localUnits = NeoSyncSaveUnits.local(await _findGameSaveFiles(game));
    final localUnit = localUnits.where((local) => local.key == unit.key);
    final locals = localUnit.isEmpty ? <LocalSaveFile>[] : localUnit.single.members;
    final byIdentity = {for (final local in locals) _saveIdentity(local.relativePath): local};
    final cloudByIdentity = {for (final member in members) _saveIdentity(member.sourceSavePath): member};
    var needsDownload = false;
    for (final identity in {...byIdentity.keys, ...cloudByIdentity.keys}) {
      final status = await _calculateGameSyncStatus(byIdentity[identity], cloudByIdentity[identity]);
      if (status == neo_sync.GameSyncStatus.error) {
        throw StateError('Cannot verify every member of the native save');
      }
      if (status == neo_sync.GameSyncStatus.localOnly) {
        _skippedFiles += members.length;
        return true;
      }
      needsDownload |= status == neo_sync.GameSyncStatus.cloudOnly;
    }
    if (needsDownload) {
      await restoreCloudSaveUnit(members, game: game);
      _downloadedFiles += members.length;
    } else {
      _skippedFiles += members.length;
    }
    return true;
  }
  // DOLPHIN_ISOLATION_END: neosync_whole_directory_download

  /// Helper para encontrar el juego de un archivo de nube
  Future<GameModel?> _findGameForCloudFile(NeoSyncFile cloudFile) async {
    // DOLPHIN_ISOLATION_BEGIN: neosync_restore_original_path
final v2Path = NeoSyncSavePolicy.canonical(cloudFile.sourceSavePath);
// DOLPHIN_ISOLATION_END: neosync_restore_original_path
    if (v2Path != null &&
        v2Path.emulatorSlug == 'rpcs3' &&
        v2Path.gameName != null) {
      final parts = v2Path.filePath.split('/');
      final saveDirectory = parts.length >= 2 ? parts[1] : '';
      final titleId = _rpcs3TitleIdFromSaveDirectory(saveDirectory) ?? '';
      final cached = Rpcs3LibraryService.cachedGameForTitleId(titleId);
      final displayName = cached?.title.trim().isNotEmpty == true
          ? cached!.title.trim()
          : (cloudFile.gameName.trim().isNotEmpty
                ? cloudFile.gameName.trim()
                : v2Path.gameName!);
      return GameModel(
        name: displayName,
        realname: displayName,
        romname: titleId.isNotEmpty ? titleId : displayName,
        systemFolderName: 'ps3',
        systemId: 'ps3',
        year: '',
        developer: '',
        publisher: '',
        genre: '',
        players: '',
        rating: 0.0,
      ).copyWith(titleId: titleId.isEmpty ? null : titleId);
    }

    if (v2Path != null &&
        v2Path.emulatorSlug == 'melonx' &&
        v2Path.gameName != null) {
      final displayName = cloudFile.gameName.trim().isNotEmpty
          ? cloudFile.gameName.trim()
          : v2Path.gameName!;
      try {
        final row = await GameRepository.findSwitchGameByName(displayName);
        if (row != null) {
          final romname = row['filename'].toString();
          final title = row['title_name']?.toString();
          final titleId = row['title_id']?.toString();
          final romPath = row['rom_path']?.toString();
          return GameModel(
            name: (title == null || title.isEmpty) ? displayName : title,
            realname: (title == null || title.isEmpty) ? displayName : title,
            romname: romname,
            romPath: romPath,
            titleName: title,
            systemFolderName: 'switch',
            systemId: 'switch',
            year: '',
            developer: '',
            publisher: '',
            genre: '',
            players: '',
            rating: 0.0,
          ).copyWith(titleId: titleId);
        }
      } catch (e) {
        NeoSyncProvider._log.w(
          'Could not map MeloNX cloud save by game name: $e',
        );
      }
    }

    // DOLPHIN_ISOLATION_BEGIN: neosync_cloud_native_owner
    if (v2Path != null && !v2Path.isShared) {
      final serial = RegExp(r'(?:^|/)([A-Za-z]{4}[0-9]{5})[^/]*/')
          .firstMatch(v2Path.filePath)?[1]?.toUpperCase();
      final names = <String>{v2Path.gameName?.toLowerCase() ?? '', cloudFile.gameName.toLowerCase()};
      final rows = await GameRepository.loadGamesForSystem(v2Path.system);
      final matches = rows.where((row) =>
        (serial != null && (row.titleId?.toUpperCase() == serial || row.filename.toUpperCase().contains(serial))) ||
        names.contains(CloudPathBuilder.sanitizeGameName(GameModel.fromDatabaseModel(row).name).toLowerCase())).toList();
      if (matches.length == 1) return GameModel.fromDatabaseModel(matches.single);
    }
    // DOLPHIN_ISOLATION_END: neosync_cloud_native_owner

    if (v2Path != null && !v2Path.isShared) {
      final saveBase = path.basenameWithoutExtension(v2Path.filePath);
      try {
        // DOLPHIN_ISOLATION_BEGIN: neosync_structured_owner_guard
        if (saveBase.trim().isEmpty) return null;
        // DOLPHIN_ISOLATION_END: neosync_structured_owner_guard
        final row = await GameRepository.findRomByFilenamePrefix(saveBase);
        // DOLPHIN_ISOLATION_BEGIN: neosync_structured_owner_guard
        if (row != null && row['folder_name']?.toString().toLowerCase() ==
            v2Path.system.toLowerCase()) {
        // DOLPHIN_ISOLATION_END: neosync_structured_owner_guard
          final romname = row['filename'].toString();
          final title = row['title_name']?.toString();
          return GameModel(
            name: (title == null || title.isEmpty) ? romname : title,
            realname: (title == null || title.isEmpty) ? romname : title,
            romname: romname,
            systemFolderName: row['folder_name']?.toString() ?? v2Path.system,
            emulatorName: row['emulator_name']?.toString(),
            year: '',
            developer: '',
            publisher: '',
            genre: '',
            players: '',
            rating: 0.0,
          );
        }
      } catch (e) {
        NeoSyncProvider._log.w('Could not map v2 cloud save to local game: $e');
      }
    }

    // DOLPHIN_ISOLATION_BEGIN: neosync_structured_owner_guard
    final originalPath = cloudFile.sourceSavePath;
    final parts = originalPath.split('/');
    // DOLPHIN_ISOLATION_END: neosync_structured_owner_guard

    // Identify if it is a Switch file based on known prefixes
    final isSwitchPath =
        // DOLPHIN_ISOLATION_BEGIN: neosync_structured_owner_guard
        originalPath.startsWith('saves/switch/') ||
        originalPath.startsWith('saves/eden/') ||
        originalPath.startsWith('saves/citron/') ||
        originalPath.startsWith('saves/yuzu/') ||
        originalPath.startsWith('saves/suyu/') ||
        originalPath.startsWith('saves/sudachi/');
        // DOLPHIN_ISOLATION_END: neosync_structured_owner_guard

    if (isSwitchPath && parts.length >= 3) {
      final gameNameInPath = parts[2];
      try {
        final row = await GameRepository.findSwitchGameByName(gameNameInPath);
        if (row != null) {
          final romname = row['filename'].toString();
          final title = row['title_name']?.toString();
          final titleId = row['title_id']?.toString();
          final romPath = row['rom_path']?.toString();

          return GameModel(
            name: title ?? romname,
            realname: title ?? romname,
            romname: romname,
            romPath: romPath,
            titleName: title,
            systemFolderName: 'switch',
            systemId: 'switch',
            year: '',
            developer: '',
            publisher: '',
            genre: '',
            players: '',
            rating: 0.0,
          ).copyWith(titleId: titleId);
        }
      } catch (e) {
        NeoSyncProvider._log.e('Error finding Switch game by name: $e');
      }
    }

    {
      // DOLPHIN_ISOLATION_BEGIN: neosync_structured_owner_guard
      final name = path.basenameWithoutExtension(originalPath);
      if (name.trim().isEmpty) return null;
      // DOLPHIN_ISOLATION_END: neosync_structured_owner_guard
      // Attempt to search in DB
      try {
        final row = await GameRepository.findRomByFilenamePrefix(name);
        // DOLPHIN_ISOLATION_BEGIN: neosync_structured_owner_guard
        if (row != null && (v2Path == null ||
            row['folder_name']?.toString().toLowerCase() == v2Path.system.toLowerCase())) {
        // DOLPHIN_ISOLATION_END: neosync_structured_owner_guard
          final romname = row['filename'].toString();
          final title = row['title_name']?.toString();
          final sysFolder = row['folder_name']?.toString() ?? '';

          return GameModel(
            name: title ?? romname,
            realname: title ?? romname,
            romname: romname,
            systemFolderName: sysFolder,
            year: '',
            developer: '',
            publisher: '',
            genre: '',
            players: '',
            rating: 0.0,
          );
        }
      } catch (e) {
        NeoSyncProvider._log.e('Error finding game for file: $e');
      }
    }
    return null;
  }

  /// Descarga un archivo de la nube
  Future<void> _downloadCloudFileImpl(
    NeoSyncFile cloudFile,
    File localFile,
  ) async {
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

    // DOLPHIN_ISOLATION_BEGIN: neosync_verified_native_writer
    await _downloadCloudFile(cloudFile, localFile);
    // DOLPHIN_ISOLATION_END: neosync_verified_native_writer
  }

  /// Procesa descarga con detección de conflictos
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_0_4


// DOLPHIN_ISOLATION_END: neosync_repair205_0_4
  // DOLPHIN_ISOLATION_BEGIN: neosync_no_implicit_legacy_migration
  // Current synchronization uses v2. Do not silently re-upload guessed v1
  // objects from an unrelated historical deployment during a list refresh.
  // DOLPHIN_ISOLATION_END: neosync_no_implicit_legacy_migration
}
