#!/usr/bin/env python3
"""Apply the isolated Dolphin-internal test patch to the NeoStation tree.

The test branch keeps the large upstream Dart files reviewable by expressing the
few integration points as exact, fail-closed replacements. Every anchor must
match exactly once. A source drift therefore fails CI instead of silently
building an IPA without the internal Dolphin route.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: str, old: str, new: str) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    if new in text:
        print(f"already patched: {path}")
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"Refusing to patch {path}: expected one anchor, found {count}."
        )
    target.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"patched: {path}")


replace_once(
    "pubspec.yaml",
    "version: 1.0.0+163",
    "version: 1.0.0+192",
)

replace_once(
    "lib/providers/sqlite_config_provider.dart",
    "import '../services/config_service.dart';\n",
    "import '../services/config_service.dart';\n"
    "import '../services/dolphin_embedded_service.dart';\n",
)

replace_once(
    "lib/providers/sqlite_config_provider/scanning.dart",
    """    if (Platform.isIOS) {
      final armsx2GameDir = ConfigService.linkedArmsx2GameFolderPath?.trim();
""",
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
)

replace_once(
    "lib/providers/sqlite_config_provider/scanning.dart",
    """      // Determine the systems to use for initial detection
      List<SystemModel> systemsForMapping = _availableSystems;
""",
    """      // GameCube and Wii remain visible before the first import and when
      // their native NeoStation playlists contain zero games.
      if (Platform.isIOS) {
        for (final folderName in const ['gc', 'wii']) {
          if (detectedSystems.any(
            (system) => system.folderName.toLowerCase() == folderName,
          )) {
            continue;
          }
          try {
            final nativeSystem = _availableSystems.firstWhere(
              (system) => system.folderName.toLowerCase() == folderName,
            );
            detectedSystems = [...detectedSystems, nativeSystem];
          } catch (error) {
            SqliteConfigProvider._log.e(
              '[DolphinInternal] Missing bundled $folderName system: $error',
            );
          }
        }
      }

      // Determine the systems to use for initial detection
      List<SystemModel> systemsForMapping = _availableSystems;
""",
)

replace_once(
    "lib/providers/sqlite_config_provider/scanning.dart",
    """        final bool isAndroidVirtual =
            (system.folderName == 'android' && Platform.isAndroid);

        if (romCount > 0 || hasFolderWhenNonRecursive || isAndroidVirtual) {
""",
    """        final bool isAndroidVirtual =
            (system.folderName == 'android' && Platform.isAndroid);
        final bool isNativeDolphin =
            Platform.isIOS &&
            DolphinEmbeddedService.isDolphinSystemFolder(system.folderName);

        if (romCount > 0 ||
            hasFolderWhenNonRecursive ||
            isAndroidVirtual ||
            isNativeDolphin) {
""",
)

replace_once(
    "lib/providers/sqlite_config_provider/scanning.dart",
    """      final bool shouldKeep =
          updatedSystem.romCount > 0 ||
          hasFolderWhenNonRecursive ||
          (updatedSystem.folderName == 'android' && Platform.isAndroid) ||
          updatedSystem.folderName == 'all' ||
          updatedSystem.folderName == SystemFolderNames.favorites;
""",
    """      final bool shouldKeep =
          updatedSystem.romCount > 0 ||
          hasFolderWhenNonRecursive ||
          (Platform.isIOS &&
              DolphinEmbeddedService.isDolphinSystemFolder(
                updatedSystem.folderName,
              )) ||
          (updatedSystem.folderName == 'android' && Platform.isAndroid) ||
          updatedSystem.folderName == 'all' ||
          updatedSystem.folderName == SystemFolderNames.favorites;
""",
)

replace_once(
    "lib/screens/game_screen/my_games_list.dart",
    "import 'package:neostation/widgets/game_view_footer.dart';\n",
    "import 'package:neostation/widgets/game_view_footer.dart';\n"
    "import 'package:neostation/widgets/dolphin_playlist_actions.dart';\n",
)

replace_once(
    "lib/screens/game_screen/my_games_list.dart",
    """            GameViewModeDropdown(),
          ],
""",
    """            GameViewModeDropdown(),
            DolphinPlaylistActions(
              systemFolder: widget.system.folderName,
              onLibraryChanged: () async {
                await context.read<SqliteConfigProvider>().scanSystems();
                if (!mounted) return;
                await _loadGames();
              },
            ),
          ],
""",
)

replace_once(
    "lib/services/game/game_launch_service.dart",
    "import 'package:neostation/services/logger_service.dart';\n",
    "import 'package:neostation/services/logger_service.dart';\n"
    "import 'package:neostation/services/dolphin_embedded_service.dart';\n",
)

replace_once(
    "lib/services/game/game_launch_service.dart",
    """      // iOS: there's no equivalent of Android's "send an Intent with a file
""",
    """      // GameCube/Wii on iOS are owned exclusively by NeoStation's embedded
      // Dolphin engine. This branch is deliberately before every external iOS
      // route and returns on failure, so no DeepLink, Shortcut, share sheet,
      // RetroArch core or DolphiniOS fallback can mask a failed JIT gate.
      if (Platform.isIOS &&
          DolphinEmbeddedService.isDolphinSystemFolder(system.folderName)) {
        final outcome = await DolphinEmbeddedService.launchGame(
          systemFolder: system.folderName,
          gamePath: game.romPath!,
        );
        if (outcome.success) {
          GameSessionManager.registerGameLaunch(
            system,
            game,
            'ios_dolphin_internal_jitarm64',
          );
          await FavoritesService.recordGamePlayed(game);
          return GameLaunchResult.success();
        }
        return GameLaunchResult.failure(
          outcome.message,
          outcome.details ?? outcome.logPath,
        );
      }

      // iOS: there's no equivalent of Android's "send an Intent with a file
""",
)

# Fail closed if any retired external-Dolphin routing appears in executable
# sources introduced by a later merge.
for forbidden in (
    "dolphinios://",
    "DolphinSingleSessionLaunchScript",
    "DolphinRuntimeLaunchScript",
    "StikjitDolphinBridgePlugin",
    "linkedDolphinFolderPath",
):
    matches = []
    for root in (ROOT / "lib", ROOT / "packages"):
        if not root.exists():
            continue
        for source in root.rglob("*"):
            if source.suffix.lower() not in {".dart", ".swift", ".m", ".mm", ".h"}:
                continue
            try:
                if forbidden in source.read_text(encoding="utf-8"):
                    matches.append(str(source.relative_to(ROOT)))
            except UnicodeDecodeError:
                pass
    if matches:
        raise SystemExit(
            f"Forbidden external Dolphin token {forbidden!r} found in: "
            + ", ".join(matches)
        )

print("Dolphin internal source integration applied successfully.")
