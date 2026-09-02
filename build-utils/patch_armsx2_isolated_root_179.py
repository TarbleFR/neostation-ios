from pathlib import Path


def replace_once(file_path: str, old: str, new: str, label: str) -> None:
    p = Path(file_path)
    text = p.read_text(encoding='utf-8')
    if old not in text:
        raise SystemExit(f'{label}: anchor not found in {file_path}')
    p.write_text(text.replace(old, new, 1), encoding='utf-8')


# ---------------------------------------------------------------------------
# ConfigService: ARMSX2 owns exactly one root bookmark.
# ---------------------------------------------------------------------------
config = 'lib/services/config_service.dart'
replace_once(
    config,
    """  static String? linkedArmsx2FolderPath;\n\n  /// iOS-only NeoSync save roots. These bookmarks are intentionally\n  /// separate from ROM/library folders so cloud-save configuration never\n  /// changes game discovery or launch paths.\n  static const String armsx2NeoSyncBookmarkKey = 'neosync-armsx2-saves';\n  static const String melonxNeoSyncBookmarkKey = 'neosync-melonx-saves';\n  static String? linkedArmsx2SaveFolderPath;\n  static String? linkedMelonxSaveFolderPath;\n""",
    """  static String? linkedArmsx2FolderPath;\n\n  /// Physical PS2 library derived from the one ARMSX2 root bookmark.\n  static String? linkedArmsx2GameFolderPath;\n\n  /// MeloNX keeps its own existing NeoSync bookmark. ARMSX2 does not: its\n  /// NeoSync paths are always derived from [linkedArmsx2FolderPath].\n  static const String melonxNeoSyncBookmarkKey = 'neosync-melonx-saves';\n  static String? linkedMelonxSaveFolderPath;\n""",
    'ConfigService isolated ARMSX2 root',
)


# ---------------------------------------------------------------------------
# Cold-start restore: canonical ARMSX2 root, legacy save bookmark migration only.
# Build 171 has already replaced the original two-root block with this normalizer.
# ---------------------------------------------------------------------------
main = 'lib/main.dart'
replace_once(
    main,
    "import 'package:neostation/services/armsx2_library_service.dart';\n",
    "import 'package:neostation/services/armsx2_library_service.dart';\n"
    "import 'package:neostation/services/armsx2_folder_service.dart';\n",
    'main ARMSX2 folder import',
)
replace_once(
    main,
    """    String? normalizeArmsx2Root(String? raw) {\n      if (raw == null || raw.trim().isEmpty) return null;\n      final original = raw.trim();\n      const categories = {'memcards', 'sstates', 'savestates'};\n      var current = Directory(original);\n      if (categories.contains(path.basename(current.path).toLowerCase())) {\n        current = current.parent;\n      }\n      for (var depth = 0; depth < 6; depth++) {\n        final hasSaveFolder = categories.any(\n          (name) => Directory(path.join(current.path, name)).existsSync(),\n        );\n        if (hasSaveFolder) return current.path;\n        final parent = current.parent;\n        if (parent.path == current.path) break;\n        current = parent;\n      }\n      return original;\n    }\n\n    ConfigService.linkedArmsx2FolderPath = normalizeArmsx2Root(\n      await ExternalFolderAccess.resolveBookmarkedFolder(key: 'armsx2'),\n    );\n    final dedicatedArmsx2NeoSyncRoot = normalizeArmsx2Root(\n      await ExternalFolderAccess.resolveBookmarkedFolder(\n        key: ConfigService.armsx2NeoSyncBookmarkKey,\n      ),\n    );\n    ConfigService.linkedArmsx2SaveFolderPath =\n        dedicatedArmsx2NeoSyncRoot ?? ConfigService.linkedArmsx2FolderPath;\n    ConfigService.linkedArmsx2FolderPath ??=\n        ConfigService.linkedArmsx2SaveFolderPath;\n""",
    """    // ARMSX2 has one security-scoped root for library + NeoSync.\n    final canonicalArmsx2Path =\n        await ExternalFolderAccess.resolveBookmarkedFolder(\n          key: Armsx2FolderService.bookmarkKey,\n        );\n    final legacyArmsx2Path =\n        await ExternalFolderAccess.resolveBookmarkedFolder(\n          key: Armsx2FolderService.legacyNeoSyncBookmarkKey,\n        );\n    final linkedArmsx2Path = canonicalArmsx2Path ?? legacyArmsx2Path;\n    if (linkedArmsx2Path != null && linkedArmsx2Path.trim().isNotEmpty) {\n      final root = await Armsx2FolderService.resolveRoot(linkedArmsx2Path);\n      ConfigService.linkedArmsx2FolderPath = root;\n      ConfigService.linkedArmsx2GameFolderPath =\n          await Armsx2FolderService.resolveGameDirectory(root);\n      log.i(\n        'ARMSX2 isolated root restored: root=$root '\n        'gameDir=${ConfigService.linkedArmsx2GameFolderPath ?? "none"}',\n      );\n    } else {\n      ConfigService.linkedArmsx2FolderPath = null;\n      ConfigService.linkedArmsx2GameFolderPath = null;\n    }\n""",
    'main isolated ARMSX2 root restore',
)


# ---------------------------------------------------------------------------
# Settings: Link Folder is the only ARMSX2 root action. Sync becomes a local
# rescan of that same root; it never opens the ARMSX2 library export deeplink.
# ---------------------------------------------------------------------------
settings = 'lib/screens/settings_screen/new_settings_options/directories_settings_content.dart'
replace_once(
    settings,
    "import 'package:neostation/services/armsx2_library_service.dart';\n",
    "import 'package:neostation/services/armsx2_library_service.dart';\n"
    "import 'package:neostation/services/armsx2_folder_service.dart';\n",
    'settings ARMSX2 folder import',
)
replace_once(
    settings,
    """  // iOS-only: live-linking RetroArch's external folder via a persisted\n  // security-scoped bookmark. ARMSX2 and MeloNX are sync-only and never\n  // expose a folder picker in this screen.\n""",
    """  // iOS-only security-scoped roots. RetroArch and ARMSX2 are completely\n  // independent bookmarks; MeloNX keeps its existing save-only bookmark.\n""",
    'settings iOS roots comment',
)

replace_once(
    settings,
    """  Future<void> _linkNeoSyncSaveFolder({\n""",
    """  Future<void> _linkArmsx2RootFolder() async {\n    if (_linkingFolderKey != null) return;\n    setState(() => _linkingFolderKey = Armsx2FolderService.bookmarkKey);\n    try {\n      final selected = await ExternalFolderAccess.pickAndBookmarkFolder(\n        key: Armsx2FolderService.bookmarkKey,\n      );\n      if (selected == null || !mounted) return;\n      final bookmarked = await ExternalFolderAccess.resolveBookmarkedFolder(\n        key: Armsx2FolderService.bookmarkKey,\n      );\n      final root = await Armsx2FolderService.resolveRoot(bookmarked ?? selected);\n      final gameDir = await Armsx2FolderService.resolveGameDirectory(root);\n      final previousGameDir = ConfigService.linkedArmsx2GameFolderPath;\n\n      ConfigService.linkedArmsx2FolderPath = root;\n      ConfigService.linkedArmsx2GameFolderPath = gameDir;\n\n      // New links use only `armsx2`. The old save-only bookmark is migration\n      // data and is removed as soon as the canonical root is linked.\n      await ExternalFolderAccess.clearBookmark(\n        key: Armsx2FolderService.legacyNeoSyncBookmarkKey,\n      );\n\n      if (!mounted) return;\n      final configProvider = Provider.of<SqliteConfigProvider>(\n        context,\n        listen: false,\n      );\n      if (previousGameDir != null &&\n          previousGameDir != gameDir &&\n          configProvider.config.romFolders.contains(previousGameDir)) {\n        await configProvider.removeRomFolder(previousGameDir);\n      }\n      if (gameDir != null && gameDir.isNotEmpty) {\n        if (configProvider.config.romFolders.contains(gameDir)) {\n          await configProvider.scanSystems();\n        } else {\n          await configProvider.addRomFolder(gameDir, scan: true);\n        }\n      }\n\n      if (!mounted) return;\n      await _loadCurrentPaths();\n      if (mounted) setState(() {});\n      _log.i('ARMSX2 isolated root linked: root=$root gameDir=${gameDir ?? "none"}');\n    } catch (e) {\n      _log.e('ARMSX2 root link failed: $e');\n      if (mounted) {\n        AppNotification.showNotification(\n          context,\n          AppLocale.iosEmuLinkingFailed\n              .getString(context)\n              .replaceFirst('{error}', e.toString()),\n          type: NotificationType.error,\n        );\n      }\n    } finally {\n      if (mounted) setState(() => _linkingFolderKey = null);\n    }\n  }\n\n  Future<void> _linkNeoSyncSaveFolder({\n""",
    'settings ARMSX2 root linker',
)

replace_once(
    settings,
    """      if (bookmarkKey == ConfigService.armsx2NeoSyncBookmarkKey) {\n        ConfigService.linkedArmsx2SaveFolderPath = activePath;\n      } else if (bookmarkKey == ConfigService.melonxNeoSyncBookmarkKey) {\n        ConfigService.linkedMelonxSaveFolderPath = activePath;\n      }\n""",
    """      if (bookmarkKey == ConfigService.melonxNeoSyncBookmarkKey) {\n        ConfigService.linkedMelonxSaveFolderPath = activePath;\n      }\n""",
    'settings remove ARMSX2 save-only branch',
)

replace_once(
    settings,
    """  Future<void> _syncWithArmsx2() async {\n    final opened = await Armsx2LibraryService.requestLibrarySync();\n    if (!mounted) return;\n    AppNotification.showNotification(\n      context,\n      opened\n          ? AppLocale.iosArmsx2SyncRequested.getString(context)\n          : AppLocale.iosArmsx2Unavailable.getString(context),\n      type: opened ? NotificationType.info : NotificationType.error,\n    );\n  }\n""",
    """  Future<void> _syncWithArmsx2() async {\n    final root = ConfigService.linkedArmsx2FolderPath;\n    if (root == null || root.isEmpty) {\n      AppNotification.showNotification(\n        context,\n        AppLocale.iosArmsx2StatusNeedsSync.getString(context),\n        type: NotificationType.info,\n      );\n      return;\n    }\n\n    final gameDir = await Armsx2FolderService.resolveGameDirectory(root);\n    ConfigService.linkedArmsx2GameFolderPath = gameDir;\n    if (!mounted) return;\n    final configProvider = Provider.of<SqliteConfigProvider>(context, listen: false);\n    if (gameDir != null && gameDir.isNotEmpty) {\n      if (configProvider.config.romFolders.contains(gameDir)) {\n        await configProvider.scanSystems();\n      } else {\n        await configProvider.addRomFolder(gameDir, scan: true);\n      }\n    }\n    if (!mounted) return;\n    setState(() {});\n    AppNotification.showNotification(\n      context,\n      AppLocale.iosArmsx2StatusSynced.getString(context),\n      type: NotificationType.success,\n    );\n  }\n""",
    'settings local ARMSX2 rescan',
)

replace_once(
    settings,
    """  Widget _buildIOSArmsx2Section(ThemeData theme) {\n    final hasSynced = Armsx2LibraryService.hasSyncedLibrary;\n    final isSaveLinked = ConfigService.linkedArmsx2SaveFolderPath != null;\n    final statusText = hasSynced\n        ? AppLocale.iosArmsx2StatusSynced.getString(context)\n        : AppLocale.iosArmsx2StatusNeedsSync.getString(context);\n\n    return _buildIOSEmulatorCard(\n      theme: theme,\n      name: 'ARMSX2',\n      icon: Symbols.stadia_controller_rounded,\n      statusText: statusText,\n      isLinked: isSaveLinked,\n      bookmarkKey: ConfigService.armsx2NeoSyncBookmarkKey,\n      successMessage: '',\n      onLinkPressed: () => _linkNeoSyncSaveFolder(\n        bookmarkKey: ConfigService.armsx2NeoSyncBookmarkKey,\n        emulatorName: 'ARMSX2',\n      ),\n      trailingAction: Row(\n""",
    """  Widget _buildIOSArmsx2Section(ThemeData theme) {\n    final isRootLinked = ConfigService.linkedArmsx2FolderPath != null;\n    final hasLibrary = ConfigService.linkedArmsx2GameFolderPath != null;\n    final statusText = hasLibrary\n        ? AppLocale.iosArmsx2StatusSynced.getString(context)\n        : AppLocale.iosArmsx2StatusNeedsSync.getString(context);\n\n    return _buildIOSEmulatorCard(\n      theme: theme,\n      name: 'ARMSX2',\n      icon: Symbols.stadia_controller_rounded,\n      statusText: statusText,\n      isLinked: isRootLinked,\n      bookmarkKey: Armsx2FolderService.bookmarkKey,\n      successMessage: '',\n      onLinkPressed: _linkArmsx2RootFolder,\n      trailingAction: Row(\n""",
    'settings ARMSX2 card',
)
settings_text = Path(settings).read_text(encoding='utf-8')
settings_text = settings_text.replace('hasSynced\n                      ? AppLocale.iosEmuResync', 'hasLibrary\n                      ? AppLocale.iosEmuResync', 1)
Path(settings).write_text(settings_text, encoding='utf-8')


# ---------------------------------------------------------------------------
# Physical PS2 scanner: derived ARMSX2 library is a direct, recursive PS2 root.
# ---------------------------------------------------------------------------
scanning = 'lib/providers/sqlite_config_provider/scanning.dart'
replace_once(
    scanning,
    """    _setScanning(true);\n    _error = null;\n    // Re-probe the fast SAF walk once per scan: the permission behind it can be\n""",
    """    _setScanning(true);\n    _error = null;\n\n    if (Platform.isIOS) {\n      final armsx2GameDir = ConfigService.linkedArmsx2GameFolderPath?.trim();\n      if (armsx2GameDir != null &&\n          armsx2GameDir.isNotEmpty &&\n          !_config.romFolders.contains(armsx2GameDir) &&\n          _config.romFolders.length < 5) {\n        _config = _config.copyWith(\n          romFolders: [..._config.romFolders, armsx2GameDir],\n          lastScan: DateTime.now(),\n          setupCompleted: true,\n        );\n        await SqliteConfigService.saveConfig(_config);\n        SqliteConfigProvider._log.i('Registered isolated ARMSX2 PS2 library: $armsx2GameDir');\n      }\n    }\n\n    // Re-probe the fast SAF walk once per scan: the permission behind it can be\n""",
    'scanner ARMSX2 registration',
)
replace_once(
    scanning,
    """      } else {\n        // On Desktop, use File IO based detection\n        detectedSystems = await SqliteConfigService.detectSystems(\n          romFolders: _config.romFolders,\n          availableSystems: _availableSystems,\n        );\n      }\n\n      // Determine the systems to use for initial detection\n""",
    """      } else {\n        // On Desktop, use File IO based detection\n        detectedSystems = await SqliteConfigService.detectSystems(\n          romFolders: _config.romFolders,\n          availableSystems: _availableSystems,\n        );\n      }\n\n      if (Platform.isIOS &&\n          ConfigService.linkedArmsx2GameFolderPath?.isNotEmpty == true &&\n          !detectedSystems.any((system) => system.folderName == 'ps2')) {\n        try {\n          final ps2 = _availableSystems.firstWhere((system) => system.folderName == 'ps2');\n          detectedSystems = [...detectedSystems, ps2];\n        } catch (e) {\n          SqliteConfigProvider._log.w('Could not inject PS2 for ARMSX2 scan: $e');\n        }\n      }\n\n      // Determine the systems to use for initial detection\n""",
    'scanner ARMSX2 PS2 injection',
)

db = 'lib/data/datasources/sqlite_database_service.dart'
replace_once(
    db,
    "import 'package:neostation/services/logger_service.dart';\n",
    "import 'package:neostation/services/logger_service.dart';\n"
    "import 'package:neostation/services/config_service.dart';\n",
    'database ConfigService import',
)
replace_once(
    db,
    """    for (final romFolder in romFolders) {\n      final bool useSaf =\n          Platform.isAndroid && romFolder.startsWith('content://');\n      final Map<String, String>? subdirsForRoot = rootFoldersMap?[romFolder];\n\n      for (final folderToScan in allPossibleFolderNames) {\n""",
    """    for (final romFolder in romFolders) {\n      final bool useSaf =\n          Platform.isAndroid && romFolder.startsWith('content://');\n      final Map<String, String>? subdirsForRoot = rootFoldersMap?[romFolder];\n\n      final armsx2GameDir = ConfigService.linkedArmsx2GameFolderPath;\n      final isDirectArmsx2Ps2Root =\n          Platform.isIOS &&\n          system.folderName.toLowerCase() == 'ps2' &&\n          armsx2GameDir != null &&\n          path.normalize(romFolder) == path.normalize(armsx2GameDir);\n      if (isDirectArmsx2Ps2Root) {\n        scanTargets.add((\n          dirPath: romFolder,\n          canonicalPath: await _canonicalScanPath(romFolder, useSaf: false),\n          useSaf: false,\n        ));\n        continue;\n      }\n\n      for (final folderToScan in allPossibleFolderNames) {\n""",
    'database direct ARMSX2 PS2 root',
)


# ---------------------------------------------------------------------------
# NeoSync: route PS2 saves by game ownership. ARMSX2-owned games see only the
# ARMSX2 root save folders; RetroArch PS2 games see only RetroArch saves/states.
# ---------------------------------------------------------------------------
for neo_file in (
    'lib/providers/neosync/neosync_core.dart',
    'lib/providers/neosync/neosync_upload.dart',
    'lib/providers/neosync/neosync_download.dart',
    'lib/providers/neosync/neosync_path_resolver.dart',
):
    p = Path(neo_file)
    text = p.read_text(encoding='utf-8')
    text = text.replace('ConfigService.linkedArmsx2SaveFolderPath', 'ConfigService.linkedArmsx2FolderPath')
    p.write_text(text, encoding='utf-8')

replace_once(
    'lib/providers/neo_sync_provider.dart',
    "import '../services/config_service.dart';\n",
    "import '../services/config_service.dart';\n"
    "import '../services/armsx2_folder_service.dart';\n",
    'NeoSync ARMSX2 folder import',
)
resolver = 'lib/providers/neosync/neosync_path_resolver.dart'
replace_once(
    resolver,
    """    final folders = system.neosync.getFoldersForCurrentPlatform();\n    final List<String> resolvedPaths = [];\n\n    // System JSON predates iOS NeoSync and has no ios_sync_folder entries.\n""",
    """    final folders = system.neosync.getFoldersForCurrentPlatform();\n    final List<String> resolvedPaths = [];\n\n    // PS2 on iOS must never merge RetroArch and ARMSX2 save roots. Ownership\n    // comes from the ROM path: a ROM inside the ARMSX2 bookmark (or an armsx2://\n    // row) is ARMSX2-owned; every other PS2 row remains RetroArch-owned.\n    if (Platform.isIOS && system.folderName.toLowerCase() == 'ps2') {\n      final armsx2Root = ConfigService.linkedArmsx2FolderPath;\n      final isArmsx2Game = Armsx2FolderService.ownsRomPath(\n        game?.romPath,\n        armsx2Root,\n      );\n      if (isArmsx2Game && armsx2Root != null && armsx2Root.isNotEmpty) {\n        return await Armsx2FolderService.resolveSaveDirectories(armsx2Root);\n      }\n\n      final retroPaths = <String>[];\n      final saves = await _getRetroArchSavesPath();\n      final states = await _getRetroArchStatesPath();\n      if (saves != null) retroPaths.add(saves);\n      if (states != null) retroPaths.add(states);\n      return retroPaths.toSet().toList();\n    }\n\n    // System JSON predates iOS NeoSync and has no ios_sync_folder entries.\n""",
    'NeoSync isolated PS2 ownership routing',
)
replace_once(
    resolver,
    """    if (Platform.isIOS) {\n      final systemFolder = system.folderName.toLowerCase();\n      if (systemFolder == 'ps2') {\n        final custom = ConfigService.linkedArmsx2FolderPath;\n        if (custom != null && custom.isNotEmpty) resolvedPaths.add(custom);\n      } else if (systemFolder == 'switch') {\n        final custom = ConfigService.linkedMelonxSaveFolderPath;\n        if (custom != null && custom.isNotEmpty) resolvedPaths.add(custom);\n      }\n    }\n""",
    """    if (Platform.isIOS) {\n      final systemFolder = system.folderName.toLowerCase();\n      if (systemFolder == 'switch') {\n        final custom = ConfigService.linkedMelonxSaveFolderPath;\n        if (custom != null && custom.isNotEmpty) resolvedPaths.add(custom);\n      }\n    }\n""",
    'NeoSync remove generic ARMSX2 injection',
)
replace_once(
    resolver,
    """    if (pathStr == '{ARMSX2_IOS_SAVES}' && Platform.isIOS) {\n      final root = ConfigService.linkedArmsx2FolderPath;\n      if (root != null && root.isNotEmpty) {\n        if (!ensureExists || Directory(root).existsSync()) return [root];\n      }\n      return [];\n    }\n""",
    """    if (pathStr == '{ARMSX2_IOS_SAVES}' && Platform.isIOS) {\n      final root = ConfigService.linkedArmsx2FolderPath;\n      if (root == null || root.isEmpty) return [];\n      final saves = await Armsx2FolderService.resolveSaveDirectories(root);\n      if (!ensureExists) return saves;\n      return saves.where((p) => Directory(p).existsSync()).toList();\n    }\n""",
    'NeoSync ARMSX2 placeholder',
)


# ---------------------------------------------------------------------------
# Launch ownership: an ARMSX2-owned physical ROM uses the existing ARMSX2
# Shortcut/JIT route without requiring a library-export cache, and never falls
# through to RetroArch if ARMSX2 launch fails.
# ---------------------------------------------------------------------------
launch = 'lib/services/game/game_launch_service.dart'
replace_once(
    launch,
    "import 'package:neostation/services/armsx2_library_service.dart';\n",
    "import 'package:neostation/services/armsx2_library_service.dart';\n"
    "import 'package:neostation/services/armsx2_folder_service.dart';\n",
    'GameLaunch ARMSX2 folder import',
)
replace_once(
    launch,
    """        if (system.folderName.toLowerCase() == 'ps2') {\n          try {\n            final launched = await Armsx2LibraryService.launchGameByRomPath(\n              game.romPath!,\n            );\n            if (launched) return GameLaunchResult.success();\n          } catch (e) {\n            // Physical PS2 rows can still fall through to RetroArch/Open In.\n          }\n\n          // A virtual ARMSX2 row has no local file to hand to RetroArch or the\n          // iOS share sheet. If the deeplink failed, stop here with a useful\n          // error instead of attempting file-based fallbacks on armsx2://.\n          if (isArmsx2VirtualRom) {\n            return GameLaunchResult.failure(\n              'Could not launch this PS2 game in ARMSX2.',\n              game.romPath,\n            );\n          }\n        }\n""",
    """        if (system.folderName.toLowerCase() == 'ps2') {\n          final isArmsx2OwnedRom = Armsx2FolderService.ownsRomPath(\n            game.romPath,\n            ConfigService.linkedArmsx2FolderPath,\n          );\n          try {\n            final launched = await Armsx2LibraryService.launchGameByRomPath(\n              game.romPath!,\n            );\n            if (launched) return GameLaunchResult.success();\n          } catch (e) {\n            _log.e('ARMSX2 launch failed for ${game.romPath}: $e');\n          }\n\n          // An ARMSX2-owned path must never be reinterpreted as a RetroArch\n          // game. This is the hard ownership boundary between both bookmarks.\n          if (isArmsx2OwnedRom || isArmsx2VirtualRom) {\n            return GameLaunchResult.failure(\n              'Could not launch this PS2 game in ARMSX2.',\n              game.romPath,\n            );\n          }\n        }\n""",
    'GameLaunch ARMSX2 ownership boundary',
)

library = 'lib/services/armsx2_library_service.dart'
replace_once(
    library,
    "import 'package:neostation/services/logger_service.dart';\n",
    "import 'package:neostation/services/logger_service.dart';\n"
    "import 'package:neostation/services/config_service.dart';\n"
    "import 'package:neostation/services/armsx2_folder_service.dart';\n",
    'Armsx2Library ownership imports',
)
replace_once(
    library,
    """    final cache = _cache;\n    if (cache == null || cache.isEmpty) {\n      await _writeDebugFile(\n        'armsx2_launch_debug.txt',\n        'romPath: $romPath\\ncache is null or empty (sync ARMSX2 first)',\n      );\n      return false;\n    }\n""",
    """    final ownsLinkedPhysicalRom = Armsx2FolderService.ownsRomPath(\n      romPath,\n      ConfigService.linkedArmsx2FolderPath,\n    );\n    final cache = _cache;\n    if (cache == null || cache.isEmpty) {\n      if (ownsLinkedPhysicalRom) {\n        return await _launchLinkedPhysicalRom(romPath);\n      }\n      await _writeDebugFile(\n        'armsx2_launch_debug.txt',\n        'romPath: $romPath\\nnot owned by the linked ARMSX2 root',\n      );\n      return false;\n    }\n""",
    'Armsx2Library cache-independent physical launch',
)
replace_once(
    library,
    """    if (entry == null) return false;\n\n    final fileName = entry['fileName']?.toString();\n""",
    """    if (entry == null) {\n      if (ownsLinkedPhysicalRom) {\n        return await _launchLinkedPhysicalRom(romPath);\n      }\n      return false;\n    }\n\n    final fileName = entry['fileName']?.toString();\n""",
    'Armsx2Library physical fallback after cache miss',
)
replace_once(
    library,
    """  /// Device-readable diagnostics for CI-only iOS development where an Xcode\n""",
    """  static Future<bool> _launchLinkedPhysicalRom(String romPath) async {\n    final fileName = path.basename(romPath);\n    if (fileName.isEmpty) return false;\n    final uri = Uri(\n      scheme: 'armsx2',\n      host: 'launch',\n      queryParameters: {'game': fileName},\n    );\n    try {\n      await _writeDebugFile(\n        'armsx2_shortcut_launch_debug.txt',\n        'STATE: SHORTCUT_REQUESTED\\n'\n            'Shortcut: ${IosShortcutJitLaunchService.armsx2ShortcutName}\\n'\n            'Game URL: $uri\\n'\n            'Source: linked ARMSX2 physical root\\n'\n            'ROM: $romPath',\n      );\n      return await IosShortcutJitLaunchService.run(\n        shortcutName: IosShortcutJitLaunchService.armsx2ShortcutName,\n        input: uri.toString(),\n      );\n    } catch (e) {\n      _log.e('Armsx2LibraryService: linked physical launch failed: $e');\n      return false;\n    }\n  }\n\n  /// Device-readable diagnostics for CI-only iOS development where an Xcode\n""",
    'Armsx2Library physical launch helper',
)

print('Build 178: isolated ARMSX2 root, NeoSync ownership and launch routing applied')
