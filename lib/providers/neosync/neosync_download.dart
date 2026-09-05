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
  Future<void> _performDownloadPhase(String savesPath) async {
    _syncStatus = 'Phase 2: Downloading cloud files...';
    _processedItems.add('⬇️ Phase 2: Downloading files from cloud...');
    notify();

    final result = await _neoSyncService.getFiles();
    if (!result['success']) {
      throw Exception('Failed to fetch cloud files: ${result['message']}');
    }

    final cloudFiles = result['files'] as List<NeoSyncFile>;
    if (cloudFiles.isEmpty) {
      _processedItems.add('No cloud files found');
      return;
    }

    _processedItems.add('⬇️ Found ${cloudFiles.length} cloud files to process');

    for (final cloudFile in cloudFiles) {
      await _processDownloadFileWithConflictDetection(cloudFile, savesPath);
      _processedFiles++;
      _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
      notify();
    }
  }

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
    }
  }

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

    if (v2Path != null && !v2Path.isShared) {
      final saveBase = path.basenameWithoutExtension(v2Path.filePath);
      try {
        final row = await GameRepository.findRomByFilenamePrefix(saveBase);
        if (row != null) {
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

    final parts = cloudFile.fileName.split('/');

    // Identify if it is a Switch file based on known prefixes
    final isSwitchPath =
        cloudFile.fileName.startsWith('saves/switch/') ||
        cloudFile.fileName.startsWith('saves/eden/') ||
        cloudFile.fileName.startsWith('saves/citron/') ||
        cloudFile.fileName.startsWith('saves/yuzu/') ||
        cloudFile.fileName.startsWith('saves/suyu/') ||
        cloudFile.fileName.startsWith('saves/sudachi/');

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
      final name = path.basenameWithoutExtension(cloudFile.fileName);
      // Attempt to search in DB
      try {
        final row = await GameRepository.findRomByFilenamePrefix(name);
        if (row != null) {
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

    final result = LegacyNeoSyncService.isLegacyId(cloudFile.id)
        ? await _legacyNeoSyncService.downloadFile(cloudFile.id)
        : await _neoSyncService.downloadFile(cloudFile.id);
    if (result['success'] == true && result['data'] != null) {
      final bytes = result['data'] as List<int>;
      final payload = cloudFile.fileName.toLowerCase().endsWith('.neosync.gz')
          ? gzip.decode(bytes)
          : bytes;
      await localFile.writeAsBytes(payload);

      // Save the actual local sync state in the database.
      // This avoids the "Operation not permitted" error on Android 11+ when trying
      // to change the timestamp with setLastModified.
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
        NeoSyncProvider._log.w(
          'Could not save sync state for ${localFile.path}: $e',
        );
      }
    } else {
      throw Exception(result['message'] ?? 'Failed to download file');
    }
  }

  /// Procesa descarga con detección de conflictos
  Future<void> _processDownloadFileWithConflictDetection(
    NeoSyncFile cloudFile,
    String savesPath,
  ) async {
    // DOLPHIN_ISOLATION_BEGIN: dolphin_no_generic_download
    if (DolphinSaveTarget.ownsCloudPath(cloudFile.fileName) ||
        DolphinSaveTarget.ownsCloudPath(cloudFile.sourceSavePath)) return;
    // DOLPHIN_ISOLATION_END: dolphin_no_generic_download

    GameModel? game = await _findGameForCloudFile(cloudFile);
    if (game == null) return;

    final localPaths = await resolveCloudFileToLocalPath(game, cloudFile);

    if (localPaths.isEmpty) return;

    for (final localPath in localPaths) {
      final localFile = File(localPath);
      if (localFile.existsSync()) {
        final localStat = await localFile.stat();
        if (cloudFile.uploadedAt.isAfter(localStat.modified)) {
          await _downloadCloudFileImpl(cloudFile, localFile);
          _downloadedFiles++;
          _processedItems.add('⬇️ Updated: ${cloudFile.fileName}');
        } else {
          _skippedFiles++;
        }
      } else {
        await localFile.parent.create(recursive: true);
        await _downloadCloudFileImpl(cloudFile, localFile);
        _downloadedFiles++;
        _processedItems.add('✨ Downloaded: ${cloudFile.fileName}');
      }
    }
  }

  /// Copies recognizable NeoSync v1 files into the v2 namespace.
  ///
  /// This is intentionally non-destructive: the historical object remains in
  /// v1. Files that cannot be mapped to a local game/emulator are skipped and
  /// remain visible through the legacy bridge.
  Future<Set<String>> _migrateLegacyFilesToV2(
    List<NeoSyncFile> legacyFiles,
  ) async {
    final migrated = <String>{};

    for (final legacyFile in legacyFiles) {
      if (!LegacyNeoSyncService.isLegacyId(legacyFile.id)) continue;
// DOLPHIN_ISOLATION_BEGIN: neosync_legacy_save_policy
      if (NeoSyncSavePolicy.classify(legacyFile.sourceSavePath) != NeoSyncSaveKind.save) continue;
// DOLPHIN_ISOLATION_END: neosync_legacy_save_policy
      Directory? tempDir;
      try {
        final game = await _findGameForCloudFile(legacyFile);
        final system = game?.systemFolderName?.trim();
        final emulatorId = game?.emulatorName?.trim();
        if (game == null ||
            system == null ||
            system.isEmpty ||
            emulatorId == null ||
            emulatorId.isEmpty) {
          continue;
        }

        final emulatorSlug = CloudPathBuilder.slugFromEmulatorUniqueId(
          emulatorId,
        );
        if (emulatorSlug.isEmpty || emulatorSlug == 'standalone') continue;

        final downloaded = await _legacyNeoSyncService.downloadFile(
          legacyFile.id,
        );
        if (downloaded['success'] != true || downloaded['data'] == null) {
          continue;
        }

        final bytes = downloaded['data'] as List<int>;
        final fileName = path.basename(legacyFile.fileName);
        if (fileName.isEmpty) continue;
        final lowerName = fileName.toLowerCase();
        final systemLower = system.toLowerCase();
        final isState = legacyFile.fileName.startsWith('states/');
        final isShared =
            (systemLower == 'ps2' && lowerName.endsWith('.ps2')) ||
            ((systemLower == 'dc' || systemLower == 'dreamcast') &&
                lowerName.contains('vmu_save'));

        final v2Name = CloudPathBuilder.build(
          system: system,
          emulatorSlug: emulatorSlug,
          scope: isShared ? 'shared' : 'game',
          gameName: isShared
              ? null
              : path.basenameWithoutExtension(legacyFile.fileName),
          filePath: fileName,
          isState: isState,
        );

        tempDir = await Directory.systemTemp.createTemp('neosync-v1-migrate-');
        final tempFile = File(path.join(tempDir.path, fileName));
        await tempFile.parent.create(recursive: true);
        await tempFile.writeAsBytes(bytes, flush: true);
        try {
          await tempFile.setLastModified(
            legacyFile.fileModifiedAt ?? legacyFile.uploadedAt,
          );
        } catch (_) {}

        final result = await _neoSyncService.syncFile(
          tempFile,
          game.name,
          customFilename: v2Name,
          systemId: system,
          emulatorId: emulatorSlug,
          isState: isState,
          scope: isShared ? 'shared' : 'game',
        );
        if (result['success'] == true) {
          migrated.add(legacyFile.id);
        }
      } catch (e) {
        NeoSyncProvider._log.w(
          'NeoSync v1 migration skipped ${legacyFile.fileName}: $e',
        );
      } finally {
        if (tempDir != null) {
          try {
            await tempDir.delete(recursive: true);
          } catch (_) {}
        }
      }
    }

    return migrated;
  }
}
