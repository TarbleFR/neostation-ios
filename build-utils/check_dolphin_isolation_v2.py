#!/usr/bin/env python3
"""Fail CI when Dolphin changes anything outside its explicit gc/wii surface.

Shared NeoStation files may change only inside paired DOLPHIN_ISOLATION markers.
Whitespace-only formatting adjacent to a marked block is ignored, while every
non-whitespace source change outside the block remains fatal.
"""

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
    ".github/workflows/dolphin-internal-isolated-v3.yml",
    "pubspec.yaml",
    "pubspec.lock",
    "build-utils/Gemfile.dolphin",
    "build-utils/materialize_dolphin_isolated_v2.py",
    "build-utils/patch_dolphin_internal_core_v2.py",
    "build-utils/configure_dolphin_ios_v2.py",
    "build-utils/check_dolphin_isolation_v2.py",
    "lib/services/dolphin_internal_v2_service.dart",
    "lib/widgets/dolphin_internal_playlist_actions.dart",
    *SHARED_FILES,
}
ALLOWED_PREFIXES = (
    "packages/dolphin_internal_bridge/",
    "packages/dolphin_jit_helper/",
    "native/dolphin_internal_helper/",
    "test/dolphin_",
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


def adjacent_to_range(index: int, ranges: list[tuple[int, int]]) -> bool:
    return any(index in {start - 1, start, end - 1, end} for start, end in ranges)


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
            deleted = baseline[i1:i2]
            if all(not line.strip() for line in deleted):
                continue
            probes = [max(0, j1 - 1), min(max(0, len(current) - 1), j1)]
            if not any(
                index_is_in_ranges(probe, ranges) or adjacent_to_range(probe, ranges)
                for probe in probes
            ):
                raise AssertionError(
                    f"{relative}: deletion outside a Dolphin marker at baseline lines "
                    f"{i1 + 1}-{i2}"
                )
            continue

        violations = [
            index
            for index in range(j1, j2)
            if current[index].strip() and not index_is_in_ranges(index, ranges)
        ]
        if violations:
            snippet = "\n".join(current[j1:j2][:16])
            raise AssertionError(
                f"{relative}: non-Dolphin shared change outside markers:\n{snippet}"
            )


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"Missing {label}: {needle}")


def forbid(text: str, needle: str, label: str) -> None:
    if needle in text:
        raise AssertionError(f"Forbidden {label}: {needle}")


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="origin/main")
    args = parser.parse_args()
    base = args.base

    changed = changed_files(base)
    unexpected = sorted(path for path in changed if not is_allowed(path))
    if unexpected:
        raise AssertionError(
            "Dolphin branch changed files outside its isolated surface:\n"
            + "\n".join(unexpected)
        )

    for shared in sorted(SHARED_FILES):
        if shared in changed:
            check_shared_file(base, shared)

    launcher = read("lib/services/game/game_launch_service.dart")
    require(launcher, "DolphinInternalV2Service.isDolphinSystem", "gc/wii gate")
    require(launcher, "DolphinInternalV2Service.launch", "internal Dolphin call")
    for preserved in (
        "Rpcs3LaunchService.launchTitle",
        "MelonxLibraryService.launchGameByRomPath",
        "Armsx2LibraryService.launchGameByRomPath",
        "RetroArchLibraryService.launchGameByRomPath",
    ):
        require(launcher, preserved, f"preserved launcher {preserved}")

    service = read("lib/services/dolphin_internal_v2_service.dart")
    require(service, "normalized == 'gc' || normalized == 'wii'", "strict systems")
    for extension in ("'iso'", "'gcm'", "'ciso'", "'gcz'", "'rvz'", "'wia'", "'wbfs'", "'wad'", "'tgc'"):
        require(service, extension, f"Dolphin image extension {extension}")
    forbid(service, "'elf'", "generic ELF ownership")
    forbid(service, "'dol'", "generic DOL ownership")

    helper = read(
        "packages/dolphin_jit_helper/ios/Classes/DolphinJITRequestHandlerBase.swift"
    )
    require(helper, "script: .legacy", "Dolphin legacy StikJIT policy")
    forbid(helper, ".universal", "universal StikJIT in Dolphin helper")

    for shared_jit in (
        "packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift",
        "packages/stikjit_bridge/ios/Classes/NeoStationStikjitBridgePlugin.swift",
        "packages/stikjit_bridge/ios/Classes/StikjitRpcs3BridgePlugin.swift",
    ):
        path = ROOT / shared_jit
        if path.is_file():
            require(path.read_text(encoding="utf-8"), "script: .universal", shared_jit)
        if shared_jit in changed:
            raise AssertionError(f"Shared StikJIT implementation changed: {shared_jit}")

    active_roots = (
        ROOT / "lib",
        ROOT / "packages/dolphin_internal_bridge",
        ROOT / "packages/dolphin_jit_helper",
        ROOT / "native/dolphin_internal_helper",
    )
    forbidden_tokens = (
        "dolphinios://",
        "dolphin-emu://",
        "DolphinSingleSessionLaunchScript",
        "DolphinRuntimeLaunchScript",
        "StikjitDolphinBridgePlugin",
        "universal.js",
    )
    offenders: list[str] = []
    for source_root in active_roots:
        if not source_root.exists():
            continue
        for path in source_root.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in {
                ".dart", ".swift", ".m", ".mm", ".h", ".plist", ".yaml", ".yml"
            }:
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for token in forbidden_tokens:
                if token in text:
                    offenders.append(f"{path.relative_to(ROOT)}: {token}")
    if offenders:
        raise AssertionError(
            "Forbidden external or universal Dolphin route found:\n"
            + "\n".join(offenders)
        )

    protected_prefixes = (
        "assets/systems/",
        "lib/services/retroarch_",
        "lib/services/armsx2_",
        "lib/services/melonx_",
        "lib/services/rpcs3_",
        "packages/stikjit_bridge/",
    )
    protected_changes = [
        path for path in changed if path.startswith(protected_prefixes)
    ]
    if protected_changes:
        raise AssertionError(
            "Existing emulator integration changed:\n" + "\n".join(protected_changes)
        )

    print("Dolphin isolation guard passed.")
    print("Routes: gc -> internal Dolphin; wii -> internal Dolphin; all others unchanged.")
    print(f"Audited {len(changed)} changed files against {base}.")


if __name__ == "__main__":
    main()
