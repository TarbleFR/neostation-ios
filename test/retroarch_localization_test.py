#!/usr/bin/env python3
"""Validate RetroArch and library visibility locale coverage before packaging."""
from collections import Counter
from pathlib import Path
import json
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
LOCALES = {'en', 'es', 'ru', 'zh', 'zh_Hant', 'pt', 'fr', 'de', 'it', 'id', 'ja', 'ko'}
PLACEHOLDERS = re.compile(r'\{[a-zA-Z_][a-zA-Z_0-9]*\}')
NATIVE_KEYS = set('menuTitle resumeGame createState loadState coreOptions shaders overlays '
                  'cheats quitGame back slot enabled disabled noItems operationFailed loading '
                  'none cancel confirm addCheat importCheats cheatDescription cheatCode '
                  'deleteCheat filesHelp menuAccessibility quitConfirm overwriteState apply '
                  'unavailable savedState emptyState deleteConfirm'.split())
IMPORT_KEYS = set('import games gamesFolder bios biosFolder files folderHelp imported importFailed '
                  'core coreUnavailable coreSaved launchFailed unsupportedCore busy replaceTitle '
                  'replaceHelp skipExisting scan'.split())
MIGRATION_KEYS = set('retroarchMigrationTitle retroarchMigrationBody retroarchMigrationAccept '
                     'retroarchMigrationKeepExternal retroarchMigrationLater '
                     'retroarchMigrationFailure retroarchMigrationUnavailable '
                     'migrationCopyAndSwitch migrationSwitchOnly migrationChooseFolder '
                     'migrationFolderHelp migrationCategories migrationBios migrationGames '
                     'migrationSaves migrationStates migrationConfigs migrationShaders '
                     'migrationOverlays migrationCheats migrationKeepExisting '
                     'migrationReplaceWithBackup migrationCopied migrationCopyFailure '
                     'migrationSourceMissing migrationProgress technicalDetails'.split())


def read_dart_catalogue(path):
    source = path.read_text(encoding='utf-8')
    match = re.search(r'static const values\s*=\s*<String,\s*Map<String,\s*String>>\s*'
                      r'(\{.*\});\s*\}', source, re.S)
    if not match:
        raise AssertionError(f'Cannot locate public const catalogue in {path}')
    # Dart format adds trailing commas to the JSON-compatible map literal.
    return json.loads(re.sub(r',\s*(?=})', '', match[1])), source


class RetroArchLocalizationTests(unittest.TestCase):
    def setUp(self):
        self.retroarch, self.ra_source = read_dart_catalogue(ROOT / 'lib/l10n/retroarch_locale.dart')
        self.visibility, self.visibility_source = read_dart_catalogue(
            ROOT / 'lib/l10n/library_visibility_locale.dart')

    def test_twelve_locales_same_keys_and_placeholders(self):
        for name, catalogues in [('RetroArch', self.retroarch), ('visibility', self.visibility)]:
            self.assertEqual(set(catalogues), LOCALES, name)
            expected = catalogues['en']
            for locale, catalogue in catalogues.items():
                with self.subTest(catalogue=name, locale=locale):
                    self.assertEqual(set(catalogue), set(expected))
                    for key, value in catalogue.items():
                        self.assertIsInstance(value, str)
                        self.assertTrue(value.strip(), f'{name}/{locale}/{key} is empty')
                        self.assertEqual(Counter(PLACEHOLDERS.findall(value)),
                                         Counter(PLACEHOLDERS.findall(expected[key])),
                                         f'{name}/{locale}/{key} placeholders')

    def test_all_surface_contracts_translated(self):
        self.assertTrue(NATIVE_KEYS | IMPORT_KEYS | MIGRATION_KEYS <= set(self.retroarch['en']))
        self.assertTrue(set('title description manage keepData empty saveFailed ports continue'.split())
                        <= set(self.visibility['en']))
        menu = ROOT / 'packages/retroarch_internal_bridge/ios/Classes/RetroArchSessionMenu.mm'
        self.assertTrue(menu.is_file(), 'RetroArch native menu missing')
        used = set(re.findall(r'\btext\s*:\s*@"(\w+)"', menu.read_text(encoding='utf-8')))
        self.assertTrue(used <= set(self.retroarch['en']), f'Untranslated native menu keys: {used - set(self.retroarch["en"])}')
        plugin = (ROOT / 'packages/retroarch_internal_bridge/ios/Classes/RetroArchInternalBridgePlugin.mm').read_text(encoding='utf-8')
        required = re.search(r'RequiredLabels\(\)\s*\{\s*return\s*@\[(.*?)\];', plugin, re.S)
        self.assertIsNotNone(required, 'Native localization requirement missing')
        required_keys = set(re.findall(r'@"(\w+)"', required[1]))
        self.assertTrue(required_keys <= set(self.retroarch['en']),
                        f'Untranslated native bridge keys: {required_keys - set(self.retroarch["en"])}')
        dialog = ROOT / 'lib/widgets/retroarch_migration_dialog.dart'
        if dialog.is_file():
            dialog_keys = set(re.findall(r"\b_text\('([a-zA-Z]\w*)'\)",
                                        dialog.read_text(encoding='utf-8')))
            self.assertTrue(dialog_keys <= set(self.retroarch['en']),
                            f'Untranslated migration dialog keys: {dialog_keys - set(self.retroarch["en"])}')

    def test_native_catalogue_is_identical(self):
        native = json.loads((ROOT / 'native/retroarch/localizations.json').read_text(encoding='utf-8'))
        self.assertEqual(native, self.retroarch)

    def test_traditional_resolvers_cover_script_and_regions(self):
        # Executable resolver cases are also covered by retroarch_locale_test.dart.
        for source in [self.ra_source, self.visibility_source]:
            self.assertRegex(source, r"scriptCode\?\.toLowerCase\(\)\s*==\s*'hant'")
            for region in ['TW', 'HK', 'MO']:
                self.assertRegex(source, rf"country\s*==\s*'{region}'")
            self.assertIn("return 'zh_Hant';", source)
        self.assertNotEqual(self.retroarch['zh']['resumeGame'], self.retroarch['zh_Hant']['resumeGame'])
        self.assertNotEqual(self.visibility['zh']['title'], self.visibility['zh_Hant']['title'])


if __name__ == '__main__':
    unittest.main()
