#!/usr/bin/env python3
"""Materialize the isolated Dolphin integration without changing other engines.

This script is intentionally fail-closed: every shared-file edit is anchored to
NeoStation's known source shape. Dolphin changes are restricted to the iOS
GameCube/Wii route, their native playlists, and their private scan root.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: str, old: str, new: str) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    if new in text:
        print(f"already refined: {path}")
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"Refusing to refine {path}: expected one anchor, found {count}."
        )
    target.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"refined: {path}")


subprocess.run(
    ["python3", str(ROOT / "build-utils" / "apply_dolphin_internal_patch.py")],
    cwd=ROOT,
    check=True,
)

replace_once(
    "pubspec.yaml",
    "  - packages/stikjit_bridge\n",
    "  - packages/stikjit_bridge\n  - packages/dolphin_internal_bridge\n",
)
replace_once(
    "pubspec.yaml",
    "  stikjit_bridge:\n    path: packages/stikjit_bridge\n",
    "  stikjit_bridge:\n    path: packages/stikjit_bridge\n"
    "  dolphin_internal_bridge:\n    path: packages/dolphin_internal_bridge\n",
)

# Never persist Dolphin's private root in the user's global ROM-folder list.
# Only create the private layout here; the per-system scanner below receives it
# locally for gc/wii and no other system can observe it.
replace_once(
    "lib/providers/sqlite_config_provider/scanning.dart",
    """    if (Platform.isIOS) {
      // GameCube and Wii are native NeoStation playlists on iOS. Their private
      // root is registered automatically and is never presented as a
      // DolphiniOS folder to the user.
      final dolphinLibraryRoot =
          await DolphinEmbeddedService.internalLibraryRootPath();
      if (!_config.romFolders.contains(dolphinLibraryRoot)) {
        _config = _config.copyWith(
          romFolders: [..._config.romFolders, dolphinLibraryRoot],
          lastScan: DateTime.now(),
          setupCompleted: true,
        );
        await SqliteConfigService.saveConfig(_config);
        SqliteConfigProvider._log.i(
          '[DolphinInternal] Registered private GC/Wii library root.',
        );
      }

      final armsx2GameDir = ConfigService.linkedArmsx2GameFolderPath?.trim();
""",
    """    if (Platform.isIOS) {
      // Create Dolphin's private layout without registering it as a global ROM
      // source. The root is injected only into gc/wii scans below.
      await DolphinEmbeddedService.ensureLayout();
      SqliteConfigProvider._log.i(
        '[DolphinInternal] Private GameCube/Wii layout is available.',
      );

      final armsx2GameDir = ConfigService.linkedArmsx2GameFolderPath?.trim();
""",
)

# In fast-scan mode iOS still exposes the two native playlists, including with
# zero games. Android and desktop behavior is unchanged.
replace_once(
    "lib/providers/sqlite_config_provider/scanning.dart",
    """        final List<String> fastScanFolders = Platform.isAndroid
            ? ['android']
            : [];
""",
    """        final List<String> fastScanFolders = Platform.isAndroid
            ? ['android']
            : (Platform.isIOS ? ['gc', 'wii'] : []);
""",
)

replace_once(
    "lib/providers/sqlite_config_provider/scanning.dart",
    """      if (_config.romFolders.isEmpty && system.folderName != 'android') {
""",
    """      final isNativeDolphinScan =
          Platform.isIOS &&
          DolphinEmbeddedService.isDolphinSystemFolder(system.folderName);
      if (_config.romFolders.isEmpty &&
          system.folderName != 'android' &&
          !isNativeDolphinScan) {
""",
)

replace_once(
    "lib/providers/sqlite_config_provider/scanning.dart",
    """      final summary = await SqliteDatabaseService.scanSystemRoms(
        system,
        _config.romFolders,
        ignoreHiddenFiles: _config.ignoreHiddenFiles,
        rootFoldersMap: rootFoldersMap,
      );
""",
    """      final scanRoots = <String>[..._config.romFolders];
      Map<String, Map<String, String>>? effectiveRootFoldersMap = rootFoldersMap;
      if (isNativeDolphinScan) {
        scanRoots.add(await DolphinEmbeddedService.internalLibraryRootPath());
        // The pre-fetched map contains only user-configured roots. Let the
        // database scanner inspect Dolphin's private root for gc/wii only.
        effectiveRootFoldersMap = null;
      }

      final summary = await SqliteDatabaseService.scanSystemRoms(
        system,
        scanRoots,
        ignoreHiddenFiles: _config.ignoreHiddenFiles,
        rootFoldersMap: effectiveRootFoldersMap,
      );
""",
)

# Keep format ownership explicit. Generic DOL/ELF and Triforce images are not
# assigned to the GameCube/Wii playlists, and Wii WAD files cannot be imported
# through the GameCube action.
replace_once(
    "lib/services/dolphin_embedded_service.dart",
    """  static const Set<String> _gameExtensions = {
    'iso',
    'gcm',
    'ciso',
    'gcz',
    'rvz',
    'wia',
    'wbfs',
    'dol',
    'elf',
    'tgc',
  };
""",
    """  static const Set<String> _gameCubeExtensions = {
    'iso',
    'gcm',
    'ciso',
    'gcz',
    'rvz',
    'wia',
  };
  static const Set<String> _wiiExtensions = {
    'iso',
    'ciso',
    'gcz',
    'rvz',
    'wia',
    'wbfs',
    'wad',
  };
""",
)
replace_once(
    "lib/services/dolphin_embedded_service.dart",
    """    final picked = await FilePicker.pickFiles(
      dialogTitle: normalized == 'gc'
          ? 'Import GameCube games'
          : 'Import Wii games',
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: _gameExtensions.toList()..sort(),
""",
    """    final allowedExtensions = normalized == 'gc'
        ? _gameCubeExtensions
        : _wiiExtensions;
    final picked = await FilePicker.pickFiles(
      dialogTitle: normalized == 'gc'
          ? 'Import GameCube games'
          : 'Import Wii games',
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: allowedExtensions.toList()..sort(),
""",
)
replace_once(
    "lib/services/dolphin_embedded_service.dart",
    """      if (safeName.isEmpty || !_gameExtensions.contains(extension)) {
""",
    """      if (safeName.isEmpty || !allowedExtensions.contains(extension)) {
""",
)

# Match the requested private layout names while retaining Dolphin's canonical
# User sub-tree (GC, Wii, StateSaves, Cache, etc.) for upstream compatibility.
replace_once(
    "lib/services/dolphin_embedded_service.dart",
    "import 'package:file_picker/file_picker.dart';\n",
    "import 'package:crypto/crypto.dart';\nimport 'package:file_picker/file_picker.dart';\n",
)
replace_once(
    "lib/services/dolphin_embedded_service.dart",
    """    final library = Directory(path.join(root.path, 'Library'));
""",
    """    final library = Directory(path.join(root.path, 'Games'));
""",
)
replace_once(
    "lib/services/dolphin_embedded_service.dart",
    """      crashMarkers,
      Directory(path.join(user.path, 'Config')),
""",
    """      crashMarkers,
      Directory(path.join(root.path, 'Config')),
      Directory(path.join(root.path, 'Saves')),
      Directory(path.join(root.path, 'Cache')),
      Directory(path.join(root.path, 'System')),
      Directory(path.join(root.path, 'IPL')),
      Directory(path.join(user.path, 'Config')),
""",
)

# Detect duplicate content after staging. This is independent of filenames and
# keeps the scanner from creating repeated library entries.
replace_once(
    "lib/services/dolphin_embedded_service.dart",
    """        if (!await temporary.exists() || await temporary.length() <= 0) {
          throw const FileSystemException('Imported file is empty');
        }
        await temporary.rename(target.path);
""",
    """        if (!await temporary.exists() || await temporary.length() <= 0) {
          throw const FileSystemException('Imported file is empty');
        }
        final duplicate = await _findDuplicateByContent(destination, temporary);
        if (duplicate != null) {
          await temporary.delete();
          rejected[selected.name] =
              'Already imported as ${path.basename(duplicate.path)}.';
          await _appendEvent(
            directories,
            stage: 'library_import',
            status: 'duplicate',
            details: {
              'system': normalized,
              'file': selected.name,
              'existing': duplicate.path,
            },
          );
          continue;
        }
        await temporary.rename(target.path);
""",
)
replace_once(
    "lib/services/dolphin_embedded_service.dart",
    """  static Future<File> _availableDestination(
""",
    """  static Future<File?> _findDuplicateByContent(
    Directory destination,
    File staged,
  ) async {
    final stagedLength = await staged.length();
    final stagedDigest = await sha256.bind(staged.openRead()).first;
    await for (final entity in destination.list(followLinks: false)) {
      if (entity is! File || path.extension(entity.path) == '.importing') {
        continue;
      }
      try {
        if (await entity.length() != stagedLength) continue;
        final digest = await sha256.bind(entity.openRead()).first;
        if (digest == stagedDigest) return entity;
      } catch (_) {
        // An unreadable existing entry cannot be treated as a verified match.
      }
    }
    return null;
  }

  static Future<File> _availableDestination(
""",
)

print("Dolphin v2 isolation refinement applied successfully.")
