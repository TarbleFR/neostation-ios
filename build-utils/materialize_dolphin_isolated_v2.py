#!/usr/bin/env python3
"""Normalize the already-materialized isolated-v3 Dolphin source tree.

The branch itself is the source of truth. This script applies only small,
idempotent compatibility repairs required by the current Flutter/Xcode toolchain
and refuses to recreate the integration from another branch.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REQUIRED = (
    "packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.mm",
    "packages/dolphin_jit_helper/ios/Classes/DolphinJITRequestHandlerBase.swift",
    "native/dolphin_internal_helper/DolphinJITExtensionEntry.swift",
    "build-utils/configure_dolphin_ios_v2.py",
    "build-utils/patch_dolphin_internal_core_v2.py",
    "build-utils/check_dolphin_isolation_v2.py",
    "build-utils/Gemfile.dolphin",
    "lib/services/dolphin_internal_v2_service.dart",
    "lib/widgets/dolphin_internal_playlist_actions.dart",
)


def read(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        raise SystemExit(f"Missing isolated-v3 source: {relative}")
    return path.read_text(encoding="utf-8")


def write_if_changed(relative: str, text: str) -> None:
    path = ROOT / relative
    previous = path.read_text(encoding="utf-8")
    if previous != text:
        path.write_text(text, encoding="utf-8")
        print(f"normalized: {relative}")


for required in REQUIRED:
    read(required)

# Keep Build 194 deterministic without changing the public version name.
pubspec = read("pubspec.yaml")
updated_pubspec, count = re.subn(
    r"(?m)^(version:\s*[^+\s]+)\+\d+\s*$",
    r"\1+194",
    pubspec,
    count=1,
)
if count != 1:
    raise SystemExit("pubspec.yaml does not contain one version/build line")
write_if_changed("pubspec.yaml", updated_pubspec)

service_relative = "lib/services/dolphin_internal_v2_service.dart"
service = read(service_relative)
service = service.replace("import 'dart:typed_data';\n", "")
service = service.replace("FilePicker.platform.pickFiles(", "FilePicker.pickFiles(")
service = service.replace(
    """      await File(path.join(root.path, 'CrashMarkers', 'active-session.json'))
          .delete()
          .catchError((_) {});
""",
    """      final marker = File(
        path.join(root.path, 'CrashMarkers', 'active-session.json'),
      );
      await _deleteIfExists(marker);
""",
)
service = service.replace(
    "throw const FileSystemException('Copied image length mismatch');",
    "throw FileSystemException('Copied image length mismatch');",
)
for old, new in {
    "await output.delete().catchError((_) {});": "await _deleteIfExists(output);",
    "await temporary.delete().catchError((_) {});": "await _deleteIfExists(temporary);",
    "await target.delete().catchError((_) {});": "await _deleteIfExists(target);",
    "await marker.delete().catchError((_) {});": "await _deleteIfExists(marker);",
}.items():
    service = service.replace(old, new)
if "FilePicker.platform" in service:
    raise SystemExit("FilePicker.platform remains in Dolphin service")
if ".catchError((_) {})" in service:
    raise SystemExit("untyped catchError cleanup remains in Dolphin service")
write_if_changed(service_relative, service)

launcher_relative = "lib/services/game/game_launch_service.dart"
launcher = read(launcher_relative)
broken_diagnostic = """            'Dolphin stage: ${report.failedStage ?? \"unknown\"}
Log: ${report.logPath}',
"""
fixed_diagnostic = """            'Dolphin stage: ${report.failedStage ?? \"unknown\"}\\n'
            'Log: ${report.logPath}',
"""
if broken_diagnostic in launcher:
    launcher = launcher.replace(broken_diagnostic, fixed_diagnostic, 1)
if "Dolphin stage: ${report.failedStage ?? \"unknown\"}\nLog:" in launcher:
    raise SystemExit("Dolphin diagnostic still contains a literal newline")
write_if_changed(launcher_relative, launcher)

# Align the generated Objective-C++ bridge with the pinned Dolphin headers.
core_relative = "build-utils/patch_dolphin_internal_core_v2.py"
core = read(core_relative)
core = core.replace(
    '#include "Core/PowerPC/PowerPC.h"\n',
    '#include "Core/PowerPC/JitInterface.h"\n#include "Core/PowerPC/PowerPC.h"\n',
)
core = core.replace('    Config::Init();\n', '')
core = core.replace('    File::SetSysDirectory(g_system_directory);\n', '')
core = core.replace(
    '    UICommon::InitControllers();\n',
    '    WindowSystemInfo controller_wsi;\n'
    '    controller_wsi.type = WindowSystemType::iOS;\n'
    '    UICommon::InitControllers(controller_wsi);\n'
    '    DolphinAnalytics::Instance().ReportDolphinStart("neostation-ios");\n',
)
core = core.replace(
    '#include "Core/Core.h"\n',
    '#include "Core/Core.h"\n#include "Core/DolphinAnalytics.h"\n',
)
core = core.replace('    Config::Shutdown();\n', '')
core = core.replace(
    '      PowerPC::GetCPUCore() != nullptr)',
    '      Core::System::GetInstance().GetJitInterface().GetCore() != nullptr)',
)
for forbidden in (
    'File::SetSysDirectory(g_system_directory)',
    'UICommon::InitControllers();',
    'PowerPC::GetCPUCore()',
):
    if forbidden in core:
        raise SystemExit(f"Pinned Dolphin-incompatible API remains: {forbidden}")
for required in (
    'UICommon::InitControllers(controller_wsi);',
    'DolphinAnalytics::Instance().ReportDolphinStart("neostation-ios");',
    'GetJitInterface().GetCore() != nullptr',
):
    if required not in core:
        raise SystemExit(f"Required pinned Dolphin API missing: {required}")
write_if_changed(core_relative, core)

# macOS runners execute /bin/bash 3.2, which has no mapfile builtin.
workflow_relative = ".github/workflows/dolphin-internal-isolated-v3.yml"
workflow = read(workflow_relative)
workflow = workflow.replace(
    """          mapfile -t APPS < <(find "$PRODUCTS" -maxdepth 1 -type d -name '*.app' -print)
          test "${#APPS[@]}" -eq 1
          APP="${APPS[0]}"
""",
    """          APP=$(find "$PRODUCTS" -maxdepth 1 -type d -name '*.app' -print -quit)
          test -n "$APP"
          test "$(find "$PRODUCTS" -maxdepth 1 -type d -name '*.app' -print | wc -l | tr -d ' ')" -eq 1
""",
)
workflow = workflow.replace(
    """          mapfile -t HELPERS < <(find "$APP" -type d -name 'DolphinJITHelper.appex' -print)
          test "${#HELPERS[@]}" -eq 1
          HELPER="${HELPERS[0]}"
""",
    """          HELPER=$(find "$APP" -type d -name 'DolphinJITHelper.appex' -print -quit)
          test -n "$HELPER"
          test "$(find "$APP" -type d -name 'DolphinJITHelper.appex' -print | wc -l | tr -d ' ')" -eq 1
""",
)
workflow = workflow.replace(
    """          mapfile -t STIKS < <(find "$APP" -type d -name 'StikJIT.framework' -print)
          test "${#STIKS[@]}" -eq 1
          STIK="${STIKS[0]}/StikJIT"
""",
    """          APP_STIK="$APP/Frameworks/StikJIT.framework"
          HELPER_STIK="$HELPER/Frameworks/StikJIT.framework"
          test -d "$APP_STIK"
          test -d "$HELPER_STIK"
          test "$(find "$APP/Frameworks" -maxdepth 1 -type d -name 'StikJIT.framework' -print | wc -l | tr -d ' ')" -eq 1
          test "$(find "$HELPER/Frameworks" -maxdepth 1 -type d -name 'StikJIT.framework' -print | wc -l | tr -d ' ')" -eq 1
          STIK="$HELPER_STIK/StikJIT"
""",
)
if "mapfile -t" in workflow:
    raise SystemExit("Bash 4 mapfile remains in the macOS workflow")
write_if_changed(workflow_relative, workflow)

# The materialized shared files must retain explicit isolation markers.
for shared in (
    "lib/services/game/game_launch_service.dart",
    "lib/providers/sqlite_config_provider.dart",
    "lib/providers/sqlite_config_provider/scanning.dart",
    "lib/screens/game_screen/my_games_list.dart",
):
    text = read(shared)
    if "DOLPHIN_ISOLATION_BEGIN" not in text or "DOLPHIN_ISOLATION_END" not in text:
        raise SystemExit(f"Missing Dolphin isolation markers in {shared}")

print("Isolated Dolphin v3 source normalization complete.")
