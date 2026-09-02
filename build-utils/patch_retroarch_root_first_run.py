from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    file = Path(path)
    text = file.read_text(encoding='utf-8')
    if old not in text:
        raise SystemExit(f'{label} anchor not found')
    file.write_text(text.replace(old, new, 1), encoding='utf-8')


# Setup Wizard: keep the security-scoped bookmark on the RetroArch root,
# but register the detected nested game-library root as NeoStation's ROM source.
replace_once(
    'lib/widgets/setup_wizard.dart',
    "import 'package:neostation/services/config_service.dart';\n",
    "import 'package:neostation/services/config_service.dart';\n"
    "import 'package:neostation/services/ios_rom_library_root_resolver.dart';\n",
    'setup import',
)
replace_once(
    'lib/widgets/setup_wizard.dart',
    """          await configProvider.addRomFolder(linked, scan: false);\n          result = linked;\n\n          // Do not open an emulator or wait for an external callback here.\n""",
    """          var scanRoot = linked;\n          if (!usesManic) {\n            final availableSystems = configProvider.availableSystems.isNotEmpty\n                ? configProvider.availableSystems\n                : await ConfigService.loadAvailableSystems();\n            scanRoot = await IosRomLibraryRootResolver.resolveRetroArchScanRoot(\n              linkedRoot: linked,\n              systemFolderNames: availableSystems.expand(\n                (system) => <String>[system.folderName, ...system.folders],\n              ),\n            );\n          }\n          await configProvider.addRomFolder(scanRoot, scan: false);\n          result = linked;\n          _log.i(\n            'iOS first-run emulator link: root=$linked romScanRoot=$scanRoot',\n          );\n\n          // Do not open an emulator or wait for an external callback here.\n""",
    'setup ROM root',
)

# Settings > Directories: apply the same split between bookmarked emulator root
# and the folder NeoStation scans for games.
replace_once(
    'lib/screens/settings_screen/new_settings_options/directories_settings_content.dart',
    "import 'package:neostation/services/config_service.dart';\n",
    "import 'package:neostation/services/config_service.dart';\n"
    "import 'package:neostation/services/ios_rom_library_root_resolver.dart';\n",
    'directories import',
)
replace_once(
    'lib/screens/settings_screen/new_settings_options/directories_settings_content.dart',
    """      await configProvider.addRomFolder(activePath, scan: true);\n      if (!mounted) return;\n""",
    """      final availableSystems = configProvider.availableSystems.isNotEmpty\n          ? configProvider.availableSystems\n          : await ConfigService.loadAvailableSystems();\n      final scanRoot =\n          bookmarkKey == ExternalFolderAccess.defaultBookmarkKey\n          ? await IosRomLibraryRootResolver.resolveRetroArchScanRoot(\n              linkedRoot: activePath,\n              systemFolderNames: availableSystems.expand(\n                (system) => <String>[system.folderName, ...system.folders],\n              ),\n            )\n          : activePath;\n      if (configProvider.config.romFolders.contains(scanRoot)) {\n        await configProvider.scanSystems();\n      } else {\n        await configProvider.addRomFolder(scanRoot, scan: true);\n      }\n      _log.i('iOS emulator link: root=$activePath romScanRoot=$scanRoot');\n      if (!mounted) return;\n""",
    'directories ROM root',
)

# RetroArch NeoSync: preserve compatibility with older bookmarks that pointed
# to a nested game-library folder rather than the emulator root.
replace_once(
    'lib/services/retroarch_config_service.dart',
    """    final linkedRoot = ConfigService.linkedExternalFolderPath?.trim();\n    if (linkedRoot == null || linkedRoot.isEmpty) {\n""",
    """    String? linkedRoot = ConfigService.linkedExternalFolderPath?.trim();\n\n    String? normalizeRetroArchRoot(String? raw) {\n      if (raw == null || raw.trim().isEmpty) return null;\n      final original = raw.trim();\n      var current = Directory(original);\n      for (var depth = 0; depth < 6; depth++) {\n        final hasCfg =\n            File(path.join(current.path, 'retroarch.cfg')).existsSync() ||\n            File(path.join(current.path, 'config', 'retroarch.cfg')).existsSync();\n        final hasSaves = Directory(path.join(current.path, 'saves')).existsSync();\n        final hasStates = Directory(path.join(current.path, 'states')).existsSync();\n        final hasPlaylists =\n            Directory(path.join(current.path, 'playlists')).existsSync();\n        if (hasCfg ||\n            (hasSaves && hasStates) ||\n            (hasPlaylists && (hasSaves || hasStates))) {\n          return current.path;\n        }\n        final parent = current.parent;\n        if (parent.path == current.path) break;\n        current = parent;\n      }\n      return original;\n    }\n\n    final normalizedRoot = normalizeRetroArchRoot(linkedRoot);\n    if (normalizedRoot != null && normalizedRoot != linkedRoot) {\n      _log.i('NeoSync normalized RetroArch root: $linkedRoot -> $normalizedRoot');\n      linkedRoot = normalizedRoot;\n      ConfigService.linkedExternalFolderPath = normalizedRoot;\n    }\n\n    if (linkedRoot == null || linkedRoot.isEmpty) {\n""",
    'RetroArch NeoSync root',
)

# Preserve the ARMSX2 root handling from Build 170 so this build supersedes it.
replace_once(
    'lib/main.dart',
    """    // Same again for ARMSX2's folder, which lives under its own bookmark\n    // key so linking one emulator never invalidates the other.\n    ConfigService.linkedArmsx2FolderPath =\n        await ExternalFolderAccess.resolveBookmarkedFolder(key: 'armsx2');\n\n    // NeoSync save roots are independent from emulator library roots.\n    ConfigService.linkedArmsx2SaveFolderPath =\n        await ExternalFolderAccess.resolveBookmarkedFolder(\n          key: ConfigService.armsx2NeoSyncBookmarkKey,\n        );\n""",
    """    String? normalizeArmsx2Root(String? raw) {\n      if (raw == null || raw.trim().isEmpty) return null;\n      final original = raw.trim();\n      const categories = {'memcards', 'sstates', 'savestates'};\n      var current = Directory(original);\n      if (categories.contains(path.basename(current.path).toLowerCase())) {\n        current = current.parent;\n      }\n      for (var depth = 0; depth < 6; depth++) {\n        final hasSaveFolder = categories.any(\n          (name) => Directory(path.join(current.path, name)).existsSync(),\n        );\n        if (hasSaveFolder) return current.path;\n        final parent = current.parent;\n        if (parent.path == current.path) break;\n        current = parent;\n      }\n      return original;\n    }\n\n    ConfigService.linkedArmsx2FolderPath = normalizeArmsx2Root(\n      await ExternalFolderAccess.resolveBookmarkedFolder(key: 'armsx2'),\n    );\n    final dedicatedArmsx2NeoSyncRoot = normalizeArmsx2Root(\n      await ExternalFolderAccess.resolveBookmarkedFolder(\n        key: ConfigService.armsx2NeoSyncBookmarkKey,\n      ),\n    );\n    ConfigService.linkedArmsx2SaveFolderPath =\n        dedicatedArmsx2NeoSyncRoot ?? ConfigService.linkedArmsx2FolderPath;\n    ConfigService.linkedArmsx2FolderPath ??=\n        ConfigService.linkedArmsx2SaveFolderPath;\n""",
    'ARMSX2 NeoSync root',
)
