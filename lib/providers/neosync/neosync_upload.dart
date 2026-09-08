part of '../neo_sync_provider.dart';

extension NeoSyncUpload on NeoSyncProvider {
  /// Uploads only save roots that remain supported by NeoSync on the current
  /// platform. On iOS, DolphiniOS uses its strict V1 store while the
  /// standalone ARMSX2, RPCS3 and MeloNX save trees are not enumerated.
  Future<void> autoSyncUploads() async {
    if (!isNeoSyncAuthenticated || _isSyncing) return;

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
      await _syncAllDolphinGames(download: false);

      final savesPath = await _getRetroArchSavesPath();
      List<File> retroArchSaves = [];
      if (savesPath != null) {
        retroArchSaves = await _getSaveFiles(savesPath);
      }

      final flycastRoot = await _flycastSystemSaveRoot();
      if (flycastRoot != null) {
        retroArchSaves.addAll(await _getSaveFiles(flycastRoot));
      }

      final statesPath = await _getRetroArchStatesPath();
      List<File> retroArchStates = [];
      if (statesPath != null) {
        retroArchStates = await _getSaveFiles(statesPath);
      }

      // Preserve the existing non-iOS Switch NAND flow. iOS Switch saves are
      // owned by MeloNX and are intentionally outside NeoSync.
      if (!Platform.isIOS) {
        try {
          final emulators = await SwitchSaveDetector.detectEmulatorNandPaths();
          if (Platform.isAndroid) {
            final Map<String, List<MapEntry<File, String>>> savesByTitleId = {};
            for (final emulator in emulators) {
              final nandPath = emulator.nandDirectory;
              final savePath =
                  '$nandPath${Platform.pathSeparator}user${Platform.pathSeparator}save${Platform.pathSeparator}0000000000000000';
              final saveDir = Directory(savePath);
              if (!await saveDir.exists()) continue;
              final switchFiles = saveDir
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where((file) =>
                      !file.path.endsWith('.') && !file.path.endsWith('..'))
                  .toList();
              for (final file in switchFiles) {
                try {
                  final parts = file.path.split(Platform.pathSeparator);
                  final saveIndex = parts.indexOf('save');
                  if (saveIndex != -1 && saveIndex + 3 < parts.length) {
                    final titleId = parts[saveIndex + 3];
                    final relative = parts
                        .sublist(saveIndex + 4)
                        .join(Platform.pathSeparator);
                    final key = '$titleId/$relative';
                    (savesByTitleId[key] ??= <MapEntry<File, String>>[]).add(
                      MapEntry(file, emulator.emulatorName),
                    );
                  }
                } catch (_) {
                  saveFiles.add(file);
                }
              }
            }
            for (final entry in savesByTitleId.values) {
              if (entry.length == 1) {
                saveFiles.add(entry.first.key);
                continue;
              }
              File? mostRecent;
              DateTime? mostRecentDate;
              for (final candidate in entry) {
                final modified = await candidate.key.lastModified();
                if (mostRecent == null || modified.isAfter(mostRecentDate!)) {
                  mostRecent = candidate.key;
                  mostRecentDate = modified;
                }
              }
              if (mostRecent != null) saveFiles.add(mostRecent);
            }
          } else {
            for (final emulator in emulators) {
              final savePath =
                  '${emulator.nandDirectory}${Platform.pathSeparator}user${Platform.pathSeparator}save${Platform.pathSeparator}0000000000000000';
              final saveDir = Directory(savePath);
              if (!await saveDir.exists()) continue;
              saveFiles.addAll(
                saveDir
                    .listSync(recursive: true)
                    .whereType<File>()
                    .where((file) =>
                        !file.path.endsWith('.') && !file.path.endsWith('..')),
              );
            }
          }
        } catch (error) {
          NeoSyncProvider._log.e('Error scanning Switch NAND saves: $error');
        }
      }

      if (retroArchSaves.isEmpty &&
          retroArchStates.isEmpty &&
          saveFiles.isEmpty) {
        if (_dolphinBulkChecked > 0) {
          _syncStatus =
              'Dolphin upload checked: $_uploadedFiles uploaded. '
              'See per-game status for conflicts or deferred saves.';
          _syncProgress = 1.0;
          return;
        }
        _syncStatus = 'No local save files found';
        _processedItems.add('No local save files found for auto-sync');
        return;
      }

      _totalFiles =
          retroArchSaves.length + retroArchStates.length + saveFiles.length;
      _processedItems.add('Auto-syncing $_totalFiles local files...');
      _syncStatus = 'Checking files for upload...';
      notify();

      for (final file in retroArchSaves) {
        await _processAutoUploadFile(
          file,
          flycastRoot != null && path.isWithin(flycastRoot, file.path)
              ? flycastRoot
              : savesPath!,
          isState: false,
        );
        _processedFiles++;
        _syncProgress = _totalFiles == 0 ? 0 : _processedFiles / _totalFiles;
        notify();
      }

      for (final file in retroArchStates) {
        await _processAutoUploadFile(file, statesPath!, isState: true);
        _processedFiles++;
        _syncProgress = _totalFiles == 0 ? 0 : _processedFiles / _totalFiles;
        notify();
      }

      for (final file in saveFiles) {
        await _processAutoUploadFile(file, file.parent.path, isState: false);
        _processedFiles++;
        _syncProgress = _totalFiles == 0 ? 0 : _processedFiles / _totalFiles;
        notify();
      }

      _syncProgress = 1.0;
      _syncStatus =
          'Auto-upload completed: $_uploadedFiles uploaded, $_skippedFiles already synced';
      _processedItems.add(_syncStatus);
    } catch (error) {
      if (error is QuotaExceededException) {
        _error = 'Storage quota exceeded after ${error.attemptCount} attempts';
        _syncStatus = 'Quota exceeded - Auto-sync disabled';
      } else {
        _error = 'Error during auto-sync: $error';
        _syncStatus = 'Error: $_error';
      }
      _processedItems.add(_syncStatus);
    } finally {
      _finishDolphinBulkStatus();
      _setSyncing(false);
    }
  }

  Future<void> _processAutoUploadFile(
    File file,
    String basePath, {
    bool isState = false,
    String? customEmulatorSlug,
  }) async {
    try {
      // Standalone iOS emulator callers are intentionally inert even if an
      // older code path still holds a reference to this helper.
      if (Platform.isIOS &&
          const {'armsx2', 'rpcs3', 'melonx'}
              .contains(customEmulatorSlug?.toLowerCase())) {
        _skippedFiles++;
        return;
      }

      final isNandFile = file.path.contains(
        '${Platform.pathSeparator}nand${Platform.pathSeparator}user${Platform.pathSeparator}save',
      );
      if (isNandFile && !Platform.isIOS) {
        await _handleSwitchNandAutoUpload(file);
        return;
      }

      final game = await _gameForSaveFile(file);
      if (game == null) {
        _skippedFiles++;
        return;
      }
      if (_isIosNeoSyncGameExcluded(game)) {
        _skippedFiles++;
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
        return;
      }

      if (Platform.isIOS &&
          const {'armsx2', 'rpcs3', 'melonx'}
              .contains(v2Path.emulatorSlug.toLowerCase())) {
        _skippedFiles++;
        return;
      }

      final result = await _neoSyncService.syncFile(
        file,
        game.name,
        source: await _sourceForLocalFile(file),
        customFilename: relativePath,
        systemId: v2Path.system,
        emulatorId: v2Path.emulatorSlug,
        isState: v2Path.isState,
        scope: v2Path.scope,
      );
      if (result['success'] == true && result['pending_download'] != true) {
        if (result['skipped'] == true) {
          _skippedFiles++;
        } else {
          _uploadedFiles++;
          _resetQuotaAttempts();
        }
      } else {
        final message = result['message']?.toString() ?? '';
        if (_checkQuotaExceeded(message)) {
          _quotaExceededActive = true;
          throw QuotaExceededException(message, _quotaExceededAttempts);
        }
      }
    } catch (error) {
      if (error is QuotaExceededException) rethrow;
      _processedItems.add('Error processing ${path.basename(file.path)}: $error');
    }
  }

  /// Compatibility stubs. The standalone iOS save integrations are removed;
  /// these methods deliberately perform no filesystem or network work.
  Future<bool> _uploadArmsx2File(
    File file,
    String root, {
    GameModel? preferredGame,
    bool contentHashOnly = false,
  }) async => false;

  Future<bool> _uploadRpcs3File(
    File file,
    String dataRoot, {
    GameModel? preferredGame,
    bool contentHashOnly = false,
  }) async => false;

  Future<bool> _uploadMeloNXFile(
    File file,
    String root, {
    GameModel? preferredGame,
    bool contentHashOnly = false,
  }) async => false;

  Future<void> _handleSwitchNandAutoUpload(File file) async {
    if (Platform.isIOS) return;
    try {
      final parts = file.path.split(Platform.pathSeparator);
      final saveIndex = parts.indexOf('save');
      if (saveIndex == -1 || saveIndex + 3 >= parts.length) return;
      final titleId = parts[saveIndex + 3];
      final row = await GameRepository.findSwitchGameByTitleId(titleId);
      if (row == null) return;

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
        source: await _sourceForLocalFile(file),
        customFilename: relativePath,
      );
      if (result['success'] == true && result['pending_download'] != true) {
        if (result['skipped'] == true) {
          _skippedFiles++;
        } else {
          _uploadedFiles++;
          _resetQuotaAttempts();
        }
      }
    } catch (error) {
      NeoSyncProvider._log.e('Error processing Switch NAND file: $error');
    }
  }
}
