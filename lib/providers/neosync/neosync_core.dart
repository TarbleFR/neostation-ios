part of '../neo_sync_provider.dart';

extension NeoSyncCore on NeoSyncProvider {
  Future<void> updateSelectedGame(
    String romname,
    Future<GameModel?> Function(String romname) findGameModelByRomName,
  ) async {
    // Updates the internal state of the selected game
    _selectedGameRomname = romname;

    // Get the game model to store the name
    final gameModel = await findGameModelByRomName(romname);
    _selectedGameName = gameModel?.name ?? romname;

    // If the game does not exist in the map, add it
    if (!_gameSyncStates.containsKey(romname)) {
      _gameSyncStates[romname] = neo_sync.GameSyncState(
        gameId: romname,
        gameName: _selectedGameName!,
        status: neo_sync.GameSyncStatus.noSaveFound,
        cloudEnabled: true,
        localSave: null,
        cloudSave: null,
        lastSync: null,
        errorMessage: null,
      );
    }
    // Checks the sync state for the selected game
    await checkSelectedGameSaveStatus(findGameModelByRomName);
    notify();
  }

  /// Checks the synchronization state only for the selected game
  Future<void> checkSelectedGameSaveStatus(
    Future<GameModel?> Function(String romname) findGameModelByRomName,
  ) async {
    // Clear multi-emulator files tracking for new check (PS2 and Switch shared memory cards/saves)
    _processedMultiEmulatorFilesInSession.clear();

    if (_selectedGameRomname == null) {
      _syncStatus = 'No selected game for status check';
      _processedItems.add('No selected game for NeoSync save status check');
      NeoSyncProvider._log.w('No selected game for NeoSync save status check');
      notify();
      return;
    }

    final selectedGameState = _gameSyncStates[_selectedGameRomname];
    if (selectedGameState != null) {
      // Find the game model (GameModel) using the romname
      final selectedGameModel = await findGameModelByRomName(
        _selectedGameRomname!,
      );
      if (selectedGameModel != null) {
        // Only checks the state, does not sync
        await _checkGameSaveStatus(selectedGameModel);
        _syncStatus = 'Checked save status for selected game';
        _processedItems.add(
          'Checked save status for: ${selectedGameState.gameName}',
        );
        notify();
        return;
      } else {
        _syncStatus = 'Selected game model not found';
        _processedItems.add('Selected game model not found for status check');
        NeoSyncProvider._log.w(
          'Selected game model not found for status check',
        );
        notify();
        return;
      }
    }
    _syncStatus = 'No selected game for status check';
    _processedItems.add('No selected game for NeoSync save status check');
    NeoSyncProvider._log.w('No selected game for NeoSync save status check');
    notify();
    return;
  }

  /// Only checks the synchronization state for a game (no sync actions)
  Future<void> _checkGameSaveStatus(GameModel game) async {
    // DOLPHIN_ISOLATION_BEGIN: dolphin_status
    if (_isDolphinGame(game)) { await _syncDolphinGame(game, perform: false); return; }
    // DOLPHIN_ISOLATION_END: dolphin_status

    // DOLPHIN_ISOLATION_BEGIN: neosync_all_save_status
    try {
      final locals = await _findGameSaveFiles(game);
      final clouds = await _getCloudSaveFilesForGame(game);
      final status = await _aggregateGameSyncStatus(locals, clouds);
      final current = _gameSyncStates[game.romname];
      _updateGameSyncState(
        game.romname,
        game.name,
        current?.status == neo_sync.GameSyncStatus.quotaExceeded || _quotaExceededActive
            ? neo_sync.GameSyncStatus.quotaExceeded : status,
        localSave: locals.isEmpty ? null : locals.first,
        cloudSave: clouds.isEmpty ? null : clouds.first,
      );
    } catch (error) {
      _updateGameSyncState(game.romname, game.name, neo_sync.GameSyncStatus.error,
          errorMessage: 'Cannot check save synchronization: $error');
    }
    // DOLPHIN_ISOLATION_END: neosync_all_save_status
  }

  void setAuthService(AuthService authService) {
    _authService = authService;
    notify();
  }

  bool get isNeoSyncAuthenticated {
    return _authService?.isLoggedIn == true;
  }

  /// Unified synchronization: Uploads and downloads with automatic resolution
  // DOLPHIN_ISOLATION_BEGIN: neosync_all_emulator_full_sync
  Future<void> syncWithConflictResolution() async {
    if (!isNeoSyncAuthenticated || _isSyncing || _isAutoSyncing) return;
    _setAutoSyncing(true);
    try {
      // These phases discover all linked native roots, including Dolphin,
      // even when no RetroArch save directory is linked.
      await autoSyncUploads();
      if (_error != null) return;
      await autoSyncDownloads();
    } finally {
      _setAutoSyncing(false);
    }
  }
  // DOLPHIN_ISOLATION_END: neosync_all_emulator_full_sync

  /// Steam-style auto-sync: Detects and synchronizes files automatically
  Future<void> autoSync() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (_isSyncing || _isAutoSyncing) return;

    _setAutoSyncing(true);
    try {
      await autoSyncUploads();
      await autoSyncDownloads();
    } finally {
      _setAutoSyncing(false);
    }
  }

  /// Stops the ongoing synchronization
  void stopSyncing() {
    _isSyncing = false;
    _syncStatus = 'Sync stopped by user';
    // Defer the notification to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notify();
    });
  }

  void clearError() {
    _error = null;
    // Defer the notification to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notify();
    });
  }

  /// Enables or disables auto-sync
  void setAutoSyncEnabled(bool enabled) {
    _autoSyncEnabled = enabled;
    notify();
  }

  /// Runs auto-sync before starting a game (Steam-style)
  Future<void> syncBeforeGameStart() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (!_autoSyncEnabled) return;

    _processedItems.add('🎮 Syncing saves before game start...');
    await autoSync();
  }

  /// Runs auto-sync after closing a game (Steam-style)
  Future<void> syncAfterGameEnd() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (!_autoSyncEnabled) return;

    _processedItems.add('🎮 Syncing saves after game end...');
    await autoSyncUploads(); // Only upload local changes after the game
  }

  /// Runs only download auto-sync when initializing the app
  Future<void> syncOnAppStart() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (!_autoSyncEnabled) return;

    _processedItems.add('🚀 Checking for cloud updates on app start...');
    await autoSyncDownloads(); // Only download on initialization
  }

  /// Resets the state of the quota exceeded dialog
  void resetQuotaExceededDialog() {
    _quotaExceededDialogShown = false;
    _quotaExceededAttempts = 0;
    _quotaExceededActive = false; // Also reset the global flag
  }

  /// Shows the quota exceeded dialog
  Future<String?> showQuotaExceededDialog(BuildContext context) async {
    if (_quotaExceededDialogShown) return null;

    _quotaExceededDialogShown = true;
    notify();

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => QuotaExceededDialog(
        quota: _quota!,
        attemptCount: _quotaExceededAttempts,
        onUpgradePlan: () {
          // Navigate to the plan upgrade screen (not yet implemented).
        },
        onManageFiles: () {
          // Navigate to the file management screen (not yet implemented).
        },
      ),
    );
  }

  /// Gets all local saves with their synchronization state
  Future<List<LocalSaveFile>> getLocalSaveFiles() async {
    // DOLPHIN_ISOLATION_BEGIN: dolphin_global_save_list
    final dolphinFiles = await _allDolphinLocalSaves();
    if (Platform.isIOS && await _getRetroArchSavesPath() == null) return dolphinFiles;
    // DOLPHIN_ISOLATION_END: dolphin_global_save_list
    final savesPath = await _getRetroArchSavesPath();
    if (savesPath == null) {
      NeoSyncProvider._log.w('RetroArch saves directory not found');
      return [];
    }

    final saveFiles = await _getSaveFiles(savesPath);
    final localSaveFiles = <LocalSaveFile>[];

    // Create a map of synced files by name for quick comparison
    final syncedFilesMap = <String, NeoSyncFile>{};
    for (final syncedFile in _files) {
      // Normalize separators for consistent comparison
      final normalizedFileName = syncedFile.fileName.replaceAll('\\', '/');
      syncedFilesMap[normalizedFileName] = syncedFile;
    }

    for (final file in saveFiles) {
      try {
        final stat = await file.stat();
        final fileName = file.path.split(Platform.pathSeparator).last;
        final gameName = _extractGameNameFromPath(file.path);

        // Calculate the full relative path (same as used for uploading)
        String relativePath = '';
        final normalizedFilePath = file.path.replaceAll('\\', '/');
        final normalizedSavesPath = savesPath.replaceAll('\\', '/');

        final savesPathWithSeparator = normalizedSavesPath.endsWith('/')
            ? normalizedSavesPath
            : '$normalizedSavesPath/';

        if (normalizedFilePath.startsWith(savesPathWithSeparator)) {
          relativePath = normalizedFilePath.substring(
            savesPathWithSeparator.length,
          );
        } else {
          relativePath = fileName;
        }

        // Normalizar separadores para comparación consistente
        relativePath = relativePath.replaceAll('\\', '/');

        // DOLPHIN_ISOLATION_BEGIN: neosync_local_content_confirmation
        final syncedFile = syncedFilesMap[relativePath];
        final isSynced = syncedFile?.checksum != null &&
            _neoSyncService.calculateFileHash(await file.readAsBytes()) == syncedFile!.checksum;
        // DOLPHIN_ISOLATION_END: neosync_local_content_confirmation

        localSaveFiles.add(
          LocalSaveFile(
            filePath: file.path,
            fileName: fileName,
            fileSize: stat.size,
            lastModified: stat.modified,
            gameName: gameName,
            isSynced: isSynced,
            relativePath: relativePath,
          ),
        );
      } catch (e) {
        NeoSyncProvider._log.w(
          'Error processing local save file ${file.path}: $e',
        );
      }
    }

    // DOLPHIN_ISOLATION_BEGIN: dolphin_append_local_saves
    localSaveFiles.addAll(dolphinFiles);
    // DOLPHIN_ISOLATION_END: dolphin_append_local_saves
    // Ordenar por fecha de modificación (más recientes primero)
    localSaveFiles.sort((a, b) => b.lastModified.compareTo(a.lastModified));

    return localSaveFiles;
  }

  // ==========================================
  // MÉTODOS PARA SINCRONIZACIÓN POR JUEGO
  // ==========================================

  /// Detecta automáticamente archivos de guardado para un juego específico
  /// y realiza sincronización automática cuando es apropiado
  Future<void> detectGameSaveFiles(GameModel game) async {
    // DOLPHIN_ISOLATION_BEGIN: dolphin_detect
    if (_isDolphinGame(game)) { await _syncDolphinGame(game); return; }
    // DOLPHIN_ISOLATION_END: dolphin_detect

    // A shared PS2/DC card may have changed since the previous game session.
    // Never carry the processed marker across independent detections.
    _processedMultiEmulatorFilesInSession.clear();

    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (game.cloudSyncEnabled != true) {
      // Si el sync está deshabilitado para este juego, no hacer nada
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.disabled,
      );
      return;
    }

    // Verificar si el sistema tiene sync deshabilitado
    final system = await _getSystemForGame(game);
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_0
    if (system != null && !_supportsNeoSync(system)) {
// DOLPHIN_ISOLATION_END: neosync_repair205_0
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.disabled,
      );
      return;
    }

    // PRIMERO: Actualizar estado a "checking/syncing" para mostrar feedback visual inmediato
    _updateGameSyncState(
      game.romname,
      game.name,
      neo_sync.GameSyncStatus.syncing,
    );

    try {
      // Identificar si es un sistema de "memory cards compartidas"
      final system = await _getSystemForGame(game);
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_1

// DOLPHIN_ISOLATION_END: neosync_repair205_1
      // Verificar si hay configuración de emulador válida en Windows
      if (system != null && Platform.isWindows) {
        bool hasValidEmulator = true;

        if (system.id == 'switch') {
          final emulatorsList =
              await EmulatorRepository.getStandaloneEmulatorsBySystemId(
                'switch',
              );
          hasValidEmulator = false;

          // Revisar primero el seleccionado por el usuario
          for (final emu in emulatorsList) {
            if (emu['is_user_default'].toString() == '1') {
              final path = emu['emulator_path']?.toString();
              if (path != null && path.trim().isNotEmpty) {
                hasValidEmulator = true;
              }
              break;
            }
          }

          // Si no hay de usuario, revisar el default del sistema
          if (!hasValidEmulator &&
              !emulatorsList.any(
                (e) => e['is_user_default'].toString() == '1',
              )) {
            for (final emu in emulatorsList) {
              if (emu['is_default'].toString() == '1') {
                final path = emu['emulator_path']?.toString();
                if (path != null && path.trim().isNotEmpty) {
                  hasValidEmulator = true;
                }
                break;
              }
            }
          }
        } else {
          // Para RetroArch y otros sistemas, verificar si las rutas se pueden resolver.
          final resolvedPaths = await resolveUniversalPaths(
            system,
            game: game,
            ensureExists: false,
          );
          if (resolvedPaths.isEmpty) {
            hasValidEmulator = false;
          }
        }

        if (!hasValidEmulator) {
          NeoSyncProvider._log.w(
            'No valid emulator path configured for ${system.realName} in Windows, marking as missingEmulator',
          );
          _updateGameSyncState(
            game.romname,
            game.name,
            neo_sync.GameSyncStatus.missingEmulator,
          );
          return;
        }
      }

      // DOLPHIN_ISOLATION_BEGIN: neosync_native_unit_sync
      final locals = await _findGameSaveFiles(game);
      final clouds = await _getCloudSaveFilesForGame(game);
      _gameLocalSaves[game.romname] = locals;
      _gameCloudSaves[game.romname] = clouds;
      final localUnits = {for (final unit in NeoSyncSaveUnits.local(locals)) unit.key: unit};
      final cloudUnits = {for (final unit in NeoSyncSaveUnits.cloud(clouds)) unit.key: unit};
      var failed = false;
      var quotaFailed = false;
      for (final key in {...localUnits.keys, ...cloudUnits.keys}) {
        final localMembers = localUnits[key]?.members ?? <LocalSaveFile>[];
        final cloudMembers = cloudUnits[key]?.members ?? <NeoSyncFile>[];
        final localByKey = {for (final file in localMembers) _saveIdentity(file.relativePath): file};
        final cloudByKey = {for (final file in cloudMembers) _saveIdentity(file.sourceSavePath): file};
        if (cloudUnits[key]?.hasConflictingMembers == true) {
          failed = true;
          continue;
        }
        var needsUpload = false;
        var needsDownload = false;
        var comparisonFailed = false;
        for (final identity in {...localByKey.keys, ...cloudByKey.keys}) {
          final status = await _calculateGameSyncStatus(localByKey[identity], cloudByKey[identity]);
          needsUpload |= status == neo_sync.GameSyncStatus.localOnly;
          needsDownload |= status == neo_sync.GameSyncStatus.cloudOnly;
          comparisonFailed |= status == neo_sync.GameSyncStatus.error;
        }
        if (comparisonFailed) { failed = true; continue; }
        try {
          if (needsUpload) {
            // The existing local directory is authoritative as a unit. Do not
            // restore an older remote companion over a different local member.
            for (final member in localMembers) {
              if (!await _autoUploadLocalSave(game, member)) failed = true;
            }
          } else if (needsDownload) {
            await restoreCloudSaveUnit(cloudMembers, game: game);
          }
        } on QuotaExceededException {
          quotaFailed = true;
          failed = true;
        } catch (error) {
          failed = true;
          NeoSyncProvider._log.w('Native save synchronization failed: $error');
        }
      }
      final listing = await _neoSyncService.getFiles();
      if (listing['success'] != true) throw StateError('Cannot confirm NeoSync synchronization');
      _publishCloudInventory(listing['files'] as List<NeoSyncFile>);
      final verifiedLocals = await _findGameSaveFiles(game);
      final verifiedClouds = await _getCloudSaveFilesForGame(game);
      _gameLocalSaves[game.romname] = verifiedLocals;
      _gameCloudSaves[game.romname] = verifiedClouds;
      final verified = await _aggregateGameSyncStatus(verifiedLocals, verifiedClouds);
      final status = verified == neo_sync.GameSyncStatus.upToDate ? verified
          : _quotaExceededActive || quotaFailed ? neo_sync.GameSyncStatus.quotaExceeded
          : failed ? neo_sync.GameSyncStatus.error : verified;
      _updateGameSyncState(game.romname, game.name, status,
        localSave: verifiedLocals.isEmpty ? null : verifiedLocals.first,
        cloudSave: verifiedClouds.isEmpty ? null : verifiedClouds.first,
        errorMessage: failed ? 'A native save could not be synchronized completely' : null);
      // DOLPHIN_ISOLATION_END: neosync_native_unit_sync
    } catch (e) {
      NeoSyncProvider._log.w('Error detecting saves for ${game.name}: $e');
      _updateGameSyncState(
        game.romname,
        game.name,
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_2
        neo_sync.GameSyncStatus.error,
// DOLPHIN_ISOLATION_END: neosync_repair205_2
      );
    }
  }

  /// Obtiene el nombre del ROM sin extensión para comparación con archivos de save
  String _getRomNameWithoutExtension(String romname) {
    // Remover la extensión del archivo si existe
    if (romname.contains('.')) {
      return romname.substring(0, romname.lastIndexOf('.'));
    }
    return romname;
  }

  Future<bool> _autoUploadLocalSave(
    GameModel game,
    LocalSaveFile localSave,
  ) async {
    try {
      final file = File(localSave.filePath);
      if (!file.existsSync()) return false;

      // 1. Obtener el sistema para resolver sus rutas JSON
      final system = await _getSystemForGame(game);
      if (system == null) return false;

      // Verificar si el sistema tiene sync deshabilitado
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_3
      if (!_supportsNeoSync(system)) {
// DOLPHIN_ISOLATION_END: neosync_repair205_3
        return false;
      }

      final rpcs3Root = Rpcs3LibraryService.linkedDataPath;
      if (Platform.isIOS &&
          system.folderName.toLowerCase() == 'ps3' &&
          rpcs3Root != null &&
          rpcs3Root.isNotEmpty &&
          path.isWithin(rpcs3Root, file.path)) {
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_4
        return await _uploadRpcs3File(file, rpcs3Root, preferredGame: game, contentHashOnly: true);
// DOLPHIN_ISOLATION_END: neosync_repair205_4
      }

      final armsx2Root = ConfigService.linkedArmsx2FolderPath;
      if (Platform.isIOS &&
          system.folderName.toLowerCase() == 'ps2' &&
          armsx2Root != null &&
          armsx2Root.isNotEmpty &&
          path.isWithin(armsx2Root, file.path)) {
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_5
        return await _uploadArmsx2File(file, armsx2Root, preferredGame: game, contentHashOnly: true);
// DOLPHIN_ISOLATION_END: neosync_repair205_5
      }

      // MeloNX on iOS stores saves below a Title-ID directory. Use that ID
      // only for local matching, while the cloud keeps the readable game name.
      final melonxRoot = ConfigService.linkedMelonxSaveFolderPath;
      if (Platform.isIOS &&
          system.folderName.toLowerCase() == 'switch' &&
          melonxRoot != null &&
          melonxRoot.isNotEmpty &&
          (path.isWithin(melonxRoot, file.path) ||
              path.equals(file.parent.path, melonxRoot))) {
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_6
        return await _uploadMeloNXFile(file, melonxRoot, preferredGame: game, contentHashOnly: true);
// DOLPHIN_ISOLATION_END: neosync_repair205_6
      }

      // 2. Determinar la ruta relativa de manera universal
      final savesPath = await _getRetroArchSavesPath();
      final statesPath = await _getRetroArchStatesPath();

      String basePath = file.parent.path;
      bool isState = false;

      if (statesPath != null && path.isWithin(statesPath, file.path)) {
        basePath = statesPath;
        isState = true;
      } else if (savesPath != null && path.isWithin(savesPath, file.path)) {
        basePath = savesPath;
        isState = false;
      }

      final relativePath = await _calculateSyncRelativePath(
        game,
        file,
        basePath,
        isState: isState,
      );

      final v2Path = CloudPathBuilder.parse(relativePath);
      if (v2Path == null) return false;

      final result = await _neoSyncService.syncFile(
        file,
        game.name,
        // DOLPHIN_ISOLATION_BEGIN: neosync_source_proof
        source: await _sourceForLocalFile(file),
        // DOLPHIN_ISOLATION_END: neosync_source_proof
        customFilename: relativePath,
        systemId: v2Path.system,
        emulatorId: v2Path.emulatorSlug,
        isState: v2Path.isState,
        scope: v2Path.scope,
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_7
        contentHashOnly: true,
// DOLPHIN_ISOLATION_END: neosync_repair205_7
      );

// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_8
      if (result['success'] == true && result['pending_download'] != true) {
// DOLPHIN_ISOLATION_END: neosync_repair205_8
        return true;
      } else {
        final errorMessage = result['message']?.toString().toLowerCase() ?? '';
        if (errorMessage.contains('quota') &&
            errorMessage.contains('exceeded')) {
          _quotaExceededActive = true;
          throw QuotaExceededException('Storage quota exceeded', 1);
        }
        return false;
      }
    } on QuotaExceededException {
      rethrow;
    } catch (e) {
      NeoSyncProvider._log.w('Error auto-uploading save for ${game.name}: $e');
      return false;
    }
  }

  /// Descarga automáticamente un save de la nube
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_9
  /// Busca TODOS los archivos de guardado locales para un juego específico (saves y states)
// DOLPHIN_ISOLATION_END: neosync_repair205_9
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_0_0
  Future<List<LocalSaveFile>> _findGameSaveFiles(GameModel game) async {
// DOLPHIN_ISOLATION_END: neosync_repair205_0_0
    // DOLPHIN_ISOLATION_BEGIN: dolphin_find_local
    if (_isDolphinGame(game)) return _dolphinLocalFiles(game);
    // DOLPHIN_ISOLATION_END: dolphin_find_local

    try {
      // 1. Obtener el sistema para resolver sus rutas JSON
      final system = await _getSystemForGame(game);
      if (system == null) return [];

      // Verificar si el sistema tiene sync deshabilitado
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_10
      if (!_supportsNeoSync(system)) return [];
// DOLPHIN_ISOLATION_END: neosync_repair205_10

      // 2. Resolver rutas universales desde el JSON
      final resolvedFolders = await resolveUniversalPaths(system, game: game);
      if (resolvedFolders.isEmpty) return [];

      // 3. Escanear archivos en esas rutas pero en un Isolate para no bloquear la UI
      final List<File> allFiles = [];
      // DOLPHIN_ISOLATION_BEGIN: neosync_discover_candidates
      final List<String> filePaths = await Isolate.run(() {
        final paths = <String>{};
        for (final folderPath in resolvedFolders) {
          final dir = Directory(folderPath);
          if (!dir.existsSync()) continue;
          paths.addAll(dir.listSync(recursive: true, followLinks: false)
              .whereType<File>().map((file) => file.path));
        }
        return paths.toList();
      });
      // DOLPHIN_ISOLATION_END: neosync_discover_candidates

      allFiles.addAll(filePaths.map((path) => File(path)));

      // 4. Filtrar archivos según el sistema
      final List<LocalSaveFile> matchingFiles = [];
      final gameRomName = _getRomNameWithoutExtension(game.romname)
          .toLowerCase();

      // Identificar si es un sistema de "memory cards compartidas"
      final isSharedSystem =
          system.folderName == 'ps2' || system.folderName == 'dc';

      final statesPath = await _getRetroArchStatesPath();
      final savesPath = await _getRetroArchSavesPath();

      for (final file in allFiles) {
        try {
          // DOLPHIN_ISOLATION_BEGIN: neosync_discover_source
          final source = await _sourceForLocalFile(file);
          if (source == null &&
              NeoSyncSavePolicy.classify(file.path) != NeoSyncSaveKind.save) continue;
          // DOLPHIN_ISOLATION_END: neosync_discover_source
          final fileName = path.basename(file.path).toLowerCase();
          bool isMatch = false;

          final rpcs3Root = Rpcs3LibraryService.linkedDataPath;
          if (Platform.isIOS &&
              system.folderName.toLowerCase() == 'ps3' &&
              rpcs3Root != null &&
              rpcs3Root.isNotEmpty &&
              path.isWithin(rpcs3Root, file.path)) {
            final rpcs3 = await _resolveRpcs3FileForCloud(
              file,
              rpcs3Root,
              preferredGame: game,
            );
            isMatch = rpcs3 != null;
          // DOLPHIN_ISOLATION_BEGIN: neosync_native_game_match
          } else if (source?.family == NeoSyncSaveFamily.melonx &&
              system.folderName.toLowerCase() == 'switch') {
            isMatch = await _resolveMeloNXFileForCloud(file, source!.rootPath,
                preferredGame: game) != null;
          } else if (const {'psp', 'pspminis'}.contains(system.folderName.toLowerCase()) &&
              RegExp(r'(?:^|/)(?:PSP/)?SAVEDATA/', caseSensitive: false)
                  .hasMatch(file.path.replaceAll('\\', '/'))) {
            final owner = await _gameForSaveFile(file);
            isMatch = owner?.romname == game.romname;
          // DOLPHIN_ISOLATION_END: neosync_native_game_match
          } else if (isSharedSystem) {
            final armsx2Root = ConfigService.linkedArmsx2FolderPath;
            if (Platform.isIOS &&
                system.folderName.toLowerCase() == 'ps2' &&
                armsx2Root != null &&
                armsx2Root.isNotEmpty &&
                path.isWithin(armsx2Root, file.path) &&
                _resolveArmsx2FileForCloud(file, armsx2Root) != null) {
    // DOLPHIN_ISOLATION_BEGIN: neosync207_armsx2_local_owner
              final resolved = _resolveArmsx2FileForCloud(file, armsx2Root)!;
              isMatch = !resolved.isState || NeoSyncGameScope.ps2StateMatches(
                path.relative(file.path, from: armsx2Root),
                romName: game.romname, gameName: game.name, titleId: game.titleId);
    // DOLPHIN_ISOLATION_END: neosync207_armsx2_local_owner
            } else if (system.folderName == 'ps2' &&
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_11
                (fileName.endsWith('.ps2') ||
                 (source?.family == NeoSyncSaveFamily.retroArchSaves &&
                  source!.relativePath.split('/').length > 2))) {
// DOLPHIN_ISOLATION_END: neosync_repair205_11
              isMatch = true;
            } else if (system.folderName == 'dc' &&
                fileName.startsWith('vmu_save') &&
                fileName.endsWith('.bin')) {
              isMatch = true;
            }
          } else {
            // Para sistemas estándar, filtrar por romname
            // Extendemos la búsqueda a la ruta completa por si el nombre del juego
            // está en la carpeta contenedora en vez del propio archivo (ej. Switch)
            final fullPathLower = file.path.toLowerCase();

    // DOLPHIN_ISOLATION_BEGIN: neosync207_nonempty_local
            if (gameRomName.isNotEmpty && (fileName.contains(gameRomName) ||
                fullPathLower.contains(gameRomName))) {
    // DOLPHIN_ISOLATION_END: neosync207_nonempty_local
              isMatch = true;
            } else if (system.folderName == 'switch' &&
                game.titleId != null &&
                game.titleId!.isNotEmpty) {
              // Especial para Switch: matchear por Title ID en la ruta
              if (fullPathLower.contains(game.titleId!.toLowerCase())) {
                isMatch = true;
              }
            } else {
              // Comparación flexible
              final normalizedPath = fullPathLower.replaceAll(
                RegExp(r'[^\w\s\/\\]'),
                '',
              );
              final normalizedGameName = gameRomName.replaceAll(
                RegExp(r'[^\w\s]'),
                '',
              );
    // DOLPHIN_ISOLATION_BEGIN: neosync207_nonempty_local_normalized
              if (normalizedGameName.isNotEmpty && normalizedPath.contains(normalizedGameName)) {
    // DOLPHIN_ISOLATION_END: neosync207_nonempty_local_normalized
                isMatch = true;
              }
            }
          }

          if (isMatch) {
            final stat = await file.stat();

            String basePath = file.parent.path;
            bool isState = false;

            if (statesPath != null && path.isWithin(statesPath, file.path)) {
              basePath = statesPath;
              isState = true;
            } else if (savesPath != null &&
                path.isWithin(savesPath, file.path)) {
              basePath = savesPath;
              isState = false;
            }

            String relativePath;
            final rpcs3Root = Rpcs3LibraryService.linkedDataPath;
            final armsx2Root = ConfigService.linkedArmsx2FolderPath;
            if (Platform.isIOS &&
                system.folderName.toLowerCase() == 'ps3' &&
                rpcs3Root != null &&
                rpcs3Root.isNotEmpty &&
                path.isWithin(rpcs3Root, file.path)) {
              final rpcs3 = await _resolveRpcs3FileForCloud(
                file,
                rpcs3Root,
                preferredGame: game,
              );
              if (rpcs3 == null) continue;
              relativePath = rpcs3.cloudPath;
            } else if (Platform.isIOS &&
                system.folderName.toLowerCase() == 'ps2' &&
                armsx2Root != null &&
                armsx2Root.isNotEmpty &&
                path.isWithin(armsx2Root, file.path)) {
              final armsx2 = _resolveArmsx2FileForCloud(file, armsx2Root);
              if (armsx2 == null) continue;
              relativePath = armsx2.cloudPath;
            } else {
              final melonxRoot = ConfigService.linkedMelonxSaveFolderPath;
              if (Platform.isIOS &&
                  system.folderName.toLowerCase() == 'switch' &&
                  melonxRoot != null &&
                  melonxRoot.isNotEmpty &&
                  path.isWithin(melonxRoot, file.path)) {
                final melonx = await _resolveMeloNXFileForCloud(
                  file,
                  melonxRoot,
                  preferredGame: game,
                );
                if (melonx == null) continue;
                relativePath = melonx.cloudPath;
              } else {
                // DOLPHIN_ISOLATION_BEGIN: neosync_discover_canonical_identity
                relativePath = await _calculateSyncRelativePath(
                  game,
                  file,
                  basePath,
                  isState: isState,
                );
                // DOLPHIN_ISOLATION_END: neosync_discover_canonical_identity
              }
            }

            matchingFiles.add(
              LocalSaveFile(
                filePath: file.path,
                fileName: path.basename(file.path),
                fileSize: stat.size,
                lastModified: stat.modified,
                gameName: isSharedSystem
                    ? '${system.realName} Shared'
                    : game.name,
                isSynced: false,
                relativePath: relativePath,
              ),
            );

            // Do not mark shared cards as processed while merely discovering them.
            // The upload/check loop owns that marker after a real sync decision.
          }
        } catch (e) {
          NeoSyncProvider._log.e('Error matching file: $e');
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_12
          rethrow;
// DOLPHIN_ISOLATION_END: neosync_repair205_12
        }
      }

      return matchingFiles;
    } catch (e) {
      NeoSyncProvider._log.e('Error in universal _findGameSaveFiles: $e');
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_13
      rethrow;
// DOLPHIN_ISOLATION_END: neosync_repair205_13
    }
  }

  /// Busca archivo de guardado local para un juego específico (legacy method - returns first match)


  /// Obtiene TODOS los archivos de guardado de la nube para un juego específico
  Future<List<NeoSyncFile>> _getCloudSaveFilesForGame(GameModel game) async {
    // DOLPHIN_ISOLATION_BEGIN: dolphin_find_cloud
    if (_isDolphinGame(game)) return _dolphinCloudFiles(game);
    // DOLPHIN_ISOLATION_END: dolphin_find_cloud

    try {
      // 1. Obtener el sistema para resolver sus características
      final system = await _getSystemForGame(game);
      if (system == null) return [];

      // Verificar si el sistema tiene sync deshabilitado
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_14
      if (!_supportsNeoSync(system)) return [];
// DOLPHIN_ISOLATION_END: neosync_repair205_14

      // 2. Cargar archivos de la nube si no están cargados
      if (_files.isEmpty) {
        final result = await _neoSyncService.getFiles();
        if (result['success']) {
          _files = result['files'];
        } else {
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_15
          throw StateError('NeoSync cloud listing failed: ${result['message']}');
// DOLPHIN_ISOLATION_END: neosync_repair205_15
        }
      }

      final gameRomName = _getRomNameWithoutExtension(game.romname)
          .toLowerCase();
      final List<NeoSyncFile> matchingFiles = [];

      // Identificar si es un sistema de "memory cards compartidas"
      final isSharedSystem =
          system.folderName == 'ps2' || system.folderName == 'dc';

      for (final cloudFile in _files) {
        // DOLPHIN_ISOLATION_BEGIN: dolphin_no_foreign_cloud_match
        if (DolphinSaveTarget.ownsCloudPath(cloudFile.fileName) ||
            DolphinSaveTarget.ownsCloudPath(cloudFile.sourceSavePath)) continue;
        // DOLPHIN_ISOLATION_END: dolphin_no_foreign_cloud_match
        // DOLPHIN_ISOLATION_BEGIN: neosync_cloud_scope
        if (cloudFile.saveKind != NeoSyncSaveKind.save) continue;
        final identity = NeoSyncSavePolicy.canonical(cloudFile.sourceSavePath);
        if (identity != null && identity.system.toLowerCase() != system.folderName.toLowerCase()) continue;
        final fileName = path.basename(_saveIdentity(cloudFile.sourceSavePath)).toLowerCase();
        if (Platform.isIOS && system.folderName.toLowerCase() == 'ps2' && identity != null) {
          final armsx2 = Armsx2FolderService.ownsRomPath(game.romPath, ConfigService.linkedArmsx2FolderPath);
          if ((identity.emulatorSlug == 'armsx2') != armsx2) continue;
        }
        if (identity?.emulatorSlug == 'armsx2' && system.folderName.toLowerCase() == 'ps2') {
          if (!identity!.isState || NeoSyncGameScope.ps2StateMatches(identity.filePath,
              romName: game.romname, gameName: game.name, titleId: game.titleId)) {
            matchingFiles.add(cloudFile);
          }
          continue;
        }
        if (identity?.emulatorSlug == 'melonx' && system.folderName.toLowerCase() == 'switch') {
          final expectedTitleId = await _meloNXTitleIdForGame(game);
          if (NeoSyncGameScope.switchCloudMatches(identity!.filePath,
              expectedTitleId: expectedTitleId, legacyOwner: identity.gameName,
              expectedNames: {
                CloudPathBuilder.sanitizeGameName(game.name),
                if (game.titleName?.trim().isNotEmpty == true)
                  CloudPathBuilder.sanitizeGameName(game.titleName!),
              })) matchingFiles.add(cloudFile);
          continue;
        }
        // DOLPHIN_ISOLATION_END: neosync_cloud_scope
        bool isMatch = false;

        if (isSharedSystem) {
          // Para sistemas compartidos, filtrar estrictamente por sistema
          // DOLPHIN_ISOLATION_BEGIN: neosync_per_game_original_path
final parsed = NeoSyncSavePolicy.canonical(cloudFile.sourceSavePath);
// DOLPHIN_ISOLATION_END: neosync_per_game_original_path
          if (system.folderName.toLowerCase() == 'ps2' &&
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_16
              parsed?.system == 'ps2' && parsed?.isShared == true) {
// DOLPHIN_ISOLATION_END: neosync_repair205_16
            isMatch = true;
          } else if (system.folderName == 'ps2' && fileName.endsWith('.ps2')) {
            isMatch = true;
          } else if (system.folderName == 'dc' &&
              fileName.startsWith('vmu_save') &&
              fileName.endsWith('.bin')) {
            isMatch = true;
          }
        } else {
          // DOLPHIN_ISOLATION_BEGIN: neosync_per_game_original_path
final parsed = NeoSyncSavePolicy.canonical(cloudFile.sourceSavePath);
// DOLPHIN_ISOLATION_END: neosync_per_game_original_path
          if (system.folderName.toLowerCase() == 'ps3' &&
              parsed?.emulatorSlug == 'rpcs3' &&
              parsed?.gameName != null) {
            var expectedTitleId = game.titleId?.trim().toUpperCase();
            if (expectedTitleId == null || expectedTitleId.isEmpty) {
              expectedTitleId = (await GameRepository.getTitleIdForGame(
                game.romname,
                game.name,
              ))?.trim().toUpperCase();
            }
            final parts = parsed!.filePath.split('/');
            final cloudSaveDirectory = parts.length >= 2 ? parts[1] : '';
            final cloudTitleId = _rpcs3TitleIdFromSaveDirectory(
              cloudSaveDirectory,
            );
            final expectedNames = <String>{
              CloudPathBuilder.sanitizeGameName(game.name).toLowerCase(),
              if (game.titleName != null && game.titleName!.trim().isNotEmpty)
                CloudPathBuilder.sanitizeGameName(game.titleName!)
                    .toLowerCase(),
            };
            final cloudGameName = parsed.gameName!.toLowerCase();
            if ((expectedTitleId != null &&
                    expectedTitleId.isNotEmpty &&
                    cloudTitleId == expectedTitleId) ||
                expectedNames.contains(cloudGameName)) {
              isMatch = true;
            }
          }

          if (!isMatch &&
              system.folderName.toLowerCase() == 'switch' &&
              parsed?.emulatorSlug == 'melonx' &&
              parsed?.gameName != null) {
            final expectedNames = <String>{
              CloudPathBuilder.sanitizeGameName(game.name).toLowerCase(),
              if (game.titleName != null && game.titleName!.trim().isNotEmpty)
                CloudPathBuilder.sanitizeGameName(game.titleName!)
                    .toLowerCase(),
            };
            final cloudGameName = parsed!.gameName!.toLowerCase();
            if (expectedNames.contains(cloudGameName) ||
                cloudFile.gameName.toLowerCase() == game.name.toLowerCase()) {
              isMatch = true;
            }
          }

          // Para sistemas estándar, filtrar por romname cuando no haya match v2.
          // Usamos la ruta completa del cloudFile por si está en carpetas.
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_17
          final fullCloudPathLower = cloudFile.sourceSavePath.toLowerCase();
// DOLPHIN_ISOLATION_END: neosync_repair205_17

    // DOLPHIN_ISOLATION_BEGIN: neosync207_nonempty_cloud
          if (!isMatch && gameRomName.isNotEmpty &&
              (fileName.contains(gameRomName) ||
    // DOLPHIN_ISOLATION_END: neosync207_nonempty_cloud
                  fullCloudPathLower.contains(gameRomName))) {
            isMatch = true;
          } else if (!isMatch) {
            // Comparación flexible en toda la ruta
            final normalizedCloudPath = fullCloudPathLower.replaceAll(
              RegExp(r'[^\w\s\/]'),
              '',
            );
            final normalizedGameName = gameRomName.replaceAll(
              RegExp(r'[^\w\s]'),
              '',
            );
    // DOLPHIN_ISOLATION_BEGIN: neosync207_nonempty_cloud_normalized
            if (normalizedGameName.isNotEmpty && normalizedCloudPath.contains(normalizedGameName)) {
    // DOLPHIN_ISOLATION_END: neosync207_nonempty_cloud_normalized
              isMatch = true;
            }
          }
        }

        if (isMatch) {
          matchingFiles.add(cloudFile);
        }
      }

      return matchingFiles;
    } catch (e) {
      NeoSyncProvider._log.e(
        'Error getting cloud save files for ${game.name}: $e',
      );
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_18
      rethrow;
// DOLPHIN_ISOLATION_END: neosync_repair205_18
    }
  }

  /// Obtiene archivo de guardado de la nube para un juego específico (legacy method - returns first match)
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_19

// DOLPHIN_ISOLATION_END: neosync_repair205_19

  // DOLPHIN_ISOLATION_BEGIN: neosync_confirmed_status
  String _saveIdentity(String value) => NeoSyncStatusRules.identity(value);

  Future<neo_sync.GameSyncStatus> _aggregateGameSyncStatus(
    List<LocalSaveFile> locals,
    List<NeoSyncFile> clouds,
  ) => NeoSyncStatusRules.aggregate(locals, clouds,
      readSyncState: SyncRepository.getSyncState);

  Future<neo_sync.GameSyncStatus> _calculateGameSyncStatus(
    LocalSaveFile? localSave,
    NeoSyncFile? cloudSave,
  ) => NeoSyncStatusRules.compare(localSave, cloudSave,
      readSyncState: SyncRepository.getSyncState);

  void _updateGameSyncState(
    String gameId,
    String gameName,
    neo_sync.GameSyncStatus status, {
    LocalSaveFile? localSave,
    NeoSyncFile? cloudSave,
    String? errorMessage,
  }) {
    final currentState = _gameSyncStates[gameId];
    _gameSyncStates[gameId] = neo_sync.GameSyncState(
      gameId: gameId,
      gameName: gameName,
      status: status,
      cloudEnabled: currentState?.cloudEnabled ?? true,
      localSave: localSave,
      cloudSave: cloudSave,
      lastSync: status == neo_sync.GameSyncStatus.upToDate
          ? DateTime.now() : currentState?.lastSync,
      errorMessage: errorMessage,
    );
    notify();
  }
  // DOLPHIN_ISOLATION_END: neosync_confirmed_status

  /// Actualiza la configuración de sincronización en la nube para un juego
  Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {
    try {
      // systemFolderName and filename resolution for this gameId is not yet implemented;
      // only local state is updated for now.
      final currentState = _gameSyncStates[gameId];
      if (currentState != null) {
        final newState = currentState.copyWith(cloudEnabled: enabled);
        _gameSyncStates[gameId] = newState;
      }

      if (enabled) {
        _updateGameSyncState(
          gameId,
          currentState?.gameName ?? gameId,
          neo_sync.GameSyncStatus.noSaveFound,
        );
      } else {
        _updateGameSyncState(
          gameId,
          currentState?.gameName ?? gameId,
          neo_sync.GameSyncStatus.disabled,
        );
      }
    } catch (e) {
      NeoSyncProvider._log.e('Error updating cloud sync for game $gameId: $e');
    }
  }

  // ==========================================
  // MÉTODOS PÚBLICOS PARA DESCARGA INDIVIDUAL
  // ==========================================

  /// Obtiene la ruta del directorio de saves de RetroArch (método público)
  Future<String?> getRetroArchSavesPath() async {
    return _getRetroArchSavesPath();
  }

  /// Descarga un archivo de la nube a un archivo local (método público)
  Future<void> downloadCloudFile(NeoSyncFile cloudFile, File localFile) async {
    return _downloadCloudFile(cloudFile, localFile);
  }

  /// Helper to calculate relative path for sync, with special handling for Dreamcast
  /// Sincroniza saves antes de iniciar un juego (al estilo Steam)
  Future<void> syncGameSavesBeforeLaunch(GameModel game) async {
    // DOLPHIN_ISOLATION_BEGIN: dolphin_prelaunch
    if (_isDolphinGame(game)) {
      if (_autoSyncEnabled) await _syncDolphinGame(game);
      return;
    }
    // DOLPHIN_ISOLATION_END: dolphin_prelaunch

    if (!isNeoSyncAuthenticated) return;
    if (game.cloudSyncEnabled != true) return;

    try {
      // DOLPHIN_ISOLATION_BEGIN: neosync_before_launch_units
      await detectGameSaveFiles(game);
      // DOLPHIN_ISOLATION_END: neosync_before_launch_units
    } on QuotaExceededException {
      NeoSyncProvider._log.e(
        'Pre-launch sync failed: storage quota exceeded for ${game.name}',
      );
      // Actualizar el estado del juego a quota exceeded
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.quotaExceeded,
      );
    } catch (e) {
      NeoSyncProvider._log.w('Error in pre-launch sync for ${game.name}: $e');
    }
  }

  /// Sincroniza saves después de cerrar un juego (al estilo Steam)
  Future<void> syncGameSavesAfterClose(GameModel game) async {
    // DOLPHIN_ISOLATION_BEGIN: dolphin_after_close
    if (_isDolphinGame(game)) {
      if (_autoSyncEnabled) {
        for (var attempt = 0; attempt < 3; attempt++) {
          await _syncDolphinGame(game, download: false);
          if (_gameSyncStates[game.romname]?.status != neo_sync.GameSyncStatus.pending) break;
          if (attempt < 2) await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      }
      return;
    }
    // DOLPHIN_ISOLATION_END: dolphin_after_close

    if (!isNeoSyncAuthenticated) return;
    if (game.cloudSyncEnabled != true) return;

    try {
      // DOLPHIN_ISOLATION_BEGIN: neosync_after_close_units
      await Future.delayed(const Duration(seconds: 1));
      await detectGameSaveFiles(game);
      // DOLPHIN_ISOLATION_END: neosync_after_close_units
    } on QuotaExceededException {
      NeoSyncProvider._log.e(
        'Post-game sync failed: storage quota exceeded for ${game.name}',
      );
      // Actualizar el estado del juego a quota exceeded
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.quotaExceeded,
      );
    } catch (e) {
      NeoSyncProvider._log.w('Error in post-game sync for ${game.name}: $e');
    }
  }

  /// Restaura un backup desde la nube (descarga y sobreescribe local)
  Future<void> restoreCloudBackup(NeoSyncFile cloudFile) async {
    // DOLPHIN_ISOLATION_BEGIN: dolphin_restore
    if (DolphinSaveTarget.ownsCloudPath(cloudFile.fileName) ||
        DolphinSaveTarget.ownsCloudPath(cloudFile.sourceSavePath)) {
      await _restoreDolphinCloud(cloudFile); return;
    }
    // DOLPHIN_ISOLATION_END: dolphin_restore

    // DOLPHIN_ISOLATION_BEGIN: neosync_restore_owner
    final byId = <String, NeoSyncFile>{
      for (final item in [..._files, ..._onlineFiles]) item.id: item,
      cloudFile.id: cloudFile,
    };
    final units = NeoSyncSaveUnits.cloud(byId.values);
    final selected = units.where((unit) => unit.members.any((member) => member.id == cloudFile.id));
    if (selected.length != 1) throw StateError('Cannot identify one native save');
    await restoreCloudSaveUnit(selected.single.members);
    // DOLPHIN_ISOLATION_END: neosync_restore_owner
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_20
  }
// DOLPHIN_ISOLATION_END: neosync_repair205_20

// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_21
}
// DOLPHIN_ISOLATION_END: neosync_repair205_21
