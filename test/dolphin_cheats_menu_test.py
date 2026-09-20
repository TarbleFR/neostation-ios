#!/usr/bin/env python3
"""Lock the embedded Dolphin cheat-manager contract to the pinned upstream APIs."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
core=(ROOT/'build-utils/patch_dolphin_internal_core_v2.py').read_text()
menu=(ROOT/'packages/dolphin_internal_bridge/ios/Classes/DolphinSessionMenu.mm').read_text()
plugin=(ROOT/'packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.mm').read_text()
locale=(ROOT/'lib/l10n/dolphin_import_locale.dart').read_text()
for token in (
    '#include "Core/GeckoCode.h"',
    '#include "Core/GeckoCodeConfig.h"',
    '#include "Core/ActionReplay.h"',
    'Gecko::DownloadCodes',
    'Gecko::LoadCodes',
    'Gecko::SaveCodes',
    'Gecko::SetActiveCodes',
    'ActionReplay::LoadCodes',
    'ActionReplay::SaveCodes',
    'ActionReplay::ApplyCodes',
    'CheckApprovedGeckoCode',
    'CheckApprovedARCode',
):
    assert token in core, token
assert 'neostation_dolphin_cheats_snapshot' in plugin
assert 'neostation_dolphin_download_gecko_codes' in plugin
assert 'menu.readCheats' in plugin and 'menu.performCheatCommand' in plugin
assert '@"cheats"' in menu and '@"downloadGecko"' in menu
assert 'hardcoreCheatBlocked' in menu and 'hardcoreCheatBlocked' in locale
master=core[core.index('int32_t neostation_dolphin_set_cheats_enabled'):core.index('int32_t neostation_dolphin_set_cheat_enabled')]
assert 'for (auto& code : gecko_off) code.enabled = false;' in master
assert 'for (auto& code : ar_off) code.enabled = false;' in master
assert master.index('Gecko::SetActiveCodes(gecko_off') < master.index('Config::SetBase(Config::MAIN_ENABLE_CHEATS, requested)')
toggle=core[core.index('int32_t neostation_dolphin_set_cheat_enabled'):core.index('char* neostation_dolphin_download_gecko_codes')]
assert toggle.count('requested && !Config::Get(Config::MAIN_ENABLE_CHEATS)') == 2
assert toggle.count('IsHardcoreModeActive()') == 2
print('PASS: Dolphin Gecko/Action Replay catalogue, download, live toggle, master state, and Hardcore gates')
