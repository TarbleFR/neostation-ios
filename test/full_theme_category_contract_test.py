from pathlib import Path

settings = Path('lib/screens/settings_screen/new_settings_options/themes_settings_content.dart').read_text()
workflow = Path('.github/workflows/build-ipa-once.yml').read_text()
dolphin_patch = Path('build-utils/patch_dolphin_internal_core_v2.py').read_text()

def require(text, *markers):
    for marker in markers:
        assert marker in text, marker

require(
    settings,
    'FullThemeLocale.title(context)',
    '_FullThemeCategoryCard',
    'fullThemeIndex',
    "allowedExtensions: const ['zip']",
    'FullThemeService.instance.importZip',
    'activeTheme?.name ?? FullThemeLocale.import(context)',
)
require(
    workflow,
    'Build 262',
    'work/full-theme-build262-sync260',
    'patch_rpcs3_build260_modern_menu.py',
    'dolphin_achievements_hacks_menu_test.py',
    'integrated_import_tab_contract_test.py',
    '-DUSE_RETRO_ACHIEVEMENTS=ON',
)
require(
    dolphin_patch,
    'neostation_dolphin_configure_achievements',
    'graphics.hack_applied',
)
print('Build 262 Full Theme + Build 260 preservation contract passed')
