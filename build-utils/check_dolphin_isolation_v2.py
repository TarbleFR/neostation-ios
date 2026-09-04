#!/usr/bin/env python3
"""Fail CI when Dolphin changes anything outside its explicit gc/wii surface."""

from __future__ import annotations

import argparse
import difflib
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHARED_FILES = {
    "lib/services/game/game_launch_service.dart",
    "lib/providers/sqlite_config_provider.dart",
    "lib/providers/sqlite_config_provider/scanning.dart",
    "lib/screens/game_screen/my_games_list.dart",
}
ALLOWED_EXACT = {
    ".github/workflows/dolphin-internal-isolated-v2.yml",
    "pubspec.yaml",
    "pubspec.lock",
    "build-utils/apply_dolphin_internal_patch.py",
    "build-utils/patch_dolphin_internal_core.py",
    "build-utils/materialize_dolphin_isolated_v2.py",
    "build-utils/patch_dolphin_internal_core_v2.py",
    "build-utils/configure_dolphin_ios_v2.py",
    "build-utils/check_dolphin_isolation_v2.py",
    "lib/services/dolphin_embedded_service.dart",
    "lib/services/dolphin_internal_v2_service.dart",
    "lib/widgets/dolphin_playlist_actions.dart",
    "lib/widgets/dolphin_internal_playlist_actions.dart",
    "native/dolphin_internal/DolphinJITMessage.swift",
    *SHARED_FILES,
}
ALLOWED_PREFIXES = (
    "packages/dolphin_internal_bridge/",
    "packages/dolphin_jit_helper/",
    "native/dolphin_internal_helper/",
    "test/dolphin_",
    "build-utils/.dolphin-v2-",
)
MARKER_BEGIN = "DOLPHIN_ISOLATION_BEGIN"
MARKER_END = "DOLPHIN_ISOLATION_END"


def git(*args: str) -> str:
    return subprocess.check_output(
        ["git", *args], cwd=ROOT, text=True, stderr=subprocess.STDOUT
    )


def changed_files(base: str) -> list[str]:
    output = git("diff", "--name-only", f"{base}...HEAD")
    return [line.strip() for line in output.splitlines() if line.strip()]


def is_allowed(path: str) -> bool:
    return path in ALLOWED_EXACT or path.startswith(ALLOWED_PREFIXES)


def baseline_text(base: str, path: str) -> str:
    return git("show", f"{base}:{path}")


def marker_ranges(lines: list[str]) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    start: int | None = None
    for index, line in enumerate(lines):
        if MARKER_BEGIN in line:
            if start is not None:
                raise AssertionError("nested Dolphin isolation markers")
            start = index
        if MARKER_END in line:
            if start is None:
                raise AssertionError("unmatched Dolphin isolation end marker")
            ranges.append((start, index + 1))
            start = None
    if start is not None:
        raise AssertionError("unclosed Dolphin isolation marker")
    return ranges


def index_is_in_ranges(index: int, ranges: list[tuple[int, int]]) -> bool:
    return any(start <= index < end for start, end in ranges)


def check_shared_file(base: str, relative: str) -> None:
    current = (ROOT / relative).read_text(encoding="utf-8").splitlines()
    baseline = baseline_text(base, relative).splitlines()
    ranges = marker_ranges(current)
    if not ranges:
        raise AssertionError(f"{relative}: shared file changed without isolation markers")

    matcher = difflib.SequenceMatcher(a=baseline, b=current, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        if j1 == j2:
            probes = [max(0, j1 - 1), min(len(current) - 1, j1)]
            if not any(index_is_in_ranges(probe, ranges) for probe in probes):
                raise AssertionError(
                    f"{relative}: deletion outside a Dolphin marker at baseline lines {i1 + 1}-{i2}"
                )
            continue
        if not all(index_is_in_ranges(index, ranges) for index in range(j1, j2)):
            snippet = "\n".join(current[j1:j2][:12])
            raise AssertionError(
                f"{relative}: non-Dolphin shared change outside markers:\n{snippet}"
            )


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"Missing {label}: {needle}")


def forbid(text: str, needle: str, label: str) -> None:
    if needle in text:
        raise AssertionError(f"Forbidden {label}: {needle}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="origin/main")
    args = parser.parse_args()
    base = args.base

    files = changed_files(base)
    unexpected = [path for path in files if not is_allowed(path)]
    if unexpected:
        raise SystemExit(
            "Dolphin isolation violation; unexpected changed files:\n  "
            + "\n  ".join(unexpected)
        )

    # Existing system definitions, integrations and StikJIT contracts are
    # protected by the allowlist. This explicit check produces a clearer error.
    protected_prefixes = (
        "assets/systems/",
        "packages/stikjit_bridge/",
        "lib/services/stikjit_",
        "lib/services/retroarch_",
        "lib/services/melonx_",
        "lib/services/armsx2_",
        "lib/services/rpcs3_",
    )
    touched_protected = [
        path
        for path in files
        if path.startswith(protected_prefixes)
        and path not in {
            "lib/services/dolphin_embedded_service.dart",
            "lib/services/dolphin_internal_v2_service.dart",
        }
    ]
    if touched_protected:
        raise SystemExit(
            "An existing emulator integration was modified:\n  "
            + "\n  ".join(touched_protected)
        )

    for shared in SHARED_FILES:
        if shared in files:
            check_shared_file(base, shared)

    launcher = (ROOT / "lib/services/game/game_launch_service.dart").read_text()
    require(launcher, "DolphinInternalV2Service.isDolphinSystem", "isolated route predicate")
    require(launcher, "await DolphinInternalV2Service.launch", "embedded Dolphin launch")
    require(launcher, "Rpcs3LaunchService.launchTitle", "RPCS3 route")
    require(launcher, "MelonxLibraryService.launchGameByRomPath", "MeloNX route")
    require(launcher, "Armsx2LibraryService.launchGameByRomPath", "ARMSX2 route")
    require(launcher, "RetroArchLibraryService.launchGameByRomPath", "RetroArch route")
    if launcher.index("DolphinInternalV2Service.isDolphinSystem") > launcher.index("if (Platform.isIOS)"):
        raise AssertionError("The explicit gc/wii Dolphin route must precede the general iOS router")

    service = (ROOT / "lib/services/dolphin_internal_v2_service.dart").read_text()
    require(service, "normalized == 'gc' || normalized == 'wii'", "gc/wii-only service gate")
    require(service, "path.isWithin(normalizedLibrary, normalizedGame)", "private-library ownership check")
    require(service, "legacyHandshakeValidated", "legacy handshake gate")
    require(service, "executableMemoryValidated", "executable memory gate")
    require(service, "jitArm64Initialized", "JITARM64 gate")
    require(service, "metalInitialized", "Metal gate")
    forbid(service, "'elf'", "generic ELF association")
    forbid(service, "'dol'", "generic DOL association")
    forbid(service, "universal.js", "universal script in Dolphin service")

    helper = (ROOT / "packages/dolphin_jit_helper/ios/Classes/DolphinJITRequestHandlerBase.swift").read_text()
    require(helper, "script: .legacy", "StikJIT legacy script")
    require(helper, "targetPID:", "host PID targeting")
    forbid(helper, ".universal", "universal StikJIT helper path")

    scanner = (ROOT / "lib/providers/sqlite_config_provider/scanning.dart").read_text()
    require(scanner, "DolphinInternalV2Service.scanRootPath", "isolated Dolphin scan root")
    forbid(scanner, "romFolders: [..._config.romFolders", "global Dolphin root injection")

    # The existing bridge keeps universal.js for emulators that already use it.
    universal_files = (
        "packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift",
        "packages/stikjit_bridge/ios/Classes/NeoStationStikjitBridgePlugin.swift",
        "packages/stikjit_bridge/ios/Classes/StikjitRpcs3BridgePlugin.swift",
    )
    for relative in universal_files:
        path = ROOT / relative
        if path.is_file():
            require(path.read_text(), "script: .universal", f"existing universal JIT contract in {relative}")

    pubspec = (ROOT / "pubspec.yaml").read_text()
    require(pubspec, "stikjit_bridge:", "existing StikJIT dependency")
    require(pubspec, "dolphin_internal_bridge:", "isolated Dolphin bridge dependency")

    workflow_baseline = baseline_text(base, "build-ipa.yml")
    if (ROOT / "build-ipa.yml").read_text() != workflow_baseline:
        raise AssertionError("The stable global IPA workflow was modified")

    # No source outside the approved Dolphin/shared files may reference the new
    # service; this catches accidental route interception.
    approved_references = {
        "lib/services/dolphin_internal_v2_service.dart",
        "lib/services/game/game_launch_service.dart",
        "lib/providers/sqlite_config_provider.dart",
        "lib/providers/sqlite_config_provider/scanning.dart",
        "lib/screens/game_screen/my_games_list.dart",
        "lib/widgets/dolphin_internal_playlist_actions.dart",
    }
    for dart in (ROOT / "lib").rglob("*.dart"):
        relative = dart.relative_to(ROOT).as_posix()
        if relative in approved_references:
            continue
        if "DolphinInternalV2Service" in dart.read_text(encoding="utf-8"):
            raise AssertionError(f"Dolphin service leaked into unrelated source: {relative}")

    print("Dolphin isolation and existing-emulator non-regression contracts passed.")
    print("Changed files:")
    for relative in files:
        print(f"  {relative}")


if __name__ == "__main__":
    main()
