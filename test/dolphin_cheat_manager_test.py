#!/usr/bin/env python3
"""Regression contract for NeoStation's embedded Dolphin cheat manager.

This test intentionally checks the generated native bridge and host UI together.
The native workflow separately compiles the exact pinned DolphiniOS revision.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "build-utils/patch_dolphin_internal_core_v2.py"
MENU_H = ROOT / "packages/dolphin_internal_bridge/ios/Classes/DolphinSessionMenu.h"
MENU_MM = ROOT / "packages/dolphin_internal_bridge/ios/Classes/DolphinSessionMenu.mm"
PLUGIN = ROOT / "packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.mm"
LOCALE = ROOT / "lib/l10n/dolphin_import_locale.dart"


def main() -> None:
    patch = PATCH.read_text()
    menu_h = MENU_H.read_text()
    menu = MENU_MM.read_text()
    plugin = PLUGIN.read_text()
    locale = LOCALE.read_text()

    # Native code must use Dolphin's real cheat subsystems and exact game identity.
    for needle in (
        '#include "Core/GeckoCode.h"',
        '#include "Core/GeckoCodeConfig.h"',
        '#include "Core/ActionReplay.h"',
        'g_game_id = volume->GetGameID();',
        'g_gametdb_id = volume->GetGameTDBID();',
        'g_game_revision = volume->GetRevision().value_or(0);',
        'Gecko::LoadCodes(defaults, local)',
        'ActionReplay::LoadCodes(defaults, local)',
        'Gecko::DownloadCodes(g_gametdb_id, &downloaded)',
        'Gecko::SaveCodes(local, codes)',
        'ActionReplay::SaveCodes(&local, codes)',
        'Gecko::SetActiveCodes(codes, g_game_id, g_game_revision)',
        'ActionReplay::ApplyCodes(codes, g_game_id, g_game_revision)',
        'Config::MAIN_ENABLE_CHEATS',
        'neostation_dolphin_cheats_snapshot',
        'neostation_dolphin_download_gecko_codes',
    ):
        assert needle in patch, needle

    # The host menu exposes master toggle, download, and individual code toggles.
    for needle in (
        'readCheats',
        'performCheatCommand',
        'DOLMenuCheats',
        '@"cheats": @"bolt.shield"',
        '@"downloadGecko"',
        '@"geckoCodes"',
        '@"actionReplayCodes"',
    ):
        assert needle in (menu_h + menu), needle
    for needle in (
        'neostation_dolphin_cheats_snapshot',
        'neostation_dolphin_set_cheats_enabled',
        'neostation_dolphin_set_cheat_enabled',
        'neostation_dolphin_download_gecko_codes',
        'menu.readCheats',
        'menu.performCheatCommand',
    ):
        assert needle in plugin, needle

    # Every NeoStation locale must carry the new cheat labels.
    locales = ("en", "fr", "de", "es", "pt", "ru", "id", "it", "ja", "ko", "zh", "zh_Hant")
    for language in locales:
        marker = f'"{language}": {{'
        start = locale.index(marker)
        next_positions = [
            locale.find(f'"{other}": {{', start + len(marker))
            for other in locales
            if locale.find(f'"{other}": {{', start + len(marker)) >= 0
        ]
        end = min(next_positions) if next_positions else len(locale)
        block = locale[start:end]
        for key in ("cheats", "enableCheats", "downloadGecko", "geckoCodes",
                    "actionReplayCodes", "cheatsHelp", "downloadedCodes",
                    "cheatDownloadFailed", "cheatUpdated"):
            assert f'"{key}":' in block, (language, key)

    print("PASS: Dolphin native Gecko/Action Replay manager and 12-locale UI contract")


if __name__ == "__main__":
    main()
