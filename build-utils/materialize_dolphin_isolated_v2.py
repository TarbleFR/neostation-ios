#!/usr/bin/env python3
"""Materialize the isolated Dolphin v2 patch into NeoStation sources.

Every shared-file change is fenced with DOLPHIN_ISOLATION markers so CI can
prove that the pre-existing launch, scan and playlist implementations are
byte-for-byte unchanged outside the narrow GameCube/Wii additions.
"""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BEGIN = "DOLPHIN_ISOLATION_BEGIN"
END = "DOLPHIN_ISOLATION_END"


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def write(relative: str, text: str) -> None:
    path = ROOT / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, got {count}")
    return text.replace(old, new, 1)


def insert_once(text: str, anchor: str, addition: str, label: str) -> str:
    if addition in text:
        return text
    return replace_once(text, anchor, addition + anchor, label)


def patch_pubspec() -> None:
    relative = "pubspec.yaml"
    text = read(relative)
    if "  - packages/dolphin_internal_bridge\n" not in text:
        text = replace_once(
            text,
            "  - packages/stikjit_bridge\n",
            "  - packages/stikjit_bridge\n  - packages/dolphin_internal_bridge\n",
            "workspace dependency",
        )
    if "\n  dolphin_internal_bridge:\n" not in text:
        text = replace_once(
            text,
            "  stikjit_bridge:\n    path: packages/stikjit_bridge\n",
            "  stikjit_bridge:\n    path: packages/stikjit_bridge\n"
            "  dolphin_internal_bridge:\n"
            "    path: packages/dolphin_internal_bridge\n",
            "Dart dependency",
        )
    text = re.sub(
        r"^version:\s*([^+\n]+)\+\d+\s*$",
        r"version: \1+193",
        text,
        count=1,
        flags=re.MULTILINE,
    )
    write(relative, text)


def patch_provider_import() -> None:
    relative = "lib/providers/sqlite_config_provider.dart"
    text = read(relative)
    marker = f"/* {BEGIN}: provider_import */"
    if marker in text:
        return
    anchor = "import 'dart:io';\n"
    block = (
        f"/* {BEGIN}: provider_import */\n"
        "import '../services/dolphin_internal_v2_service.dart';\n"
        f"/* {END}: provider_import */\n"
    )
    text = insert_once(text, anchor, block, "provider import")
    write(relative, text)


def patch_scanning() -> None:
    relative = "lib/providers/sqlite_config_provider/scanning.dart"
    text = read(relative)

    marker = f"// {BEGIN}: native_playlists"
    if marker not in text:
        anchor = "      // Determine the systems to use for initial detection\n"
        block = f"""      // {BEGIN}: native_playlists
      // GameCube and Wii are native NeoStation playlists on iOS. They stay
      // visible at zero games without registering Dolphin's private root as a
      // global ROM folder or changing another system's scan source.
      if (Platform.isIOS) {{
        for (final folderName in const ['gc', 'wii']) {{
          if (detectedSystems.any((system) => system.folderName == folderName)) {{
            continue;
          }}
          try {{
            final nativeSystem = _availableSystems.firstWhere(
              (system) => system.folderName == folderName,
            );
            detectedSystems = [...detectedSystems, nativeSystem];
          }} catch (error) {{
            SqliteConfigProvider._log.e(
              'Could not expose native Dolphin playlist $folderName: $error',
            );
          }}
        }}
      }}
      // {END}: native_playlists

"""
        text = insert_once(text, anchor, block, "native playlist injection")

    marker = f"// {BEGIN}: fast_scan_playlists"
    if marker not in text:
        old = """        final List<String> fastScanFolders = Platform.isAndroid
            ? ['android']
            : [];
"""
        new = f"""        // {BEGIN}: fast_scan_playlists
        final List<String> fastScanFolders = Platform.isAndroid
            ? ['android']
            : Platform.isIOS
            ? ['gc', 'wii']
            : [];
        // {END}: fast_scan_playlists
"""
        text = replace_once(text, old, new, "fast scan playlist preservation")

    marker = f"  // {BEGIN}: targeted_refresh_api"
    if marker not in text:
        anchor = "  /// Performs an isolated scan for a specific system.\n"
        block = f"""  // {BEGIN}: targeted_refresh_api
  /// Refreshes only NeoStation's private GameCube or Wii library.
  /// No configured ROM root and no other emulator playlist is scanned.
  Future<void> refreshDolphinInternalLibrary(String folderName) async {{
    if (!Platform.isIOS ||
        !DolphinInternalV2Service.isDolphinSystem(folderName)) {{
      throw ArgumentError.value(
        folderName,
        'folderName',
        'Dolphin refresh is restricted to gc/wii on iOS.',
      );
    }}
    if (_availableSystems.isEmpty) await _loadAvailableSystems();
    final system = _availableSystems.firstWhere(
      (candidate) => candidate.folderName == folderName.toLowerCase(),
    );
    await SystemRepository.addDetectedSystem(system.id!, system.folderName);
    if (!_detectedSystems.any((candidate) => candidate.id == system.id)) {{
      _detectedSystems = [..._detectedSystems, system];
    }}
    await _scanSystemRoms(system);
    await _refreshDetectedSystemsFromDatabase();
    _sortDetectedSystems();
    _notify();
  }}
  // {END}: targeted_refresh_api

"""
        text = insert_once(text, anchor, block, "targeted Dolphin refresh API")

    marker = f"      // {BEGIN}: isolated_scan_root"
    if marker not in text:
        old = """      // Allow scanning for Android system even if no ROM folders are selected
      if (_config.romFolders.isEmpty && system.folderName != 'android') {
        return ScanSummary(
          added: 0,
          removed: 0,
          total: 0,
          systemName: system.realName,
        );
      }

"""
        new = f"""      // {BEGIN}: isolated_scan_root
      final isDolphinInternalSystem =
          Platform.isIOS &&
          DolphinInternalV2Service.isDolphinSystem(system.folderName);
      // Allow the private gc/wii root to scan even when no public ROM folder
      // exists. Every non-Dolphin system retains the original early return.
      if (_config.romFolders.isEmpty &&
          system.folderName != 'android' &&
          !isDolphinInternalSystem) {{
        return ScanSummary(
          added: 0,
          removed: 0,
          total: 0,
          systemName: system.realName,
        );
      }}
      final dolphinScanRoots = isDolphinInternalSystem
          ? [await DolphinInternalV2Service.scanRootPath()]
          : _config.romFolders;
      final effectiveRootFoldersMap = isDolphinInternalSystem
          ? await SqliteDatabaseService.getExistingSubdirectories(
              dolphinScanRoots,
            )
          : rootFoldersMap;
      // {END}: isolated_scan_root

"""
        text = replace_once(text, old, new, "isolated scanner root")

    marker = f"      // {BEGIN}: isolated_scan_call"
    if marker not in text:
        old = """      final summary = await SqliteDatabaseService.scanSystemRoms(
        system,
        _config.romFolders,
        ignoreHiddenFiles: _config.ignoreHiddenFiles,
        rootFoldersMap: rootFoldersMap,
      );
"""
        new = f"""      // {BEGIN}: isolated_scan_call
      final summary = await SqliteDatabaseService.scanSystemRoms(
        system,
        dolphinScanRoots,
        ignoreHiddenFiles: _config.ignoreHiddenFiles,
        rootFoldersMap: effectiveRootFoldersMap,
      );
      // {END}: isolated_scan_call
"""
        text = replace_once(text, old, new, "isolated scanner call")

    marker = f"        // {BEGIN}: keep_empty_native_systems"
    if marker not in text:
        old = """        if (romCount > 0 || hasFolderWhenNonRecursive || isAndroidVirtual) {
          systemsToKeep.add(system.copyWith(romCount: romCount));
"""
        new = f"""        // {BEGIN}: keep_empty_native_systems
        final isDolphinInternalSystem =
            Platform.isIOS &&
            DolphinInternalV2Service.isDolphinSystem(system.folderName);
        if (romCount > 0 ||
            hasFolderWhenNonRecursive ||
            isAndroidVirtual ||
            isDolphinInternalSystem) {{
          systemsToKeep.add(system.copyWith(romCount: romCount));
        // {END}: keep_empty_native_systems
"""
        text = replace_once(text, old, new, "keep empty native systems")

    marker = f"      // {BEGIN}: refresh_keep_native_systems"
    if marker not in text:
        old = """      final bool shouldKeep =
          updatedSystem.romCount > 0 ||
          hasFolderWhenNonRecursive ||
          (updatedSystem.folderName == 'android' && Platform.isAndroid) ||
          updatedSystem.folderName == 'all' ||
          updatedSystem.folderName == SystemFolderNames.favorites;
"""
        new = f"""      // {BEGIN}: refresh_keep_native_systems
      final bool shouldKeep =
          updatedSystem.romCount > 0 ||
          hasFolderWhenNonRecursive ||
          (updatedSystem.folderName == 'android' && Platform.isAndroid) ||
          updatedSystem.folderName == 'all' ||
          updatedSystem.folderName == SystemFolderNames.favorites ||
          (Platform.isIOS &&
              DolphinInternalV2Service.isDolphinSystem(
                updatedSystem.folderName,
              ));
      // {END}: refresh_keep_native_systems
"""
        text = replace_once(text, old, new, "refresh keep native systems")

    write(relative, text)


def patch_launcher() -> None:
    relative = "lib/services/game/game_launch_service.dart"
    text = read(relative)
    marker = f"// {BEGIN}: launcher_import"
    if marker not in text:
        anchor = "import 'package:neostation/services/logger_service.dart';\n"
        block = (
            f"// {BEGIN}: launcher_import\n"
            "import '../dolphin_internal_v2_service.dart';\n"
            f"// {END}: launcher_import\n"
        )
        text = insert_once(text, anchor, block, "launcher import")

    marker = f"      // {BEGIN}: explicit_gc_wii_route"
    if marker not in text:
        anchor = "      // iOS: there's no equivalent of Android's \"send an Intent with a file\n"
        block = f"""      // {BEGIN}: explicit_gc_wii_route
      // This is the only shared-router addition. It returns on both success and
      // failure, so a GameCube/Wii image can never fall through to RetroArch,
      // a DeepLink, a Shortcut or another emulator. Every other system skips
      // this block and continues through the byte-for-byte existing router.
      if (Platform.isIOS &&
          DolphinInternalV2Service.isDolphinSystem(system.folderName)) {{
        final gamePath = game.romPath;
        if (gamePath == null || gamePath.isEmpty) {{
          return GameLaunchResult.failure(
            'Dolphin launch refused: the game path is missing.',
            system.folderName,
          );
        }}
        final report = await DolphinInternalV2Service.launch(
          folderName: system.folderName,
          gamePath: gamePath,
        );
        if (!context.mounted) return GameLaunchResult.failure('', '');
        if (!report.ready) {{
          return GameLaunchResult.failure(
            report.message,
            'Dolphin stage: ${{report.failedStage ?? "unknown"}}\nLog: ${{report.logPath}}',
          );
        }}
        GameSessionManager.registerGameLaunch(
          system,
          game,
          'ios_dolphin_internal',
        );
        await FavoritesService.recordGamePlayed(game);
        return GameLaunchResult.success();
      }}
      // {END}: explicit_gc_wii_route

"""
        text = insert_once(text, anchor, block, "explicit gc/wii route")
    write(relative, text)


def patch_playlist() -> None:
    relative = "lib/screens/game_screen/my_games_list.dart"
    text = read(relative)
    marker = f"// {BEGIN}: playlist_import"
    if marker not in text:
        anchor = "import 'package:neostation/services/game_service.dart';\n"
        block = (
            f"// {BEGIN}: playlist_import\n"
            "import 'package:neostation/widgets/dolphin_internal_playlist_actions.dart';\n"
            f"// {END}: playlist_import\n"
        )
        text = insert_once(text, anchor, block, "playlist import")

    marker = f"            // {BEGIN}: playlist_actions"
    if marker not in text:
        pattern = re.compile(r"(?P<indent>\s*)GameViewModeDropdown\(\),\n")
        match = pattern.search(text)
        if match is None:
            raise SystemExit("playlist actions: GameViewModeDropdown anchor missing")
        indent = match.group("indent")
        original = match.group(0)
        addition = (
            original
            + f"{indent}// {BEGIN}: playlist_actions\n"
            + f"{indent}DolphinInternalPlaylistActions(\n"
            + f"{indent}  systemFolder: widget.system.folderName,\n"
            + f"{indent}  onLibraryChanged: () async {{\n"
            + f"{indent}    await context\n"
            + f"{indent}        .read<SqliteConfigProvider>()\n"
            + f"{indent}        .refreshDolphinInternalLibrary(\n"
            + f"{indent}          widget.system.folderName,\n"
            + f"{indent}        );\n"
            + f"{indent}  }},\n"
            + f"{indent}),\n"
            + f"{indent}// {END}: playlist_actions\n"
        )
        text = text[: match.start()] + addition + text[match.end() :]
    write(relative, text)


def write_contract_test() -> None:
    write(
        "test/dolphin_isolation_contract_test.dart",
        r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dolphin is routed before the general iOS launcher and only for gc/wii', () {
    final launcher = File(
      'lib/services/game/game_launch_service.dart',
    ).readAsStringSync();
    expect(launcher, contains('DolphinInternalV2Service.isDolphinSystem'));
    expect(
      launcher.indexOf('DolphinInternalV2Service.isDolphinSystem'),
      lessThan(launcher.indexOf('if (Platform.isIOS)')),
    );
    expect(launcher, contains('Rpcs3LaunchService.launchTitle'));
    expect(launcher, contains('MelonxLibraryService.launchGameByRomPath'));
    expect(launcher, contains('Armsx2LibraryService.launchGameByRomPath'));
    expect(launcher, contains('RetroArchLibraryService.launchGameByRomPath'));
  });

  test('Dolphin JIT policy is legacy-only and does not alter shared StikJIT', () {
    final helper = File(
      'packages/dolphin_jit_helper/ios/Classes/DolphinJITRequestHandlerBase.swift',
    ).readAsStringSync();
    expect(helper, contains('script: .legacy'));
    expect(helper, isNot(contains('.universal')));

    for (final path in [
      'packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift',
      'packages/stikjit_bridge/ios/Classes/NeoStationStikjitBridgePlugin.swift',
      'packages/stikjit_bridge/ios/Classes/StikjitRpcs3BridgePlugin.swift',
    ]) {
      final file = File(path);
      if (file.existsSync()) {
        expect(file.readAsStringSync(), contains('script: .universal'));
      }
    }
  });

  test('Dolphin does not own generic executable extensions', () {
    final service = File(
      'lib/services/dolphin_internal_v2_service.dart',
    ).readAsStringSync();
    expect(service, isNot(contains("'elf'")));
    expect(service, isNot(contains("'dol'")));
    expect(service, contains("normalized == 'gc' || normalized == 'wii'"));
  });
}
''',
    )


def remove_retired_v1_files() -> None:
    retired = (
        "lib/services/dolphin_embedded_service.dart",
        "lib/widgets/dolphin_playlist_actions.dart",
        "native/dolphin_internal/DolphinJITMessage.swift",
        "build-utils/apply_dolphin_internal_patch.py",
        "build-utils/patch_dolphin_internal_core.py",
        "build-utils/dolphin_isolation_marker.txt",
        "build-utils/dolphin_isolation_marker2.txt",
        "build-utils/dolphin_isolation_marker3.txt",
        "build-utils/.dolphin-v2-progress",
        "build-utils/.dolphin-v2-progress2",
        "build-utils/.dolphin-v2-progress3",
    )
    for relative in retired:
        (ROOT / relative).unlink(missing_ok=True)


def main() -> None:
    remove_retired_v1_files()
    patch_pubspec()
    patch_provider_import()
    patch_scanning()
    patch_launcher()
    patch_playlist()
    write_contract_test()
    print("Materialized isolated Dolphin v2 sources and non-regression tests.")


if __name__ == "__main__":
    main()
