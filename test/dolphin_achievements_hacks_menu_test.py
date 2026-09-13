#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
patch = (root / "build-utils/patch_dolphin_internal_core_v2.py").read_text()
session = (root / "packages/dolphin_internal_bridge/core/NeoStationSession.inc").read_text()
host = (root / "packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.mm").read_text()
menu = (root / "packages/dolphin_internal_bridge/ios/Classes/DolphinSessionMenu.mm").read_text()
service = (root / "lib/services/dolphin_internal_v2_service.dart").read_text()

for token in [
    "neostation_dolphin_configure_achievements",
    "Config::RA_ENABLED",
    "Config::RA_USERNAME",
    "Config::RA_API_TOKEN",
    "AchievementManager::GetInstance()",
    "achievements.enabled",
    '@"achievements":',
]:
    assert token in patch or token in host, token

for forbidden in ["raUsername, @\"", "raApiToken, @\""]:
    assert forbidden not in host
assert "RetroAchievementsRepository.getRAApiKey()" in service

for key in [
    "viSkip", "skipEfbAccess", "ignoreFormatChanges", "efbCopyToTexture",
    "deferEfbCopies", "fastDepth", "disableBoundingBox", "vertexRounding",
]:
    assert key in patch, key
    assert key in menu, key

for token in [
    "GFX_HACK_VI_SKIP", "GFX_HACK_EFB_ACCESS_ENABLE",
    "GFX_HACK_EFB_EMULATE_FORMAT_CHANGES", "GFX_HACK_SKIP_EFB_COPY_TO_RAM",
    "GFX_HACK_DEFER_EFB_COPIES", "GFX_FAST_DEPTH_CALC",
    "GFX_HACK_BBOX_ENABLE", "GFX_HACK_VERTEX_ROUNDING",
]:
    assert token in patch or token in session, token

for token in [
    "UITableViewStyleInsetGrouped", "UIBlurEffectStyleSystemChromeMaterial",
    "secondarySystemGroupedBackgroundColor", "wrench.and.screwdriver",
]:
    assert token in menu, token

print("Dolphin achievements, hacks and modern menu contract: OK")
