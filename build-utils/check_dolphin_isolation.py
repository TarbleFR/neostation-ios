#!/usr/bin/env python3
"""CI guard for Dolphin isolation and non-regression of other emulators."""

from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args: str) -> str:
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def baseline(path: str) -> str:
    return run("git", "show", f"HEAD:{path}")


allowed_shared_changes = {
    "pubspec.yaml",
    "lib/providers/sqlite_config_provider.dart",
    "lib/providers/sqlite_config_provider/scanning.dart",
    "lib/screens/game_screen/my_games_list.dart",
    "lib/services/game/game_launch_service.dart",
    "lib/services/dolphin_embedded_service.dart",
}
changed = set(filter(None, run("git", "diff", "--name-only").splitlines()))
unexpected = changed - allowed_shared_changes
missing = {
    "pubspec.yaml",
    "lib/providers/sqlite_config_provider/scanning.dart",
    "lib/screens/game_screen/my_games_list.dart",
    "lib/services/game/game_launch_service.dart",
} - changed
if unexpected:
    raise SystemExit(
        "Dolphin patch modified unrelated tracked files: " + ", ".join(sorted(unexpected))
    )
if missing:
    raise SystemExit(
        "Expected materialized Dolphin integration changes are absent: "
        + ", ".join(sorted(missing))
    )

launcher_path = "lib/services/game/game_launch_service.dart"
launcher_before = baseline(launcher_path)
launcher_after = read(launcher_path)

# Existing engines must keep every route token they had before this patch.
route_tokens = {
    "RetroArch": "RetroArchLibraryService.launchGameByRomPath",
    "MeloNX": "MelonxLibraryService.launchGameByRomPath",
    "ARMSX2": "Armsx2LibraryService.launchGameByRomPath",
    "RPCS3": "Rpcs3LaunchService.launchTitle",
    "desktop launcher": "_launchGameDesktopFromConfig",
    "Android intents": "launchGenericIntent",
}
for label, token in route_tokens.items():
    before_count = launcher_before.count(token)
    after_count = launcher_after.count(token)
    if before_count and after_count < before_count:
        raise SystemExit(
            f"{label} route regressed: {token!r} count {before_count} -> {after_count}"
        )

# Preserve optional integrations whenever the base branch contains them.
optional_tokens = (
    "ManicEMU",
    "manicemu",
    "manic_emu",
    "ARMSX3",
    "armsx3",
    "rmsx3",
)
optional_paths = (
    "lib/services/game/game_launch_service.dart",
    "lib/services/launcher_service.dart",
    "lib/utils/emulator_loader.dart",
)
for token in optional_tokens:
    before_count = 0
    after_count = 0
    for path in optional_paths:
        exists_in_head = subprocess.run(
            ["git", "cat-file", "-e", f"HEAD:{path}"],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0
        if exists_in_head:
            before_count += baseline(path).count(token)
        if (ROOT / path).is_file():
            after_count += read(path).count(token)
    if before_count and after_count < before_count:
        raise SystemExit(f"Optional emulator token {token!r} was removed")

required_launcher_fragments = (
    "DolphinEmbeddedService.isDolphinSystemFolder(system.folderName)",
    "DolphinEmbeddedService.launchGame(",
    "return GameLaunchResult.failure(",
    "if (Platform.isIOS) {",
)
for fragment in required_launcher_fragments:
    if fragment not in launcher_after:
        raise SystemExit(f"Missing isolated launcher fragment: {fragment}")

service = read("lib/services/dolphin_embedded_service.dart")
plugin = read(
    "packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.swift"
)
combined_dolphin = service + "\n" + plugin

for forbidden in (
    "dolphinios://",
    "UIApplication.shared.open",
    "shortcuts://",
    "script: .universal",
    "script-name=universal",
    "Interpreter",
):
    if forbidden in combined_dolphin:
        raise SystemExit(f"Forbidden Dolphin path/token remains: {forbidden}")

for required in (
    'normalized == "gc" || normalized == "wii"',
    "targetPID: getpid()",
    "script: .legacy",
    "forceScript: true",
    "neostation_dolphin_prepare_legacy_jit",
    "neostation_dolphin_launch",
    "DolphinCore.framework",
):
    if required not in combined_dolphin:
        raise SystemExit(f"Missing real Dolphin bridge/JIT contract: {required}")

# File associations are per playlist and exclude generic DOL/ELF, Triforce,
# and non-GameCube/Wii platform extensions.
for forbidden_extension in (
    "'dol'", "'elf'", "'tgc'", "'nsp'", "'xci'", "'pkg'", "'iso3'",
):
    if forbidden_extension in service:
        raise SystemExit(f"Dolphin owns forbidden extension {forbidden_extension}")
if "_gameCubeExtensions" not in service or "_wiiExtensions" not in service:
    raise SystemExit("Per-system GameCube/Wii extension sets are missing")

# The private Dolphin root must never become a persisted global ROM folder.
scanning = read("lib/providers/sqlite_config_provider/scanning.dart")
if "romFolders: [..._config.romFolders, dolphinLibraryRoot]" in scanning:
    raise SystemExit("Dolphin private root leaked into global ROM-folder configuration")
if "if (isNativeDolphinScan)" not in scanning:
    raise SystemExit("Dolphin scan root is not scoped to GameCube/Wii")

# Existing JIT implementation files and system definitions are byte-identical.
subprocess.run(
    ["git", "diff", "--exit-code", "HEAD", "--", "packages/stikjit_bridge"],
    cwd=ROOT,
    check=True,
)
subprocess.run(
    ["git", "diff", "--exit-code", "HEAD", "--", "assets/systems"],
    cwd=ROOT,
    check=True,
)

# Existing universal-script choices remain available to their original engines;
# Dolphin's legacy lock is encapsulated in the separate plugin.
stik_sources = "\n".join(
    path.read_text(encoding="utf-8")
    for path in (ROOT / "packages/stikjit_bridge/ios/Classes").glob("*.swift")
)
if "script: .universal" not in stik_sources:
    raise SystemExit("Existing non-Dolphin StikJIT universal paths disappeared")

# No unrelated Dart source may acquire the Dolphin service.
allowed_references = {
    "lib/services/dolphin_embedded_service.dart",
    "lib/widgets/dolphin_playlist_actions.dart",
    "lib/providers/sqlite_config_provider.dart",
    "lib/providers/sqlite_config_provider/scanning.dart",
    "lib/screens/game_screen/my_games_list.dart",
    "lib/services/game/game_launch_service.dart",
}
violations = []
for source in (ROOT / "lib").rglob("*.dart"):
    relative = source.relative_to(ROOT).as_posix()
    if (
        "DolphinEmbeddedService" in source.read_text(encoding="utf-8")
        and relative not in allowed_references
    ):
        violations.append(relative)
if violations:
    raise SystemExit(
        "Dolphin integration escaped approved boundaries: "
        + ", ".join(sorted(violations))
    )

print("Dolphin isolation and non-regression guard passed.")
print("Shared files changed:")
for path in sorted(changed):
    print(f"  - {path}")
