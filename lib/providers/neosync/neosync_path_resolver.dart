part of '../neo_sync_provider.dart';

/// Centraliza la resolución de rutas para NeoSync
extension NeoSyncPathResolver on NeoSyncProvider {
  /// Resuelve una lista de rutas de sincronización para un sistema
  Future<List<String>> resolveUniversalPaths(
    SystemModel system, {
    GameModel? game,
    bool ensureExists = true,
  }) async {
    // DOLPHIN_ISOLATION_BEGIN: dolphin_save_roots
    if (Platform.isIOS && DolphinInternalV2Service.isDolphinSystem(system.folderName)) {
      final root = await DolphinInternalV2Service.rootDirectory();
      final native = system.folderName.trim().toLowerCase() == 'gc'
          ? path.join(root.path, 'User', 'GC')
          : path.join(root.path, 'User', 'Wii', 'title');
      return !ensureExists || await Directory(native).exists() ? [native] : [];
    }
    // DOLPHIN_ISOLATION_END: dolphin_save_roots

    final folders = system.neosync.getFoldersForCurrentPlatform();
    final List<String> resolvedPaths = [];

    // PS2 on iOS must never merge RetroArch and ARMSX2 save roots. Ownership
    // comes from the ROM path: a ROM inside the ARMSX2 bookmark (or an armsx2://
    // row) is ARMSX2-owned; every other PS2 row remains RetroArch-owned.
    if (Platform.isIOS && system.folderName.toLowerCase() == 'ps2') {
      final armsx2Root = ConfigService.linkedArmsx2FolderPath;
      final isArmsx2Game = Armsx2FolderService.ownsRomPath(
        game?.romPath,
        armsx2Root,
      );
      if (isArmsx2Game && armsx2Root != null && armsx2Root.isNotEmpty) {
        // DOLPHIN_ISOLATION_BEGIN: neosync_armsx2_selected_category
        if (const ['memcards', 'savestates', 'sstates']
            .contains(path.basename(armsx2Root).toLowerCase())) {
          return [armsx2Root];
        }
        // DOLPHIN_ISOLATION_END: neosync_armsx2_selected_category
        return await Armsx2FolderService.resolveSaveDirectories(armsx2Root);
      }

      final retroPaths = <String>[];
      final saves = await _getRetroArchSavesPath();
      final states = await _getRetroArchStatesPath();
      if (saves != null) retroPaths.add(saves);
      if (states != null) retroPaths.add(states);
      return retroPaths.toSet().toList();
    }

    // DOLPHIN_ISOLATION_BEGIN: neosync_native_switch_roots
    // MeloNX owns its Switch save tree. Never merge it with RetroArch's roots
    // or scan the linked app/bis root (which also contains DLC and firmware).
    if (Platform.isIOS && system.folderName.toLowerCase() == 'switch') {
      final root = ConfigService.linkedMelonxSaveFolderPath;
      return root == null || root.isEmpty
          ? [] : NeoSyncSavePolicy.melonxSaveRoots(root);
    }
    // DOLPHIN_ISOLATION_END: neosync_native_switch_roots

    // System JSON predates iOS NeoSync and has no ios_sync_folder entries.
    // RetroArch's bookmarked saves/states roots are authoritative for preview 1.
    if (Platform.isIOS && folders.isEmpty) {
      final saves = await _getRetroArchSavesPath();
      final states = await _getRetroArchStatesPath();
      if (saves != null) resolvedPaths.add(saves);
      if (states != null) resolvedPaths.add(states);
    }

// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_0_0

// DOLPHIN_ISOLATION_END: neosync_repair205_0_0
    for (final folder in folders) {
      final resolved = await _resolveSinglePath(
        folder,
        system,
        game: game,
        ensureExists: ensureExists,
      );
      resolvedPaths.addAll(resolved);
    }

    // DOLPHIN_ISOLATION_BEGIN: neosync_flycast_system_vmu
    if (system.folderName.toLowerCase() == 'dc') {
      final systemRoot = await _getRetroArchSystemPath();
      if (systemRoot != null) resolvedPaths.add(path.join(systemRoot, 'dc'));
    }
    // DOLPHIN_ISOLATION_END: neosync_flycast_system_vmu

    // Eliminar duplicados y rutas inexistentes si requireExists es true
    var result = resolvedPaths.toSet();
    if (ensureExists) {
      result = result.where((p) => Directory(p).existsSync()).toSet();
    }
    return result.toList();
  }

  /// Resuelve un string de ruta (con posibles placeholders) a una o más rutas absolutas
  Future<List<String>> _resolveSinglePath(
    String pathStr,
    SystemModel system, {
    GameModel? game,
    bool ensureExists = true,
  }) async {
    // 1. Placeholder {SYNC_DIR} (Saves y States de RetroArch)
    if (pathStr == '{SYNC_DIR}') {
      final List<String> paths = [];
      final saves = await _getRetroArchSavesPath();
      if (saves != null) paths.add(saves);
      final states = await _getRetroArchStatesPath();
      if (states != null) paths.add(states);
      return paths;
    }

    // 2. iOS ARMSX2 NeoSync root. This never falls back to Android paths.
    if (pathStr == '{ARMSX2_IOS_SAVES}' && Platform.isIOS) {
      final root = ConfigService.linkedArmsx2FolderPath;
      if (root == null || root.isEmpty) return [];
      final saves = await Armsx2FolderService.resolveSaveDirectories(root);
      if (!ensureExists) return saves;
      return saves.where((p) => Directory(p).existsSync()).toList();
    }

    // RPCS3 iOS native PS3 save-data roots. Reuse the existing security-
    // scoped bookmark for RPCS3 > Data; no second folder picker is required.
    if (pathStr == '{RPCS3_IOS_SAVEDATA}' && Platform.isIOS) {
      final dataRoot = Rpcs3LibraryService.linkedDataPath;
      if (dataRoot == null || dataRoot.isEmpty) return [];
      final home = Directory(path.join(dataRoot, 'dev_hdd0', 'home'));
      if (!home.existsSync()) return [];
      final paths = <String>[];
      try {
        for (final userDir
            in home.listSync(followLinks: false).whereType<Directory>()) {
          final savedata = path.join(userDir.path, 'savedata');
          if (Directory(savedata).existsSync()) paths.add(savedata);
        }
      } catch (e) {
        NeoSyncProvider._log.w(
          'Could not enumerate RPCS3 savedata profiles: $e',
        );
      }
      return paths;
    }

    // 3. Placeholder {NETHERSX2_MEMCARDS} (AetherSX2/NetherSX2 memcards)
    if (pathStr == '{NETHERSX2_MEMCARDS}' && Platform.isAndroid) {
      final possiblePaths = [
        '/storage/emulated/0/Android/data/xyz.aethersx2.android/files/memcards',
        '/storage/emulated/0/Android/data/com.aethersx2.android/files/memcards',
        '/sdcard/Android/data/xyz.aethersx2.android/files/memcards',
      ];
      for (final p in possiblePaths) {
        if (Directory(p).existsSync()) return [p];
      }
      if (!ensureExists) return [possiblePaths.first];
      return [];
    }

    // 3. Placeholder {PCSX2_MEMCARDS} (PCSX2 on Windows/Android)
    if (pathStr == '{PCSX2_MEMCARDS}') {
      final List<String> paths = [];
      final p = await _getPCSX2MemcardsPath();
      if (p != null) paths.add(p);
      return paths;
    }

    // 4. Placeholder {FLYCAST_SAVES} (Flycast on Windows/Android)
    if (pathStr == '{FLYCAST_SAVES}') {
      final List<String> paths = [];
      final p = await _getFlycastSavesPath();
      if (p != null) paths.add(p);
      return paths;
    }

    // 3. Placeholder {SWITCH_NAND} o ${nandDir.path} (Switch NAND)
    if (pathStr.contains('{SWITCH_NAND}') ||
        pathStr.contains(r'${nandDir.path}')) {
      final nands = await SwitchSaveDetector.detectEmulatorNandPaths();
      final List<String> paths = [];

      String? titleId = game?.titleId;

      // If titleId not in DB, try extracting from ROM file and persist it.
      if ((titleId == null || titleId.isEmpty) && game?.romPath != null) {
        try {
          final info = await SwitchTitleExtractor.extractGameInfo(
            game!.romPath!,
          );
          if (info != null && info.titleId.isNotEmpty) {
            titleId = info.titleId;
            await GameRepository.updateGameTitleId(game.romname, titleId);
          }
        } catch (e) {
          NeoSyncProvider._log.e(
            'Error updating game titleId for ${game?.romname}: $e',
          );
        }
      }

      // Last resort: scan NAND save dirs and reverse-lookup by titleId in DB.
      // Needed on Android when ROM file is inaccessible (installed titles, etc.).
      if ((titleId == null || titleId.isEmpty) &&
          game != null &&
          nands.isNotEmpty) {
        titleId = await _findTitleIdByNandScan(nands, game.romname);
        if (titleId != null) {
          await GameRepository.updateGameTitleId(game.romname, titleId);
        }
      }

      for (final nand in nands) {
        final placeholder = pathStr.contains('{SWITCH_NAND}')
            ? '{SWITCH_NAND}'
            : r'${nandDir.path}';

        // Intentar resolver carpeta específica de guardado si tenemos titleId
        if (titleId != null && titleId.isNotEmpty && pathStr == placeholder) {
          final saveInfo = await SwitchSaveDetector.findSaveForTitleId(
            nand.nandDirectory,
            titleId,
          );
          if (saveInfo != null) {
            paths.add(saveInfo.savePath);

            continue;
          }
        }

        final resolved = pathStr.replaceFirst(placeholder, nand.nandDirectory);
        paths.add(resolved);
      }
      return paths;
    }

    // 4. RetroArch Placeholders
    if (pathStr == '{RETROARCH_SAVES}') {
      final p = await _getRetroArchSavesPath();
      return p != null ? [p] : [];
    }
    if (pathStr == '{RETROARCH_STATES}') {
      final p = await _getRetroArchStatesPath();
      return p != null ? [p] : [];
    }
    if (pathStr == '{RETROARCH_SYSTEM}') {
      final p = await _getRetroArchSystemPath();
      return p != null ? [p] : [];
    }

    // 4. Resolución estándar vía ConfigService (Home, AppData, etc.)
    final resolved = ConfigService.resolvePath(pathStr);

    // Si es absoluta y existe, retornarla
    if (path.isAbsolute(resolved)) {
      if (!ensureExists || Directory(resolved).existsSync()) {
        return [resolved];
      }
      return [];
    }

    // Si es relativa, intentar resolverla respecto a carpetas del sistema
    // (Esto es para sistemas que definen carpetas de ROMs pero los saves están cerca)
    for (final sysFolder in system.folders) {
      final absPath = path.join(sysFolder, resolved);
      if (Directory(absPath).existsSync()) {
        return [absPath];
      }
    }

    if (!ensureExists && system.folders.isNotEmpty) {
      return [path.join(system.folders.first, resolved)];
    }

    return [];
  }

  ({String cloudPath, String gameName, bool isState, String category})?
  _resolveArmsx2FileForCloud(File file, String root) {
    // DOLPHIN_ISOLATION_BEGIN: neosync_armsx2_source
    if (NeoSyncSaveSource.resolve(filePath: file.path, rootPath: root,
        family: NeoSyncSaveFamily.armsx2) == null) return null;
    // DOLPHIN_ISOLATION_END: neosync_armsx2_source
    const categories = <String>['memcards', 'savestates', 'sstates'];
    final relative = path.relative(file.path, from: root).replaceAll('\\', '/');
    if (relative == '..' || relative.startsWith('../')) return null;

    final rootName = path.basename(root).toLowerCase();
    final segments = relative
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (segments.isEmpty) return null;

    late final String category;
    late final String internalPath;
    if (categories.contains(rootName)) {
      category = rootName;
      internalPath = segments.join('/');
    } else {
      final candidate = segments.first.toLowerCase();
      if (!categories.contains(candidate) || segments.length < 2) return null;
      category = candidate;
      internalPath = segments.sublist(1).join('/');
    }

    final isState = category != 'memcards';
    final gameName = isState ? 'ARMSX2 Save States' : 'ARMSX2 Memory Cards';
    final isMemoryCardContainer =
        category == 'memcards' && internalPath.toLowerCase().endsWith('.ps2');
    final cloudInternalPath = isMemoryCardContainer
        ? '$category/$internalPath.neosync.gz'
        : '$category/$internalPath';
    final cloudPath = CloudPathBuilder.build(
      system: 'ps2',
      emulatorSlug: 'armsx2',
      scope: 'shared',
      filePath: cloudInternalPath,
      isState: isState,
    );
    return (
      cloudPath: cloudPath,
      gameName: gameName,
      isState: isState,
      category: category,
    );
  }

  String? _resolveArmsx2CloudFileToLocal(String root, String cloudFilePath) {
    const categories = <String>['memcards', 'savestates', 'sstates'];
    var localCloudPath = cloudFilePath;
    if (localCloudPath.toLowerCase().endsWith('.neosync.gz')) {
      localCloudPath = localCloudPath.substring(
        0,
        localCloudPath.length - '.neosync.gz'.length,
      );
    }
    final segments = localCloudPath
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (segments.isEmpty) return null;

    final rootName = path.basename(root).toLowerCase();
    final category = segments.first.toLowerCase();
    if (!categories.contains(category)) {
      // Compatibility with the first iOS preview which stored paths relative
      // to the chosen folder without a category prefix.
      return path.join(root, localCloudPath);
    }

    final internalPath = segments.length > 1
        ? segments.sublist(1).join(Platform.pathSeparator)
        : '';
    if (internalPath.isEmpty) return null;

    if (categories.contains(rootName)) {
      if (rootName != category) return null;
      return path.join(root, internalPath);
    }
    return path.join(root, category, internalPath);
  }

  ({String profileId, String saveDirectory, String internalPath})?
  _parseRpcs3SaveLocation(File file, String dataRoot) {
    final relative = path
        .relative(file.path, from: dataRoot)
        .replaceAll('\\', '/');
    if (relative == '..' || relative.startsWith('../')) return null;
    final segments = relative
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (segments.length < 6 ||
        segments[0].toLowerCase() != 'dev_hdd0' ||
        segments[1].toLowerCase() != 'home' ||
        segments[3].toLowerCase() != 'savedata') {
      return null;
    }
    if (segments.any((part) => part == '.' || part == '..')) return null;
    return (
      profileId: segments[2],
      saveDirectory: segments[4],
      internalPath: segments.sublist(5).join('/'),
    );
  }

  String? _rpcs3TitleIdFromSaveDirectory(String value) {
    final match = RegExp(r'^([A-Za-z]{4}[0-9]{5})').firstMatch(value.trim());
    return match?.group(1)?.toUpperCase();
  }

  Future<({String cloudPath, String gameName, String titleId})?>
  _resolveRpcs3FileForCloud(
    File file,
    String dataRoot, {
    GameModel? preferredGame,
  }) async {
    final location = _parseRpcs3SaveLocation(file, dataRoot);
    if (location == null) return null;

    var saveTitleId = _rpcs3TitleIdFromSaveDirectory(location.saveDirectory);
    String? sfoTitle;
    final sfo = File(
      path.join(
        dataRoot,
        'dev_hdd0',
        'home',
        location.profileId,
        'savedata',
        location.saveDirectory,
        'PARAM.SFO',
      ),
    );
    if (sfo.existsSync()) {
      try {
        // ignore: invalid_use_of_visible_for_testing_member
        final values = Rpcs3LibraryService.parseParamSfoBytes(
          await sfo.readAsBytes(),
        );
        final sfoId = values['TITLE_ID']?.toString().trim() ?? '';
        if ((saveTitleId == null || saveTitleId.isEmpty) && sfoId.isNotEmpty) {
          saveTitleId = sfoId.toUpperCase();
        }
        sfoTitle = values['TITLE']?.toString().trim();
      } catch (e) {
        NeoSyncProvider._log.w('Could not parse RPCS3 save PARAM.SFO: $e');
      }
    }

    String? preferredTitleId = preferredGame?.titleId?.trim().toUpperCase();
    if (preferredGame != null &&
        (preferredTitleId == null || preferredTitleId.isEmpty)) {
      final dbId = await GameRepository.getTitleIdForGame(
        preferredGame.romname,
        preferredGame.name,
      );
      preferredTitleId = dbId?.trim().toUpperCase();
      preferredTitleId ??= _rpcs3TitleIdFromSaveDirectory(
        preferredGame.romname,
      );
    }

    if (preferredGame != null &&
        preferredTitleId != null &&
        preferredTitleId.isNotEmpty &&
        saveTitleId != null &&
        saveTitleId.isNotEmpty &&
        preferredTitleId != saveTitleId) {
      return null;
    }

    final cached = Rpcs3LibraryService.cachedGameForTitleId(saveTitleId);
    var canonicalName = cached?.title.trim() ?? '';
    if (canonicalName.isEmpty) {
      canonicalName = sfoTitle ?? '';
    }
    if (canonicalName.isEmpty) {
      canonicalName = saveTitleId ?? location.saveDirectory;
    }

    if (preferredGame != null &&
        (preferredTitleId == null || preferredTitleId.isEmpty)) {
      final expected = <String>{
        CloudPathBuilder.sanitizeGameName(preferredGame.name).toLowerCase(),
        if (preferredGame.titleName != null &&
            preferredGame.titleName!.trim().isNotEmpty)
          CloudPathBuilder.sanitizeGameName(preferredGame.titleName!)
              .toLowerCase(),
      };
      final actual = CloudPathBuilder.sanitizeGameName(canonicalName)
          .toLowerCase();
      if (!expected.contains(actual)) return null;
    }

    final gameName = preferredGame?.name.trim().isNotEmpty == true
        ? preferredGame!.name.trim()
        : canonicalName;
    final cloudPath = CloudPathBuilder.build(
      system: 'ps3',
      emulatorSlug: 'rpcs3',
      scope: 'game',
      gameName: gameName,
      filePath:
          '${location.profileId}/${location.saveDirectory}/${location.internalPath}',
      isState: false,
    );
    return (
      cloudPath: cloudPath,
      gameName: gameName,
      titleId: saveTitleId ?? '',
    );
  }

  String? _resolveRpcs3CloudFileToLocal(String dataRoot, String cloudFilePath) {
    final segments = cloudFilePath
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (segments.length < 3 ||
        segments.any((part) => part == '.' || part == '..')) {
      return null;
    }
    final profileId = segments[0];
    final saveDirectory = segments[1];
    final internal = segments.sublist(2).join(Platform.pathSeparator);
    return path.join(
      dataRoot,
      'dev_hdd0',
      'home',
      profileId,
      'savedata',
      saveDirectory,
      internal,
    );
  }

  bool _isMeloNXTitleId(String value) {
    final normalized = value.trim();
    return normalized.toLowerCase() != '0000000000000000' &&
        RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(normalized);
  }

  /// Extracts the Switch Title ID from a MeloNX save path while preserving the
  /// path *inside* that game's save directory. The Title ID is a local lookup
  /// key only and is never used as the NeoSync-visible game name.
  ({String titleId, String internalPath})? _parseMeloNXSaveLocation(
    File file,
    String root,
  ) {
// DOLPHIN_ISOLATION_BEGIN: neosync_strict_melonx_source
    return NeoSyncSavePolicy.melonxLocation(file.path, root);
// DOLPHIN_ISOLATION_END: neosync_strict_melonx_source
  }

  Future<String?> _meloNXTitleIdForGame(GameModel game) async {
    var titleId = game.titleId?.trim();
    if (titleId == null || titleId.isEmpty) {
      titleId = await GameRepository.getTitleIdForGame(game.romname, game.name);
    }
    if (titleId == null || !_isMeloNXTitleId(titleId)) return null;
    return titleId;
  }

  /// Builds the canonical NeoSync v2 path for a MeloNX file. The Title ID is
  /// deliberately removed from the cloud path; NeoSync shows the game title.
  Future<({String cloudPath, String gameName, String titleId})?>
  _resolveMeloNXFileForCloud(
    File file,
    String root, {
    GameModel? preferredGame,
  }) async {
    final location = _parseMeloNXSaveLocation(file, root);
    if (location == null) return null;

    String? gameName;
    String? preferredTitleId;
    if (preferredGame != null) {
      preferredTitleId = await _meloNXTitleIdForGame(preferredGame);
    }
    if (preferredGame != null &&
        preferredTitleId != null &&
        preferredTitleId.toLowerCase() == location.titleId.toLowerCase()) {
      gameName = preferredGame.name.trim();
    }

    if (gameName == null || gameName.isEmpty) {
      final row = await GameRepository.findSwitchGameByTitleId(
        location.titleId,
      );
      if (row == null) return null;
      final title = row['title_name']?.toString().trim() ?? '';
      final filename = row['filename']?.toString().trim() ?? '';
      gameName = title.isNotEmpty
          ? title
          : path.basenameWithoutExtension(filename);
    }
    if (gameName.isEmpty) return null;

    final cloudPath = CloudPathBuilder.build(
      system: 'switch',
      emulatorSlug: 'melonx',
      scope: 'game',
      gameName: gameName,
      filePath: location.internalPath,
      isState: false,
    );
    return (
      cloudPath: cloudPath,
      gameName: gameName,
      titleId: location.titleId,
    );
  }

  /// Finds the local MeloNX save directory for a game. Existing Title-ID
  /// directories are preferred. If the game directory does not exist yet, use
  /// the standard bis/user/save/... structure only when its user root already
  /// exists, avoiding creation of guessed account directories.
  String? _resolveMeloNXGameSaveDirectory(
    String root,
    String titleId, {
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_0_1
    String? profileId,
    String? saveId,
// DOLPHIN_ISOLATION_END: neosync_repair205_0_1
  }) {
    // DOLPHIN_ISOLATION_BEGIN: neosync_melonx_native_restore
    final matches = <String>{};
    for (final saveBase in NeoSyncSavePolicy.melonxSaveRoots(root)) {
      try {
        for (final entity in Directory(saveBase).listSync(
            recursive: true, followLinks: false).whereType<Directory>()) {
          final location = NeoSyncSavePolicy.melonxSaveLocation(
              path.join(entity.path, '__save_probe__'), root);
          if (location == null ||
              location.titleId.toLowerCase() != titleId.toLowerCase() ||
              (profileId != null && location.profileId != profileId) ||
              (saveId != null && location.saveId != saveId)) continue;
          matches.add(location.payloadRoot);
        }
      } on FileSystemException catch (e) {
        NeoSyncProvider._log.w('Could not inspect MeloNX committed saves: $e');
      }
    }
    // A different profile/container is never silently selected. Creation of a
    // native LibHac save requires its indexer: let the emulator create it first.
    return matches.length == 1 ? matches.single : null;
    // DOLPHIN_ISOLATION_END: neosync_melonx_native_restore
  }

  /// Resolves a local save file back to its library game.
  Future<GameModel?> _gameForSaveFile(File file) async {
    final saveBase = path.basenameWithoutExtension(file.path);
    try {
      // DOLPHIN_ISOLATION_BEGIN: neosync_shared_flycast_game
      final systemRoot = await _getRetroArchSystemPath();
      if (systemRoot != null && NeoSyncSaveSource.resolve(
          filePath: file.path, rootPath: path.join(systemRoot, 'dc'),
          family: NeoSyncSaveFamily.retroArchFlycastSystem) != null) {
        return GameModel(name: 'Dreamcast Memory Cards', realname: 'Dreamcast Memory Cards',
            romname: 'Dreamcast Memory Cards', systemFolderName: 'dc', coreName: 'flycast',
            year: '', developer: '', publisher: '', genre: '', players: '', rating: 0);
      }
      // DOLPHIN_ISOLATION_END: neosync_shared_flycast_game
      // DOLPHIN_ISOLATION_BEGIN: neosync_psp_savedata_game
      final psp = RegExp(r'(?:^|/)(?:PSP/)?SAVEDATA/([A-Za-z]{4}[0-9]{5})[^/]*/',
          caseSensitive: false).firstMatch(file.path.replaceAll('\\', '/'));
      if (psp != null) {
        final titleId = psp[1]!.toUpperCase();
        final normalizedPath = file.path.replaceAll('\\', '/');
        final saveDirectory = normalizedPath.substring(0, psp.end);
        final sfo = File(path.join(saveDirectory, 'PARAM.SFO'));
        String? nativeTitle;
        try {
          if (FileSystemEntity.typeSync(sfo.path, followLinks: false) ==
                  FileSystemEntityType.file &&
              sfo.lengthSync() <= 1024 * 1024) {
            // PSP and PS3 share the PSF metadata container. Do not infer the
            // game from one of its savedata members such as ICON0 or PLAYDATA.
            // ignore: invalid_use_of_visible_for_testing_member
            final values = Rpcs3LibraryService.parseParamSfoBytes(await sfo.readAsBytes());
            final title = values['TITLE']?.toString().trim();
            if (title != null && title.isNotEmpty) nativeTitle = title;
          }
        } catch (e) {
          NeoSyncProvider._log.w('Could not read PSP savedata identity: $e');
        }
        final libraries = await Future.wait([
          GameRepository.loadGamesForSystem('psp'),
          GameRepository.loadGamesForSystem('pspminis'),
        ]);
        final games = libraries.expand((rows) => rows).toList();
        var candidates = games.where((row) =>
            row.titleId?.toUpperCase() == titleId ||
            row.filename.toUpperCase().contains(titleId)).toList();
        if (candidates.isEmpty && nativeTitle != null) {
          String normalize(String value) => value.toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9]'), '');
          final wanted = normalize(nativeTitle);
          if (wanted.isNotEmpty) {
            candidates = games.where((row) => <String?>[
              row.titleName, row.realName, row.screenscraperRealName,
              path.basenameWithoutExtension(row.filename),
            ].any((name) => name != null && normalize(name) == wanted)).toList();
          }
        }
        if (candidates.length == 1) {
          return GameModel.fromDatabaseModel(candidates.single).copyWith(
              coreName: candidates.single.coreName ?? 'ppsspp');
        }
        // Native saves remain eligible even before their ROM is imported.
        // The serial identifies the savedata directory; the title is display
        // metadata only, while the complete native path is kept in the key.
        final title = nativeTitle ?? titleId;
        return GameModel(name: title, realname: title, romname: titleId,
            systemFolderName: 'psp', titleId: titleId, coreName: 'ppsspp',
            year: '', developer: '', publisher: '', genre: '', players: '', rating: 0);
      }
      // DOLPHIN_ISOLATION_END: neosync_psp_savedata_game
      final row = await GameRepository.findRomByFilenamePrefix(saveBase);
      if (row == null) return null;
      // DOLPHIN_ISOLATION_BEGIN: neosync_retain_core_metadata
      final folder = row['folder_name']?.toString();
      if (folder != null) {
        final candidates = (await GameRepository.loadGamesForSystem(folder))
            .where((item) => item.filename == row['filename']).toList();
        if (candidates.length == 1) {
          return GameModel.fromDatabaseModel(candidates.single);
        }
      }
      // DOLPHIN_ISOLATION_END: neosync_retain_core_metadata
      final romname = row['filename']?.toString() ?? saveBase;
      final title = row['title_name']?.toString();
      return GameModel(
        name: (title == null || title.isEmpty) ? romname : title,
        realname: (title == null || title.isEmpty) ? romname : title,
        romname: romname,
        systemFolderName: row['folder_name']?.toString(),
        emulatorName: row['emulator_name']?.toString(),
        year: '',
        developer: '',
        publisher: '',
        genre: '',
        players: '',
        rating: 0.0,
      );
    } catch (e) {
      NeoSyncProvider._log.w('Could not map save ${file.path} to a game: $e');
      return null;
    }
  }

  /// Builds the canonical NeoSync v2 path for a local game save/state.
  /// Never falls back to a v1 cloud path.
  Future<String> _calculateSyncRelativePath(
    GameModel game,
    File file,
    String basePath, {
    bool isState = false,
  }) async {
    final systemFolder =
        game.systemFolderName ??
        await GameRepository.getSystemFolderForGame(game.romname);
    if (systemFolder == null || systemFolder.isEmpty) {
      throw StateError(
        'NeoSync v2: system could not be resolved for ${game.romname}',
      );
    }

    // DOLPHIN_ISOLATION_BEGIN: neosync_flycast_native_key
    if (systemFolder.toLowerCase() == 'dc') {
      final systemRoot = await _getRetroArchSystemPath();
      if (systemRoot != null) {
        final source = NeoSyncSaveSource.resolve(filePath: file.path,
            rootPath: path.join(systemRoot, 'dc'),
            family: NeoSyncSaveFamily.retroArchFlycastSystem);
        if (source != null) {
          return CloudPathBuilder.build(system: 'dc', emulatorSlug: 'retroarch.flycast',
              scope: 'shared', filePath: source.relativePath);
        }
      }
    }
    // DOLPHIN_ISOLATION_END: neosync_flycast_native_key
    // DOLPHIN_ISOLATION_BEGIN: neosync_core_identity
    String? emulatorSlug;
    final relative = path.relative(file.path, from: basePath);
    if (game.coreName?.trim().isNotEmpty == true) {
      emulatorSlug = CloudPathBuilder.retroArchCoreSlug(game.coreName!);
    } else if (game.emulatorName?.trim().isNotEmpty == true) {
      final candidate = CloudPathBuilder.slugFromEmulatorUniqueId(game.emulatorName!);
      if (candidate.startsWith('retroarch.')) emulatorSlug = candidate;
    }
    // A native PSP/SAVEDATA/card folder is not a core name. When the library
    // lacks core metadata, a single-file save's immediate core directory can
    // still identify its owner; nested native bundles require real metadata.
    final segments = relative.replaceAll('\\', '/').split('/');
    if (emulatorSlug == null && segments.length == 2 &&
        !const ['psp', 'savedata', 'memcards', 'savestates', 'sstates']
            .contains(segments.first.toLowerCase())) {
      emulatorSlug = CloudPathBuilder.retroArchCoreSlug(segments.first);
    }
    // DOLPHIN_ISOLATION_END: neosync_core_identity
    if (emulatorSlug == null || emulatorSlug.isEmpty) {
      throw StateError(
        'NeoSync v2: emulator/core could not be resolved for ${game.romname}',
      );
    }

    final lowerName = path.basename(file.path).toLowerCase();
    final systemLower = systemFolder.toLowerCase();
    final isSharedCard =
        (systemLower == 'ps2' && lowerName.endsWith('.ps2')) ||
        ((systemLower == 'dc' || systemLower == 'dreamcast') &&
            lowerName.contains('vmu_save'));

    // DOLPHIN_ISOLATION_BEGIN: neosync_native_relative_path
    // Keep payload directories after the optional core folder. Flattening
    // PARAM.SFO/main/icon.sys destroys native savedata and card identities.
    if (relative.startsWith('..') || path.isAbsolute(relative)) {
      throw StateError('Save is outside its configured root');
    }
    var nativeParts = relative.replaceAll('\\', '/').split('/');
    if (nativeParts.length > 1 &&
        CloudPathBuilder.retroArchCoreSlug(nativeParts.first) == emulatorSlug) {
      nativeParts = nativeParts.sublist(1);
    }
    final nativePath = nativeParts.join('/');
    final directoryCard = systemLower == 'ps2' && !isState &&
        nativeParts.length > 1;
    final shared = isSharedCard || directoryCard;
    return CloudPathBuilder.build(
      system: systemFolder,
      emulatorSlug: emulatorSlug,
      scope: shared ? 'shared' : 'game',
      gameName: shared ? null : nativeParts.length > 1
          ? game.name : path.basenameWithoutExtension(file.path),
      filePath: nativePath,
      isState: isState,
    );
    // DOLPHIN_ISOLATION_END: neosync_native_relative_path
  }

  Future<String?> _retroArchCoreFolderForSlug(
    String emulatorSlug,
    String baseFolder,
  ) async {
    if (!emulatorSlug.startsWith('retroarch.')) return null;
    try {
      final base = Directory(baseFolder);
      if (!base.existsSync()) return null;
      for (final child
          in base.listSync(followLinks: false).whereType<Directory>()) {
        final name = path.basename(child.path);
        if (CloudPathBuilder.retroArchCoreSlug(name) == emulatorSlug) {
          return name;
        }
      }
    } catch (e) {
      NeoSyncProvider._log.w(
        'Could not map $emulatorSlug under $baseFolder: $e',
      );
    }
    return null;
  }

  /// Calcula la ruta relativa para sincronización
// DOLPHIN_ISOLATION_BEGIN: neosync_repair205_0_2


// DOLPHIN_ISOLATION_END: neosync_repair205_0_2
  /// Resuelve la ruta local para un archivo de la nube para un juego específico
  /// Resuelve la ruta local para un archivo de la nube para un juego específico
  /// Puede retornar múltiples rutas si el sistema lo requiere (ej. múltiples emuladores Switch)
  Future<List<String>> resolveCloudFileToLocalPath(
    GameModel game,
    NeoSyncFile cloudFile,
  ) async {
    // DOLPHIN_ISOLATION_BEGIN: dolphin_restore_path
    if (DolphinSaveTarget.ownsCloudPath(cloudFile.fileName) ||
        DolphinSaveTarget.ownsCloudPath(cloudFile.sourceSavePath) || _isDolphinGame(game)) {
      if (!_isDolphinGame(game)) return [];
      final target = cloudFile.dolphinTarget;
      if (target == null) return [];
      return _dolphinExclusive((store) async {
        final identity = await DolphinInternalV2Service.readSaveIdentity(game.systemFolderName!, game.romPath ?? '');
        return target.matches(identity) ? [(await store.cacheFile(target)).path] : <String>[];
      });
    }
    // DOLPHIN_ISOLATION_END: dolphin_restore_path

    final system = await _getSystemForGame(game);
    if (system == null) return [];

    // DOLPHIN_ISOLATION_BEGIN: neosync_restore_original_path
final v2Path = NeoSyncSavePolicy.canonical(cloudFile.sourceSavePath);
// DOLPHIN_ISOLATION_END: neosync_restore_original_path
    final isState = v2Path?.isState ?? cloudFile.fileName.startsWith('states/');
    final isSave = v2Path != null
        ? !v2Path.isState
        : cloudFile.fileName.startsWith('saves/');

    if (Platform.isIOS && v2Path != null) {
      if (v2Path.emulatorSlug == 'armsx2') {
        final root = ConfigService.linkedArmsx2FolderPath;
        if (root != null && root.isNotEmpty) {
          final local = _resolveArmsx2CloudFileToLocal(root, v2Path.filePath);
          return local == null ? [] : [local];
        }
      } else if (v2Path.emulatorSlug == 'rpcs3') {
        final root = Rpcs3LibraryService.linkedDataPath;
        if (root != null && root.isNotEmpty) {
          final local = _resolveRpcs3CloudFileToLocal(root, v2Path.filePath);
          return local == null ? [] : [local];
        }
      } else if (v2Path.emulatorSlug == 'melonx') {
        final root = ConfigService.linkedMelonxSaveFolderPath;
        if (root != null && root.isNotEmpty) {
          final titleId = await _meloNXTitleIdForGame(game);
          if (titleId == null) return [];
          // DOLPHIN_ISOLATION_BEGIN: neosync_melonx_profile_restore
          final parts = v2Path.filePath.split('/');
          final native = parts.length >= 5 && parts.first == 'profiles';
          if (native && parts[2].toLowerCase() != titleId.toLowerCase()) return [];
          final gameSaveRoot = _resolveMeloNXGameSaveDirectory(
            root,
            titleId,
            profileId: native ? parts[1] : null,
            saveId: native ? parts[3] : null,
          );
          if (gameSaveRoot == null) return [];
          final payload = native ? parts.sublist(4).join('/') : v2Path.filePath;
          return [path.join(gameSaveRoot, payload)];
          // DOLPHIN_ISOLATION_END: neosync_melonx_profile_restore
        }
      }
    }

    // DOLPHIN_ISOLATION_BEGIN: neosync_flycast_native_restore
    if (v2Path != null && !v2Path.isState && v2Path.system == 'dc' &&
        v2Path.emulatorSlug == 'retroarch.flycast' && v2Path.scope == 'shared' &&
        RegExp(r'^(?:system/dc/)?vmu_save_[A-D][12]\.bin$', caseSensitive: false)
            .hasMatch(v2Path.filePath)) {
      final systemRoot = await _getRetroArchSystemPath();
      return systemRoot == null ? []
          : [path.join(systemRoot, 'dc', path.basename(v2Path.filePath))];
    }
    // DOLPHIN_ISOLATION_END: neosync_flycast_native_restore
    // DOLPHIN_ISOLATION_BEGIN: neosync_native_restore_boundary
    if (v2Path != null && const ['armsx2', 'rpcs3', 'melonx']
        .contains(v2Path.emulatorSlug)) return [];
    final resolvedFolders = await resolveUniversalPaths(
      system, game: game, ensureExists: false,
    );
    if (resolvedFolders.isEmpty) return [];
    // DOLPHIN_ISOLATION_END: neosync_native_restore_boundary

    // Buscar la carpeta más apropiada.
    String targetFolder = resolvedFolders.first;

    if (isState) {
      final statesPath = await _getRetroArchStatesPath();
      if (statesPath != null) {
        targetFolder = statesPath;
      } else {
        // Fallback: buscar carpeta que parezca de states
        for (final folder in resolvedFolders) {
          if (folder.toLowerCase().contains('state') ||
              folder.toLowerCase().contains('sstates')) {
            targetFolder = folder;
            break;
          }
        }
      }
    } else if (isSave) {
      final savesPath = await _getRetroArchSavesPath();
      if (savesPath != null) {
        targetFolder = savesPath;
      } else {
        // Fallback: buscar carpeta que parezca de saves
        for (final folder in resolvedFolders) {
          if (folder.toLowerCase().contains('save') ||
              folder.toLowerCase().contains('memcards')) {
            targetFolder = folder;
            break;
          }
        }
      }
    }

    // Limpiar el nombre del archivo (quitar prefijos 'saves/' o 'states/')
    String relativeName = cloudFile.fileName;
    if (v2Path != null) {
      relativeName = v2Path.filePath;
      if (v2Path.emulatorSlug.startsWith('retroarch.')) {
        final coreFolder = await _retroArchCoreFolderForSlug(
          v2Path.emulatorSlug,
          targetFolder,
        );
        // DOLPHIN_ISOLATION_BEGIN: neosync_structured_native_core_folder
        final nativeCoreFolder = coreFolder ?? cloudFile.nativeRetroArchCoreFolder;
        if (nativeCoreFolder != null && nativeCoreFolder.isNotEmpty) {
          relativeName = path.join(nativeCoreFolder, relativeName);
        }
        // DOLPHIN_ISOLATION_END: neosync_structured_native_core_folder
      }
    } else if (isState) {
      relativeName = relativeName.replaceFirst(RegExp(r'^states[/\\]'), '');
    } else if (isSave) {
      relativeName = relativeName.replaceFirst(RegExp(r'^saves[/\\]'), '');
    }

    // Para sistemas con memory cards compartidas (PS2, Dreamcast), el relativeName ya es el filename
    // si usamos el logic de _calculateSyncRelativePath inverso.
    // Pero en general, cloudFile.fileName is 'saves/subfolder/file.ext'.
    // The relativeName after removing 'saves/' is 'subfolder/file.ext'.

    // Identificación robusta para Switch
    final isSwitch =
        system.id?.toLowerCase() == 'switch' ||
        system.folderName.toLowerCase() == 'switch' ||
        game.systemId?.toLowerCase() == 'switch' ||
        game.systemFolderName?.toLowerCase() == 'switch';

    if (isSwitch && isSave) {
      String? titleId = game.titleId;

      // Si no tenemos titleId, intentar recuperarlo de la BD con búsqueda más flexible
      if (titleId == null || titleId.isEmpty) {
        try {
          titleId = await GameRepository.getTitleIdForGame(
            game.romname,
            game.name,
          );
        } catch (e) {
          NeoSyncProvider._log.e(
            'Error fetching titleId via flexible lookup: $e',
          );
        }
      }

      // FALLBACK: Si todavía no hay titleId, intentar extraerlo del ROM real
      if ((titleId == null || titleId.isEmpty) && game.romPath != null) {
        try {
          final info = await SwitchTitleExtractor.extractGameInfo(
            game.romPath!,
          );
          if (info != null) {
            titleId = info.titleId;

            try {
              await GameRepository.updateGameTitleId(game.romname, titleId);
            } catch (dbError) {
              NeoSyncProvider._log.e(
                'Error updating DB with extracted titleId: $dbError',
              );
            }
          }
        } catch (e) {
          NeoSyncProvider._log.e('Error extracting titleId from ROM: $e');
        }
      }

      if (titleId != null && titleId.isNotEmpty) {
        final List<String> resultPaths = [];

        // relativeName is similar to `eden/A Short Hike/ExtraData1/file.dat`
        final parts = relativeName.split(RegExp(r'[/\\]'));
        String internalPath = path.basename(relativeName);
        String? emulatorPrefix;

        // Si tenemos la estructura de 3 niveles (emulator/game/internal), extraemos el internal y el prefix
        if (parts.length >= 3) {
          emulatorPrefix = parts[0].toLowerCase();
          internalPath = parts.sublist(2).join(Platform.pathSeparator);
        }

        final allEmulators = await SwitchSaveDetector.detectEmulatorNandPaths();

        // Filtrar emuladores basándonos en el prefijo del archivo de la nube para independencia
        List<EmulatorNandInfo> emulators = allEmulators;
        if (emulatorPrefix != null) {
          emulators = allEmulators.where((emu) {
            final name = emu.emulatorName.toLowerCase();
            // Match flexible: 'eden' -> 'Eden', 'Eden Legacy', 'Eden Optimized', etc.
            return name.contains(emulatorPrefix!);
          }).toList();

          if (emulators.isEmpty) {
            return [];
          }
        }

        if (emulators.isNotEmpty) {
          for (final emu in emulators) {
            // 1. Intentar encontrar save existente para este emulador
            final saveInfo = await SwitchSaveDetector.findSaveForTitleId(
              emu.nandDirectory,
              titleId,
            );

            if (saveInfo != null) {
              final fullPath = path.join(saveInfo.savePath, internalPath);
              resultPaths.add(fullPath);
            } else {
              // 2. Si no existe, construir la ruta en este NAND
              final saveBasePath = path.join(
                emu.nandDirectory,
                'user',
                'save',
                '0000000000000000',
              );
              final saveBaseDir = Directory(saveBasePath);

              // Buscar el primer directorio de usuario disponible o usar default
              String userId = '00000000000000000000000000000000';
              if (saveBaseDir.existsSync()) {
                final entities = saveBaseDir.listSync().whereType<Directory>();
                if (entities.isNotEmpty) {
                  userId = path.basename(entities.first.path);
                }
              }

              final fullPath = path.join(
                saveBasePath,
                userId,
                titleId,
                internalPath,
              );
              resultPaths.add(fullPath);
            }
          }
        }

        if (resultPaths.isNotEmpty) return resultPaths;
      }
    }

    return [path.join(targetFolder, relativeName)];
  }

  // =========================================
  // RETROARCH PATH HELPERS (Centralized)
  // =========================================

  Future<String?> _getRetroArchSavesPath() async {
    try {
      final config = await RetroArchConfigService().getMergedConfig();
      return config.savefileDirectory;
    } catch (e) {
      NeoSyncProvider._log.e('Error getting RetroArch saves path: $e');
      return null;
    }
  }

  Future<String?> _getRetroArchStatesPath() async {
    try {
      final config = await RetroArchConfigService().getMergedConfig();
      return config.savestateDirectory;
    } catch (e) {
      NeoSyncProvider._log.e('Error getting RetroArch states path: $e');
      return null;
    }
  }

  Future<String?> _getRetroArchSystemPath() async {
    try {
      final config = await RetroArchConfigService().getMergedConfig();
      return config.systemDirectory;
    } catch (e) {
      NeoSyncProvider._log.e('Error getting RetroArch system path: $e');
      return null;
    }
  }

  // =========================================
  // HELPER METHODS (Restored/Moved)
  // =========================================

  /// Gets all save files recursively from a directory
  Future<List<File>> _getSaveFiles(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return [];
    // DOLPHIN_ISOLATION_BEGIN: neosync_root_owned_scan
    final saves = await _getRetroArchSavesPath();
    final states = await _getRetroArchStatesPath();
    final systemRoot = await _getRetroArchSystemPath();
    final flycast = systemRoot == null ? null : path.join(systemRoot, 'dc');
    final arms = ConfigService.linkedArmsx2FolderPath;
    final rpcs3 = Rpcs3LibraryService.linkedDataPath;
    final melonx = ConfigService.linkedMelonxSaveFolderPath;
    bool contains(String? root) => root != null && root.isNotEmpty &&
        (path.equals(root, directoryPath) || path.isWithin(root, directoryPath));
    final NeoSyncSaveFamily? family;
    final String? root;
    if (contains(flycast)) {
      family = NeoSyncSaveFamily.retroArchFlycastSystem;
      root = flycast;
    } else if (contains(melonx)) {
      family = NeoSyncSaveFamily.melonx;
      root = melonx;
    } else if (contains(rpcs3)) {
      family = NeoSyncSaveFamily.rpcs3;
      root = rpcs3;
    } else if (contains(arms)) {
      family = NeoSyncSaveFamily.armsx2;
      root = arms;
    } else if (contains(states)) {
      family = NeoSyncSaveFamily.retroArchStates;
      root = states;
    } else if (contains(saves)) {
      family = NeoSyncSaveFamily.retroArchSaves;
      root = saves;
    } else {
      family = null;
      root = null;
    }
    final scanRoots = family == NeoSyncSaveFamily.melonx
        ? NeoSyncSavePolicy.melonxSaveRoots(directoryPath) : [directoryPath];
    try {
      final result = <File>[];
      for (final scan in scanRoots) {
        await for (final entity in Directory(scan).list(
            recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          if (family != null && root != null) {
            if (NeoSyncSaveSource.resolve(filePath: entity.path,
                rootPath: root, family: family) != null) result.add(entity);
          } else if (NeoSyncSavePolicy.classify(entity.path) == NeoSyncSaveKind.save) {
            result.add(entity);
          }
        }
      }
      return result;
    } catch (e) {
      NeoSyncProvider._log.e('Error listing save files in $directoryPath: $e');
      return [];
    }
    // DOLPHIN_ISOLATION_END: neosync_root_owned_scan
  }

  /// Calculates relative path for Switch saves
  /// Format: saves/[emulator]/[Game Name]/[internal_structure]
  Future<String> calculateSwitchRelativePath(File file, GameModel game) async {
    final sanitizedGameName = game.name.replaceAll(
      RegExp(r'[<>:"/\\|?*]'),
      '_',
    );

    String emulatorName = 'switch';
    final lowerPath = file.path.toLowerCase();

    // First, try to detect based on known NAND directories
    try {
      final emulators = await SwitchSaveDetector.detectEmulatorNandPaths();
      for (final emu in emulators) {
        if (path.isWithin(emu.nandDirectory, file.path) ||
            file.path.startsWith(emu.nandDirectory)) {
          final nameLower = emu.emulatorName.toLowerCase();
          if (nameLower.contains('eden')) {
            emulatorName = 'eden';
          } else if (nameLower.contains('citron')) {
            emulatorName = 'citron';
          } else if (nameLower.contains('yuzu')) {
            emulatorName = 'yuzu';
          } else if (nameLower.contains('suyu')) {
            emulatorName = 'suyu';
          } else if (nameLower.contains('sudachi')) {
            emulatorName = 'sudachi';
          }
          break;
        }
      }
    } catch (e) {
      NeoSyncProvider._log.e('Error checking emulator nand paths: $e');
    }

    // Fallback if not found via NAND
    if (emulatorName == 'switch') {
      if (lowerPath.contains('eden') || lowerPath.contains('yuanshen')) {
        emulatorName = 'eden';
      } else if (lowerPath.contains('citron')) {
        emulatorName = 'citron';
      } else if (lowerPath.contains('yuzu')) {
        emulatorName = 'yuzu';
      } else if (lowerPath.contains('suyu')) {
        emulatorName = 'suyu';
      } else if (lowerPath.contains('sudachi')) {
        emulatorName = 'sudachi';
      }
    }

    String internalPath = path.basename(file.path);

    // Try to preserve internal structure after the Title ID
    final pathParts = file.path.split(Platform.pathSeparator);
    final saveIndex = pathParts.indexOf('save');
    if (saveIndex != -1 && saveIndex + 3 < pathParts.length) {
      if (saveIndex + 4 < pathParts.length) {
        internalPath = pathParts.sublist(saveIndex + 4).join('/');
      }
    }

    return path
        .join('saves', emulatorName, sanitizedGameName, internalPath)
        .replaceAll('\\', '/');
  }

  Future<String?> _getPCSX2MemcardsPath() async {
    if (Platform.isAndroid) {
      final possiblePaths = [
        '/storage/emulated/0/Android/data/xyz.aethersx2.android/files/memcards',
        '/storage/emulated/0/Android/data/com.aethersx2.android/files/memcards',
      ];
      for (final p in possiblePaths) {
        if (Directory(p).existsSync()) return p;
      }
      return null;
    } else if (Platform.isWindows) {
      // 1. Try database
      try {
        final exePath = await EmulatorRepository.getEmulatorPath(
          '%pcsx2%',
          '%PCSX2%',
        );
        if (exePath != null) {
          final dir = path.dirname(exePath);
          final portable = path.join(dir, 'memcards');
          if (Directory(portable).existsSync()) return portable;
        }
      } catch (e) {
        /* ignore */
      }

      // 2. Try standard Documents location
      final docs = path.join(
        Platform.environment['USERPROFILE'] ?? '',
        'Documents',
        'PCSX2',
        'memcards',
      );
      if (Directory(docs).existsSync()) return docs;
    }
    return null;
  }

  Future<String?> _getFlycastSavesPath() async {
    if (Platform.isAndroid) {
      // RetroArch is usually used for DC on Android, or Flycast standalone
      final possible =
          '/storage/emulated/0/Android/data/com.flycast.emulator/files/data';
      if (Directory(possible).existsSync()) return possible;
      return null;
    } else if (Platform.isWindows) {
      // 1. Try database
      try {
        final exePath = await EmulatorRepository.getEmulatorPath(
          '%flycast%',
          '%Flycast%',
        );
        if (exePath != null) {
          final dir = path.dirname(exePath);
          final dataDir = path.join(dir, 'data');
          if (Directory(dataDir).existsSync()) return dataDir;
          if (Directory(dir).existsSync()) return dir;
        }
      } catch (e) {
        /* ignore */
      }
    }
    return null;
  }

  /// Scans NAND save directories across detected emulators to find which titleId
  /// belongs to the given ROM. Used as last resort when titleId is not in the DB
  /// and cannot be extracted from the ROM file (e.g., installed titles on Android).
  Future<String?> _findTitleIdByNandScan(
    List<EmulatorNandInfo> nands,
    String romname,
  ) async {
    for (final nand in nands) {
      try {
        final saveBasePath = path.join(
          nand.nandDirectory,
          'user',
          'save',
          '0000000000000000',
        );
        final saveBaseDir = Directory(saveBasePath);
        if (!saveBaseDir.existsSync()) continue;

        // List userId dirs (one level deep — fast)
        final userIdDirs = saveBaseDir.listSync().whereType<Directory>();
        for (final userIdDir in userIdDirs) {
          final titleIdDirs = userIdDir.listSync().whereType<Directory>();
          for (final titleIdDir in titleIdDirs) {
            final candidate = path.basename(titleIdDir.path);
            try {
              final row = await GameRepository.findSwitchGameByTitleId(
                candidate,
              );
              if (row != null && row['filename'].toString() == romname) {
                NeoSyncProvider._log.i(
                  'Resolved titleId "$candidate" for $romname via NAND scan',
                );
                return candidate;
              }
            } catch (e) {
              NeoSyncProvider._log.e(
                'Error finding Switch game by titleId $candidate: $e',
              );
            }
          }
        }
      } catch (e) {
        NeoSyncProvider._log.e(
          'Error scanning NAND directory for ${nand.emulatorName}: $e',
        );
      }
    }
    return null;
  }
}
