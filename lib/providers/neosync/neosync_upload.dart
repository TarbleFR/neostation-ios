part of '../neo_sync_provider.dart';

extension NeoSyncUpload on NeoSyncProvider {
  /// Auto-sync solo para subidas (archivos locales nuevos o modificados)
  Future<void> autoSyncUploads() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (_isSyncing) return;

    _setSyncing(true);
    _error = null;
    _syncProgress = 0.0;
    _syncStatus = 'Auto-detecting local files...';
    _totalFiles = 0;
    _processedFiles = 0;
    _uploadedFiles = 0;
    _skippedFiles = 0;
    _downloadedFiles = 0;
    _processedItems = [];
    notify();

    try {
      final saveFiles = <File>[];

      // 1. Collect RetroArch files (Saves and States)
      final savesPath = await _getRetroArchSavesPath();
      List<File> retroArchSaves = [];
      if (savesPath != null) {
        retroArchSaves = await _getSaveFiles(savesPath);
      }

      final statesPath = await _getRetroArchStatesPath();
      List<File> retroArchStates = [];
      if (statesPath != null) {
        retroArchStates = await _getSaveFiles(statesPath);
      }

      final customSaveFiles =
          <
            ({
              File file,
              String root,
              String system,
              String emulatorSlug,
              bool isState,
            })
          >[];
      if (Platform.isIOS) {
        final armsx2Root = ConfigService.linkedArmsx2SaveFolderPath;
        if (armsx2Root != null && Directory(armsx2Root).existsSync()) {
          const categories = <String>['memcards', 'savestates', 'sstates'];
          final selectedName = path.basename(armsx2Root).toLowerCase();
          final roots = <({String folder, String category})>[];

          if (categories.contains(selectedName)) {
            roots.add((folder: armsx2Root, category: selectedName));
          } else {
            for (final category in categories) {
              final folder = path.join(armsx2Root, category);
              if (Directory(folder).existsSync()) {
                roots.add((folder: folder, category: category));
              }
            }
          }

          for (final rootInfo in roots) {
            final isState = rootInfo.category != 'memcards';
            for (final file in await _getSaveFiles(rootInfo.folder)) {
              customSaveFiles.add((
                file: file,
                root: armsx2Root,
                system: 'ps2',
                emulatorSlug: 'armsx2',
                isState: isState,
              ));
            }
          }
        }
        final melonxRoot = ConfigService.linkedMelonxSaveFolderPath;
        if (melonxRoot != null && Directory(melonxRoot).existsSync()) {
          for (final file in await _getSaveFiles(melonxRoot)) {
            customSaveFiles.add((
              file: file,
              root: melonxRoot,
              system: 'switch',
              emulatorSlug: 'melonx',
              isState: false,
            ));
          }
        }

        final rpcs3Root = Rpcs3LibraryService.linkedDataPath;
        if (rpcs3Root != null && Directory(rpcs3Root).existsSync()) {
          final home = Directory(path.join(rpcs3Root, 'dev_hdd0', 'home'));
          if (home.existsSync()) {
            for (final userDir
                in home.listSync(followLinks: false).whereType<Directory>()) {
              final savedata = Directory(path.join(userDir.path, 'savedata'));
              if (!savedata.existsSync()) continue;
              for (final file in await _getSaveFiles(savedata.path)) {
                customSaveFiles.add((
                  file: file,
                  root: rpcs3Root,
                  system: 'ps3',
                  emulatorSlug: 'rpcs3',
                  isState: false,
                ));
              }
            }
          }
        }
      }

      // 2. Collect Switch NAND files
      try {
        final emulators = await SwitchSaveDetector.detectEmulatorNandPaths();
        if (Platform.isAndroid) {
          // On Android, group by Title ID and take only the most recent
          final Map<String, List<MapEntry<File, String>>> savesByTitleId = {};

          for (final emulator in emulators) {
            final nandPath = emulator.nandDirectory;
            final savePath =
                '$nandPath${Platform.pathSeparator}user${Platform.pathSeparator}save${Platform.pathSeparator}0000000000000000';
            final saveDir = Directory(savePath);

            if (!await saveDir.exists()) {
              NeoSyncProvider._log.w(
                'Switch save dir not found for ${emulator.emulatorName}: $savePath',
              );
            }

            if (await saveDir.exists()) {
              NeoSyncProvider._log.d(
                'Scanning Switch saves for ${emulator.emulatorName}: $savePath',
              );
              final switchFiles = saveDir
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where((f) => !f.path.endsWith('.') && !f.path.endsWith('..'))
                  .toList();

              for (final file in switchFiles) {
                try {
                  final pathParts = file.path.split(Platform.pathSeparator);
                  final saveIndex = pathParts.indexOf('save');
                  if (saveIndex != -1 && saveIndex + 3 < pathParts.length) {
                    final titleId = pathParts[saveIndex + 3];
                    final relativePath = pathParts
                        .sublist(saveIndex + 4)
                        .join(Platform.pathSeparator);
                    final key = '$titleId/$relativePath';

                    if (!savesByTitleId.containsKey(key)) {
                      savesByTitleId[key] = [];
                    }
                    savesByTitleId[key]!.add(
                      MapEntry(file, emulator.emulatorName),
                    );
                  }
                } catch (e) {
                  saveFiles.add(file);
                }
              }
            }
          }

          for (final entry in savesByTitleId.entries) {
            final files = entry.value;
            if (files.length == 1) {
              saveFiles.add(files.first.key);
            } else {
              File? mostRecent;
              DateTime? mostRecentDate;
              for (final fileEntry in files) {
                final file = fileEntry.key;
                final lastModified = await file.lastModified();
                if (mostRecent == null ||
                    lastModified.isAfter(mostRecentDate!)) {
                  mostRecent = file;
                  mostRecentDate = lastModified;
                }
              }
              if (mostRecent != null) saveFiles.add(mostRecent);
            }
          }
        } else {
          // Desktop Switch saves
          for (final emulator in emulators) {
            final nandPath = emulator.nandDirectory;
            final savePath =
                '$nandPath${Platform.pathSeparator}user${Platform.pathSeparator}save${Platform.pathSeparator}0000000000000000';
            final saveDir = Directory(savePath);
            if (await saveDir.exists()) {
              final switchFiles = saveDir
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where((f) => !f.path.endsWith('.') && !f.path.endsWith('..'))
                  .toList();
              saveFiles.addAll(switchFiles);
            }
          }
        }
      } catch (e) {
        NeoSyncProvider._log.e('Error scanning Switch NAND saves: $e');
      }

      if (retroArchSaves.isEmpty &&
          retroArchStates.isEmpty &&
          customSaveFiles.isEmpty &&
          saveFiles.isEmpty) {
        _syncStatus = 'No local save files found';
        _processedItems.add('No local save files found for auto-sync');
        _setSyncing(false);
        return;
      }

      _totalFiles =
          retroArchSaves.length +
          retroArchStates.length +
          customSaveFiles.length +
          saveFiles.length; // saveFiles contains Switch files here

      _processedItems.add('Auto-syncing $_totalFiles local files...');
      _syncStatus = 'Checking files for upload...';
      notify();

      // Process RetroArch Saves
      for (final file in retroArchSaves) {
        await _processAutoUploadFile(file, savesPath!, isState: false);
        _processedFiles++;
        _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
        notify();
      }

      // Process RetroArch States
      for (final file in retroArchStates) {
        await _processAutoUploadFile(file, statesPath!, isState: true);
        _processedFiles++;
        _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
        notify();
      }

      // Process iOS standalone-emulator save roots.
      for (final entry in customSaveFiles) {
        await _processAutoUploadFile(
          entry.file,
          entry.root,
          isState: entry.isState,
          customSystem: entry.system,
          customEmulatorSlug: entry.emulatorSlug,
        );
        _processedFiles++;
        _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
        notify();
      }

      // Process the rest (Switch, etc.)
      for (final file in saveFiles) {
        await _processAutoUploadFile(file, file.parent.path, isState: false);
        _processedFiles++;
        _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
        notify();
      }

      _syncProgress = 1.0;
      _syncStatus =
          'Auto-upload completed: $_uploadedFiles uploaded, $_skippedFiles already synced';
      _processedItems.add(
        'Auto-upload completed: $_uploadedFiles uploaded, $_skippedFiles already synced',
      );
    } catch (e) {
      if (e is QuotaExceededException) {
        _error = 'Storage quota exceeded after ${e.attemptCount} attempts';
        _syncStatus = 'Quota exceeded - Auto-sync disabled';
        _processedItems.add('Storage quota exceeded - sync stopped');
      } else {
        _error = 'Error during auto-sync: $e';
        _syncStatus = 'Error: $_error';
        _processedItems.add('Auto-sync error: $e');
      }
    } finally {
      _setSyncing(false);
    }
  }

  /// Fase 1: Subir archivos locales
  Future<void> _performUploadPhase(String basePath) async {
    _syncStatus = 'Phase 1: Uploading local files...';
    _processedItems.add('📤 Phase 1: Scanning and uploading local files...');
    notify();

    // Determine if it is a states folder for RetroArch
    final statesPath = await _getRetroArchStatesPath();
    final isState = statesPath != null && path.equals(basePath, statesPath);

    final saveFiles = await _getSaveFiles(basePath);
    if (saveFiles.isEmpty) {
      _processedItems.add('No local files found in ${path.basename(basePath)}');
      return;
    }

    _totalFiles = saveFiles.length * 2;
    _processedItems.add('📤 Found ${saveFiles.length} local files to process');

    for (final file in saveFiles) {
      await _processUploadFileWithConflictDetection(
        file,
        basePath,
        isState: isState,
      );
      _processedFiles++;
      _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
      notify();
    }
  }

  /// Procesa un archivo para auto-subida (versión optimizada)
  Future<void> _processAutoUploadFile(
    File file,
    String basePath, {
    bool isState = false,
    String? customSystem,
    String? customEmulatorSlug,
  }) async {
    try {
      final isNandFile = file.path.contains(
        '${Platform.pathSeparator}nand${Platform.pathSeparator}user${Platform.pathSeparator}save',
      );

      if (isNandFile) {
        await _handleSwitchNandAutoUpload(file);
        return;
      }

      if (customSystem == 'ps2' && customEmulatorSlug == 'armsx2') {
        await _uploadArmsx2File(file, basePath);
        return;
      }

      if (customSystem == 'switch' && customEmulatorSlug == 'melonx') {
        await _uploadMeloNXFile(file, basePath);
        return;
      }

      if (customSystem == 'ps3' && customEmulatorSlug == 'rpcs3') {
        await _uploadRpcs3File(file, basePath);
        return;
      }

      if (customSystem != null && customEmulatorSlug != null) {
        final relativeFile = path
            .relative(file.path, from: basePath)
            .replaceAll('\\', '/');
        if (relativeFile.startsWith('..')) {
          _skippedFiles++;
          return;
        }
        final cloudPath = CloudPathBuilder.build(
          system: customSystem,
          emulatorSlug: customEmulatorSlug,
          scope: 'shared',
          filePath: relativeFile,
          isState: isState,
        );
        final result = await _neoSyncService.syncFile(
          file,
          _extractGameNameFromPath(file.path),
          customFilename: cloudPath,
          systemId: customSystem,
          emulatorId: customEmulatorSlug,
          isState: isState,
          scope: 'shared',
        );
        if (result['success'] == true) {
          if (result['skipped'] == true) {
            _skippedFiles++;
          } else {
            _uploadedFiles++;
            _resetQuotaAttempts();
          }
          _processedItems.add('NeoSync: $cloudPath');
        } else {
          final errorMessage = result['message']?.toString() ?? '';
          _processedItems.add('Failed to upload: $cloudPath - $errorMessage');
          if (_checkQuotaExceeded(errorMessage)) {
            _quotaExceededActive = true;
            throw QuotaExceededException(errorMessage, _quotaExceededAttempts);
          }
        }
        return;
      }

      final game = await _gameForSaveFile(file);
      if (game == null) {
        _skippedFiles++;
        _processedItems.add(
          'Skipped unrecognized save (NeoSync v2 safety): ${path.basename(file.path)}',
        );
        return;
      }

      final relativePath = await _calculateSyncRelativePath(
        game,
        file,
        basePath,
        isState: isState,
      );
      final v2Path = CloudPathBuilder.parse(relativePath);
      if (v2Path == null) {
        _skippedFiles++;
        _processedItems.add('Skipped non-v2 path: $relativePath');
        return;
      }

      final result = await _neoSyncService.syncFile(
        file,
        game.name,
        customFilename: relativePath,
        systemId: v2Path.system,
        emulatorId: v2Path.emulatorSlug,
        isState: v2Path.isState,
        scope: v2Path.scope,
      );

      if (result['success']) {
        if (result['skipped'] == true) {
          _skippedFiles++;
          _processedItems.add('⏭️ Already synced: $relativePath');
        } else {
          _uploadedFiles++;
          _processedItems.add('📤 Auto-uploaded: $relativePath');
          _resetQuotaAttempts();
        }
      } else {
        final errorMessage = result['message'] ?? '';
        _processedItems.add('Failed to upload: $relativePath - $errorMessage');
        if (_checkQuotaExceeded(errorMessage)) {
          _quotaExceededActive = true;
          throw QuotaExceededException(errorMessage, _quotaExceededAttempts);
        }
      }
    } catch (e) {
      if (e is! QuotaExceededException) {
        _processedItems.add('Error processing ${path.basename(file.path)}: $e');
      } else {
        rethrow;
      }
    }
  }

  /// Uploads ARMSX2 memory cards and states from the three supported iOS
  /// folders. The rest of the ARMSX2 root (BIOS, cache, covers, logs, etc.) is
  /// deliberately excluded from NeoSync.
  Future<bool> _uploadArmsx2File(
    File file,
    String root, {
    GameModel? preferredGame,
  }) async {
    final resolved = _resolveArmsx2FileForCloud(file, root);
    if (resolved == null) {
      _skippedFiles++;
      return false;
    }

    final preferredGameName = preferredGame?.name.trim();
    final displayGameName =
        preferredGameName != null && preferredGameName.isNotEmpty
        ? '$preferredGameName — ${resolved.isState ? 'Save State' : 'Memory Card'}'
        : resolved.gameName;

    final isMemoryCard =
        resolved.category == 'memcards' &&
        file.path.toLowerCase().endsWith('.ps2');
    File uploadFile = file;
    Directory? tempDir;

    try {
      if (isMemoryCard) {
        final rawBytes = await file.readAsBytes();
        final compressedBytes = gzip.encode(rawBytes);
        tempDir = await Directory.systemTemp.createTemp('neosync-armsx2-card-');
        uploadFile = File(
          path.join(tempDir.path, '${path.basename(file.path)}.neosync.gz'),
        );
        await uploadFile.writeAsBytes(compressedBytes, flush: true);
        _processedItems.add(
          'ARMSX2 memory card detected: ${path.basename(file.path)} '
          '(${rawBytes.length} B → ${compressedBytes.length} B)',
        );
      }

      final result = await _neoSyncService.syncFile(
        uploadFile,
        displayGameName,
        customFilename: resolved.cloudPath,
        systemId: 'ps2',
        emulatorId: 'armsx2',
        isState: resolved.isState,
        scope: 'shared',
        contentHashOnly: isMemoryCard,
      );

      if (result['success'] == true) {
        if (result['skipped'] == true) {
          _skippedFiles++;
        } else {
          _uploadedFiles++;
          _resetQuotaAttempts();
        }
        _processedItems.add('NeoSync: $displayGameName');
        return true;
      }

      final errorMessage = result['message']?.toString() ?? '';
      _processedItems.add('Failed to upload $displayGameName: $errorMessage');
      if (_checkQuotaExceeded(errorMessage)) {
        _quotaExceededActive = true;
        throw QuotaExceededException(errorMessage, _quotaExceededAttempts);
      }
      return false;
    } finally {
      if (tempDir != null) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Uploads one constituent file from a native RPCS3 PS3 save-data folder.
  /// The technical PS3 profile/save directory is preserved in the cloud path,
  /// while NeoSync exposes the human-readable game title.
  Future<bool> _uploadRpcs3File(
    File file,
    String dataRoot, {
    GameModel? preferredGame,
  }) async {
    final resolved = await _resolveRpcs3FileForCloud(
      file,
      dataRoot,
      preferredGame: preferredGame,
    );
    if (resolved == null) {
      _skippedFiles++;
      return false;
    }

    final result = await _neoSyncService.syncFile(
      file,
      resolved.gameName,
      customFilename: resolved.cloudPath,
      systemId: 'ps3',
      emulatorId: 'rpcs3',
      isState: false,
      scope: 'game',
    );

    if (result['success'] == true) {
      if (result['skipped'] == true) {
        _skippedFiles++;
      } else {
        _uploadedFiles++;
        _resetQuotaAttempts();
      }
      _processedItems.add('NeoSync RPCS3: ${resolved.gameName}');
      return true;
    }

    final errorMessage = result['message']?.toString() ?? '';
    _processedItems.add('Failed to upload ${resolved.gameName}: $errorMessage');
    if (_checkQuotaExceeded(errorMessage)) {
      _quotaExceededActive = true;
      throw QuotaExceededException(errorMessage, _quotaExceededAttempts);
    }
    return false;
  }

  /// Uploads one MeloNX file using Title ID only to identify the local game.
  /// The NeoSync-visible path and game_name use the human-readable game title.
  Future<bool> _uploadMeloNXFile(
    File file,
    String root, {
    GameModel? preferredGame,
  }) async {
    final resolved = await _resolveMeloNXFileForCloud(
      file,
      root,
      preferredGame: preferredGame,
    );
    if (resolved == null) {
      _skippedFiles++;
      return false;
    }

    final result = await _neoSyncService.syncFile(
      file,
      resolved.gameName,
      customFilename: resolved.cloudPath,
      systemId: 'switch',
      emulatorId: 'melonx',
      isState: false,
      scope: 'game',
    );

    if (result['success'] == true) {
      if (result['skipped'] == true) {
        _skippedFiles++;
      } else {
        _uploadedFiles++;
        _resetQuotaAttempts();
      }
      _processedItems.add('NeoSync: ${resolved.gameName}');
      return true;
    }

    final errorMessage = result['message']?.toString() ?? '';
    _processedItems.add('Failed to upload ${resolved.gameName}: $errorMessage');
    if (_checkQuotaExceeded(errorMessage)) {
      _quotaExceededActive = true;
      throw QuotaExceededException(errorMessage, _quotaExceededAttempts);
    }
    return false;
  }

  /// Maneja la subida automática de archivos de Switch NAND
  Future<void> _handleSwitchNandAutoUpload(File file) async {
    try {
      final pathParts = file.path.split(Platform.pathSeparator);
      final saveIndex = pathParts.indexOf('save');
      if (saveIndex != -1 && saveIndex + 3 < pathParts.length) {
        final titleId = pathParts[saveIndex + 3];

        final row = await GameRepository.findSwitchGameByTitleId(titleId);

        if (row == null) {
          NeoSyncProvider._log.w(
            'Switch upload skipped: titleId "$titleId" not found in DB (${file.path})',
          );
          _processedItems.add(
            '⚠️ No game matched titleId $titleId — skipping upload',
          );
          return;
        }

        {
          final romname = row['filename'].toString();
          final titleName = row['title_name']?.toString();
          final game = GameModel(
            name: titleName ?? romname,
            realname: titleName ?? romname,
            romname: romname,
            systemFolderName: 'switch',
            year: '',
            developer: '',
            publisher: '',
            genre: '',
            players: '',
            rating: 0.0,
            titleId: titleId,
          );

          final relativePath = await calculateSwitchRelativePath(file, game);
          final result = await _neoSyncService.syncFile(
            file,
            game.name,
            customFilename: relativePath,
          );

          if (result['success']) {
            if (result['skipped'] == true) {
              _skippedFiles++;
              _processedItems.add('⏭️ Already synced: $relativePath');
            } else {
              _uploadedFiles++;
              _processedItems.add('📤 Auto-uploaded: $relativePath');
              _resetQuotaAttempts();
            }
          } else {
            final errorMessage = result['message'] ?? '';
            _processedItems.add(
              'Failed to upload: $relativePath - $errorMessage',
            );
            if (_checkQuotaExceeded(errorMessage)) {
              _quotaExceededActive = true;
              throw QuotaExceededException(
                errorMessage,
                _quotaExceededAttempts,
              );
            }
          }
        }
      }
    } catch (e) {
      NeoSyncProvider._log.e('Error processing Switch NAND file: $e');
    }
  }

  /// Procesa subida con detección de conflictos
  Future<void> _processUploadFileWithConflictDetection(
    File file,
    String basePath, {
    bool isState = false,
  }) async {
    try {
      final game = await _gameForSaveFile(file);
      if (game == null) {
        _skippedFiles++;
        _processedItems.add(
          'Skipped unrecognized save (NeoSync v2 safety): ${path.basename(file.path)}',
        );
        return;
      }

      final relativePath = await _calculateSyncRelativePath(
        game,
        file,
        basePath,
        isState: isState,
      );
      final v2Path = CloudPathBuilder.parse(relativePath);
      if (v2Path == null) {
        _skippedFiles++;
        _processedItems.add('Skipped non-v2 path: $relativePath');
        return;
      }

      final result = await _neoSyncService.syncFile(
        file,
        game.name,
        customFilename: relativePath,
        systemId: v2Path.system,
        emulatorId: v2Path.emulatorSlug,
        isState: v2Path.isState,
        scope: v2Path.scope,
      );

      if (result['success']) {
        if (result['skipped'] == true) {
          _skippedFiles++;
          _processedItems.add('⏭️ Already synced: $relativePath');
        } else {
          _uploadedFiles++;
          _processedItems.add('📤 Uploaded: $relativePath');
          _resetQuotaAttempts();
        }
      } else {
        final errorMessage = result['message'] ?? '';
        _processedItems.add('Failed to upload: $relativePath - $errorMessage');
        if (_checkQuotaExceeded(errorMessage)) {
          _quotaExceededActive = true;
          throw QuotaExceededException(errorMessage, _quotaExceededAttempts);
        }
      }
    } catch (e) {
      if (e is! QuotaExceededException) {
        _processedItems.add('Error processing ${path.basename(file.path)}: $e');
      } else {
        rethrow;
      }
    }
  }
}
