from pathlib import Path

settings = Path('lib/screens/settings_screen/new_settings_options/themes_settings_content.dart').read_text()
workflow = Path('.github/workflows/build-ipa-once.yml').read_text()
dolphin_patch = Path('build-utils/patch_dolphin_internal_core_v2.py').read_text()
game_list = Path('lib/screens/game_screen/my_games_list.dart').read_text()


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
require(
    game_list,
    'importAction:',
    '_buildEmbeddedDolphinImportAction()',
    '_buildEmbeddedRpcs3ImportAction()',
)
print('Full Theme + Build 260 preservation contract passed')
