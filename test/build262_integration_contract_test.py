#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

manager = (
    ROOT / "packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift"
).read_text()
provider = (ROOT / "native/local_jit_tunnel/PacketTunnelProvider.swift").read_text()
configurator = (ROOT / "build-utils/configure_local_jit_tunnel.py").read_text()
full_theme = (ROOT / "lib/services/full_theme_service.dart").read_text()
locale = (ROOT / "lib/l10n/full_theme_locale.dart").read_text()
settings = (
    ROOT / "lib/screens/settings_screen/new_settings_options/themes_settings_content.dart"
).read_text()
workflow = (ROOT / ".github/workflows/build-ipa-once.yml").read_text()
core_builder = (ROOT / "build-utils/build_rpcs3_embedded_core.sh").read_text()

# VPN startup must match the proven LocalDevVPN host/provider contract and
# recover from the stale .connecting race that caused the 45 second timeout.
for token in (
    "static let schemaVersion = 2",
    "NEOnDemandRuleEvaluateConnection()",
    "NEEvaluateConnectionRule(",
    "waitForExistingConnectionOrRestart",
    "waitUntilStoppedThenStart",
    "startExplicitly",
):
    assert token in manager, token
assert "com.apple.developer.networking.vpn.api" not in manager
assert "allow-vpn" not in manager
assert "settings.mtu = 1500" not in provider
for token in (
    "com.apple.developer.networking.networkextension",
    "packet-tunnel-provider",
):
    assert token in configurator, token
assert "com.apple.developer.networking.vpn.api" not in configurator
assert "allow-vpn" not in configurator

# Arcade Planet is downloaded from the original repository at a pinned revision
# and is not bundled into the IPA.
for token in (
    "4314e02ad7fdc0abec4cfba17ddfc1ea735b6fbf",
    "https://codeload.github.com/EvilDindon/ES-THEME-ARCADEPLANET/zip/",
    "downloadArcadePlanet",
    "_maxRemoteArchiveBytes",
    "importZip(archive)",
):
    assert token in full_theme, token
assert "FullThemeLocale.downloadArcadePlanet" in settings
assert "FullThemeLocale.downloading" in settings
assert "FullThemeLocale.downloadError" in settings

for language in (
    "de", "en", "es", "fr", "id", "it", "ja", "ko", "pt", "ru", "zh", "zh_Hant"
):
    assert f"'{language}':" in locale, language
assert "_downloadArcadePlanet" in locale
assert "_downloading" in locale
assert "_downloadError" in locale

# Preserve the final Build 260 feature set while adding Build 262 integration.
for token in (
    "patch_rpcs3_build260_modern_menu.py",
    "dolphin_achievements_hacks_menu_test.py",
    "integrated_import_tab_contract_test.py",
    "-DUSE_RETRO_ACHIEVEMENTS=ON",
):
    assert token in workflow, token
for token in (
    "name: NeoStation iOS Build 262",
    "- experimental",
    "BUILD_NUMBER: '262'",
    "NeoStation-iOS-Build-262-VPN-FullTheme",
):
    assert token in workflow, token
assert "work/ui-dolphin-build260" not in workflow
assert "BUILD_NUMBER=262" in core_builder
assert "NeoStation-iOS-Build-262-VPN-FullTheme" in core_builder

print("Build 262 VPN/full-theme integration contract: OK")
