from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def write(rel: str, text: str) -> None:
    path = ROOT / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def replace_required(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"Missing anchor for {label}")
    return text.replace(old, new, 1)


def remove_between(text: str, start: str, end: str, label: str) -> str:
    start_index = text.find(start)
    if start_index < 0:
        raise RuntimeError(f"Missing start marker for {label}")
    end_index = text.find(end, start_index)
    if end_index < 0:
        raise RuntimeError(f"Missing end marker for {label}")
    return text[:start_index] + text[end_index:]


# ---------------------------------------------------------------------------
# Library UI: user-installed/imported sources only.
# ---------------------------------------------------------------------------
screen_path = "lib/screens/library_screen/library_screen.dart"
screen = read(screen_path)

screen = screen.replace(
    "import 'package:neostation/services/library_mangadex_service.dart';\n", ""
)
screen = screen.replace("_NativeLibraryEntry", "_LibraryEntry")
screen = screen.replace("_refreshNativeLibrary", "_refreshLibrary")
screen = screen.replace("_buildNativeLibrarySliver", "_buildLibrarySliver")
screen = screen.replace(
    "/// Native reading Library for iOS.\n", "/// Reading Library for iOS.\n"
)

screen = re.sub(
    r"\n\s*bool get isMangaDex => providerId == LibraryMangaDexService\.providerId;\n",
    "\n",
    screen,
    count=1,
)
screen = re.sub(
    r"\n\s*final LibraryMangaDexService _mangaDexService =\n\s*LibraryMangaDexService\.instance;\n",
    "\n",
    screen,
    count=1,
)
screen = screen.replace(
    "      LibraryMangaDexService.providerId: 'MangaDex',\n", ""
)

old_label = """      final label = entry.isMangaDex
          ? 'MangaDex'
          : (_metadataProviderService.labelFor(entry.providerId) ??
                (entry.source?.name.trim().isNotEmpty == true
                    ? entry.source!.name.trim()
                    : entry.providerId));
"""
new_label = """      final label =
          _metadataProviderService.labelFor(entry.providerId) ??
          (entry.source?.name.trim().isNotEmpty == true
              ? entry.source!.name.trim()
              : entry.providerId);
"""
screen = replace_required(screen, old_label, new_label, "source label")

screen = screen.replace(
    "      // The native Library remains usable even if the bundled provider registry\n"
    "      // cannot be loaded for some reason.\n",
    "      // User-imported metadata registries are optional.\n",
)

screen = re.sub(
    r"\n    try \{\n      final nativeItems = await _mangaDexService\.loadPopular\(\);.*?\n    \} catch \(_\) \{\n      failures\+\+;\n    \}\n\n    final aidokuAddons",
    "\n\n    final aidokuAddons",
    screen,
    count=1,
    flags=re.S,
)

screen = re.sub(
    r"(    final futures = <Future<List<_LibraryEntry>>>\[\n)"
    r"      \(\) async \{\n        try \{\n          final items = await _mangaDexService\.searchTitles\(query\);.*?"
    r"      \}\(\),\n(      _searchMetadataProviders\(query\),)",
    r"\1\2",
    screen,
    count=1,
    flags=re.S,
)

screen = re.sub(
    r"\n    if \(entry\.isMangaDex\) \{\n      await _openMangaDexTitle\(entry\.item\);\n      return;\n    \}\n",
    "\n",
    screen,
    count=1,
)

screen = remove_between(
    screen,
    "  Future<void> _openMangaDexTitle(LibraryCatalogItem item) async {\n",
    "  Future<void> _chooseRemoveSourceOrRepository(LibraryAddon addon) async {\n",
    "MangaDex reader",
)

screen = screen.replace("    if (addon.isBuiltIn) return;\n", "")
screen = screen.replace(
    "            if (!addon.isBuiltIn)\n              TextButton.icon(\n",
    "            TextButton.icon(\n",
)
screen = re.sub(
    r"onDelete: _addons\[index\]\.isBuiltIn\n\s*\? null\n\s*: \(\) => _confirmRemoveAddon\(_addons\[index\]\),",
    "onDelete: () => _confirmRemoveAddon(_addons[index]),",
    screen,
)

screen = screen.replace(
    "Chaque source ajoutée peut être retirée individuellement. Les sources natives sont conservées.",
    "Chaque source affichée ici a été ajoutée par l’utilisateur et peut être retirée individuellement.",
)
screen = screen.replace(
    "Every added source can be removed individually. Built-in sources are kept.",
    "Every source shown here was added by the user and can be removed individually.",
)
screen = screen.replace(
    "Les $count sources importées depuis ce dépôt seront supprimées. Les autres dépôts et Gallica ne seront pas modifiés.",
    "Les $count sources importées depuis ce dépôt seront supprimées. Les autres dépôts ne seront pas modifiés.",
)
screen = screen.replace(
    "All $count sources imported from this repository will be removed. Other repositories and Gallica will not be changed.",
    "All $count sources imported from this repository will be removed. Other repositories will not be changed.",
)
screen = screen.replace("catalogue natif NeoStation", "catalogue compatible iOS")

for forbidden in (
    "LibraryMangaDexService",
    "_mangaDexService",
    "_openMangaDexTitle",
    "entry.isMangaDex",
):
    if forbidden in screen:
        raise RuntimeError(f"Library screen still contains native source reference: {forbidden}")
write(screen_path, screen)


# ---------------------------------------------------------------------------
# Add-on store: stop injecting Gallica and purge old persisted built-ins.
# ---------------------------------------------------------------------------
addon_path = "lib/services/library_addon_service.dart"
addon = read(addon_path)
addon = addon.replace(
    "  static const String gallicaProviderType = 'gallica-opds';\n", ""
)
addon = re.sub(
    r"\n  bool get isGallicaSource \{\n    final provider = manifest\['provider'\];\n    return provider is Map && provider\['type'\] == gallicaProviderType;\n  \}\n",
    "\n",
    addon,
    count=1,
)
addon = addon.replace(
    "  static const String gallicaAddonId = 'native.gallica.bnf';\n", ""
)

old_parse = """              if (addon.isRepositoryDeprecationStub) {
                needsPersist = true;
                continue;
              }
              _addons.add(addon);
"""
new_parse = """              if (addon.isBuiltIn || addon.origin.startsWith('builtin:')) {
                // Migration: older NeoStation builds persisted native sources.
                // They are no longer part of Library and are removed on load.
                needsPersist = true;
                continue;
              }
              if (addon.isRepositoryDeprecationStub) {
                needsPersist = true;
                continue;
              }
              _addons.add(addon);
"""
addon = replace_required(addon, old_parse, new_parse, "built-in migration")

addon = re.sub(
    r"\n    if \(_addons\.indexWhere\(\(item\) => item\.id == gallicaAddonId\) < 0\) \{\n"
    r"      _addons\.add\(_builtInGallicaAddon\(\)\);\n"
    r"      needsPersist = true;\n"
    r"    \}\n",
    "\n",
    addon,
    count=1,
)
addon = remove_between(
    addon,
    "  LibraryAddon _builtInGallicaAddon() {\n",
    "  Future<LibraryAddonBatchInstallResult> installDocumentFromUrl(\n",
    "built-in Gallica source",
)

for forbidden in ("gallicaAddonId", "_builtInGallicaAddon", "gallicaProviderType", "isGallicaSource"):
    if forbidden in addon:
        raise RuntimeError(f"Add-on service still contains built-in source reference: {forbidden}")
write(addon_path, addon)


# ---------------------------------------------------------------------------
# Generic catalog: remove the special built-in Gallica path/parser.
# User-installed JSON catalogs and EPUB/text readers remain supported.
# ---------------------------------------------------------------------------
catalog_path = "lib/services/library_catalog_service.dart"
catalog = read(catalog_path)
catalog = re.sub(
    r"\n    if \(addon\.isGallicaSource\) \{.*?\n    \}\n\n    final response = await _get\(uri, maxBytes: _maxCatalogBytes\);",
    "\n    final response = await _get(uri, maxBytes: _maxCatalogBytes);",
    catalog,
    count=1,
    flags=re.S,
)
catalog = remove_between(
    catalog,
    "  static List<LibraryCatalogItem> parseGallicaOpdsDocument(\n",
    "  Future<String> _loadEpubText(Uri uri) async {\n",
    "Gallica OPDS parser",
)
catalog = re.sub(
    r"\n  static String _directChildText\(XmlElement element, String localName\) \{.*?"
    r"\n  static String _normalizeArchivePath\(String value\) \{",
    "\n  static String _normalizeArchivePath(String value) {",
    catalog,
    count=1,
    flags=re.S,
)
for forbidden in ("Gallica", "isGallicaSource", "parseGallicaOpdsDocument", "gallicaProviderType"):
    if forbidden in catalog:
        raise RuntimeError(f"Catalog service still contains native Gallica code: {forbidden}")
write(catalog_path, catalog)


# ---------------------------------------------------------------------------
# Metadata adapters: keep support, but only after explicit user JSON import.
# No bundled provider registry is loaded automatically.
# ---------------------------------------------------------------------------
metadata_path = "lib/services/library_metadata_provider_service.dart"
metadata = read(metadata_path)
metadata = metadata.replace("import 'package:flutter/services.dart';\n", "")
metadata = metadata.replace(
    "/// Native adapters for the seven metadata providers declared by\n"
    "/// `assets/data/manga-providers.json`.\n"
    "///\n"
    "/// The provider registry is intentionally metadata-only. Results can enrich the\n"
    "/// Library with titles, authors, covers, descriptions, identifiers and source\n"
    "/// links. The service never invents chapter/download URLs and deliberately\n"
    "/// ignores unrelated video/trailer media.\n",
    "/// Metadata adapters activated only by a registry explicitly imported by the user.\n"
    "///\n"
    "/// NeoStation ships no built-in Library providers. Imported metadata-only\n"
    "/// registries can enrich titles, authors, covers, descriptions and identifiers,\n"
    "/// but the service never invents chapter or download URLs.\n",
)
metadata = metadata.replace(
    "  static const String manifestAsset = 'assets/data/manga-providers.json';\n", ""
)
old_init = """  Future<void> initialize() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final imported = prefs.getString(_importedRegistryPrefsKey);
    final raw = imported?.trim().isNotEmpty == true
        ? imported!
        : await rootBundle.loadString(manifestAsset);
    _providers = _parseRegistry(raw);
    _initialized = true;
  }
"""
new_init = """  Future<void> initialize() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final imported = prefs.getString(_importedRegistryPrefsKey);
    if (imported?.trim().isNotEmpty != true) {
      _providers = const <LibraryMetadataProviderDefinition>[];
      _initialized = true;
      return;
    }
    _providers = _parseRegistry(imported!);
    _initialized = true;
  }
"""
metadata = replace_required(metadata, old_init, new_init, "metadata initialize")
for forbidden in ("rootBundle", "manifestAsset", "assets/data/manga-providers.json"):
    if forbidden in metadata:
        raise RuntimeError(f"Metadata provider service still bundles providers: {forbidden}")
write(metadata_path, metadata)


# ---------------------------------------------------------------------------
# Tests: assert opt-in source behavior and remove native Gallica expectations.
# ---------------------------------------------------------------------------
metadata_test_path = "test/library_metadata_provider_service_test.dart"
metadata_test = read(metadata_test_path)
marker = "  test('parses the bundled Manga Provider registry format', () async {\n"
replacement = """  test('starts with no metadata providers without a user import', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LibraryMetadataProviderService.instance.initialize();
    expect(LibraryMetadataProviderService.instance.providers, isEmpty);
  });

  test('imports a user-supplied Manga Provider registry', () async {
"""
metadata_test = replace_required(metadata_test, marker, replacement, "metadata tests")
write(metadata_test_path, metadata_test)

catalog_test_path = "test/library_catalog_service_test.dart"
catalog_test = read(catalog_test_path)
catalog_test = catalog_test.replace(
    "group('Native Library source classification'", "group('Library source classification'"
)
catalog_test = catalog_test.replace(
    "accepts a native local-library declaration without baseUrl",
    "accepts a local-library declaration without baseUrl",
)
catalog_test = catalog_test.replace(
    "keeps Tachiyomi APK-backed entries out of the native catalog",
    "keeps Tachiyomi APK-backed entries out of the iOS catalog",
)
catalog_test = catalog_test.replace(
    "group('Native Library catalog normalization'", "group('Library catalog normalization'"
)
catalog_test = re.sub(
    r"\n    test\('parses Gallica OPDS acquisitions as readable EPUB books', \(\) \{.*?\n    \}\);",
    "",
    catalog_test,
    count=1,
    flags=re.S,
)
if "Gallica" in catalog_test:
    raise RuntimeError("Catalog tests still contain Gallica")
write(catalog_test_path, catalog_test)

addon_test_path = "test/library_addon_service_test.dart"
addon_test = read(addon_test_path)
addon_test = re.sub(
    r"\n      expect\(\n        remaining\.any\(\(item\) => item\.id == LibraryAddonService\.gallicaAddonId\),\n        isTrue,\n      \);",
    "",
    addon_test,
    count=1,
)
addon_test = re.sub(
    r"\n    test\('keeps Gallica as a built-in native catalog source', \(\) async \{.*?\n    \}\);",
    "",
    addon_test,
    count=1,
    flags=re.S,
)
if "Gallica" in addon_test or "gallicaAddonId" in addon_test:
    raise RuntimeError("Add-on tests still expect a built-in source")
write(addon_test_path, addon_test)

no_native_test = r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Library source policy', () {
    test('ships no built-in Library source', () {
      final screen = File(
        'lib/screens/library_screen/library_screen.dart',
      ).readAsStringSync();
      final addons = File(
        'lib/services/library_addon_service.dart',
      ).readAsStringSync();
      final metadata = File(
        'lib/services/library_metadata_provider_service.dart',
      ).readAsStringSync();

      expect(screen, isNot(contains('LibraryMangaDexService')));
      expect(screen, isNot(contains("'MangaDex'")));
      expect(addons, isNot(contains('_builtInGallicaAddon')));
      expect(addons, isNot(contains('native.gallica.bnf')));
      expect(metadata, isNot(contains('rootBundle.loadString')));
      expect(File('assets/data/manga-providers.json').existsSync(), isFalse);
      expect(File('lib/services/library_mangadex_service.dart').existsSync(), isFalse);
    });
  });
}
'''
write("test/library_no_native_sources_test.dart", no_native_test)


# Remove source implementations/data that made native providers available.
for rel in (
    "assets/data/manga-providers.json",
    "lib/services/library_mangadex_service.dart",
):
    (ROOT / rel).unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Repository cleanup: remove one-shot migration/apply scripts and triggers.
# The validated generated sources are now the source of truth.
# ---------------------------------------------------------------------------
for rel in (
    "tools/.fin_persistence_build_trigger",
    "tools/.fin_persistence_fix_trigger",
    "tools/apply_fin_metadata_integration.py",
    "tools/apply_fin_native_scan_fix.py",
    "tools/apply_fin_native_scan_fix_followup.py",
    "tools/apply_fin_persistence_and_launch_diagnostics.py",
    "tools/apply_fin_provider_import_fix.py",
    "tools/apply_fin_provider_import_fix_followup.py",
    "tools/apply_fin_shortcut_gameid_fix.py",
    "tools/apply_library_acquisition_integration.py",
    "tools/enable_legal_library_downloads.py",
    "tools/fix_fin_system_id.py",
    "tools/fix_library_acquisition_ci.py",
):
    (ROOT / rel).unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Replace iterative patch CI with one read-only validation/build workflow.
# ---------------------------------------------------------------------------
build_workflow = r'''name: Build Library IPA

on:
  push:
    branches:
      - feature/library-native
  workflow_dispatch: {}

permissions:
  contents: read
  statuses: write

concurrency:
  group: ios-library-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-ipa:
    name: Test and build unsigned IPA
    runs-on: macos-14
    timeout-minutes: 120

    env:
      SCREENSCRAPER_DEV_ID: ${{ secrets.SCREENSCRAPER_DEV_ID }}
      SCREENSCRAPER_DEV_PASSWORD: ${{ secrets.SCREENSCRAPER_DEV_PASSWORD }}
      GOOGLE_BOOKS_API_KEY: ${{ secrets.GOOGLE_BOOKS_API_KEY }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          ref: feature/library-native
          fetch-depth: 0

      - name: Select Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable

      - name: Set up Flutter
        uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - name: Verify committed sources are formatted
        run: |
          set -euo pipefail
          dart format --output=none --set-exit-if-changed \
            lib/services/library_addon_service.dart \
            lib/services/library_catalog_service.dart \
            lib/services/library_metadata_provider_service.dart \
            lib/services/library_download_service.dart \
            lib/services/fin_library_service.dart \
            lib/screens/library_screen/library_screen.dart \
            lib/screens/library_screen/library_pdf_reader_screen.dart \
            test/library_addon_service_test.dart \
            test/library_catalog_service_test.dart \
            test/library_metadata_provider_service_test.dart \
            test/library_acquisition_service_test.dart \
            test/library_no_native_sources_test.dart \
            test/fin_library_service_test.dart \
            test/fin_persistence_regression_test.dart
          git diff --check

      - name: Prepare build environment
        run: |
          set -euo pipefail
          mkdir -p build/ci
          python3 - <<'PY'
          import os
          import pathlib
          import sys
          required = {
              'SCREENSCRAPER_DEV_ID': os.environ.get('SCREENSCRAPER_DEV_ID', ''),
              'SCREENSCRAPER_DEV_PASSWORD': os.environ.get('SCREENSCRAPER_DEV_PASSWORD', ''),
          }
          missing = [key for key, value in required.items() if not value]
          if missing:
              print('Missing required GitHub Actions secrets: ' + ', '.join(missing))
              sys.exit(1)
          values = {
              **required,
              'GOOGLE_BOOKS_API_KEY': os.environ.get('GOOGLE_BOOKS_API_KEY', ''),
          }
          pathlib.Path('.env').write_text(
              '\n'.join(f'{key}={value}' for key, value in values.items()) + '\n',
              encoding='utf-8',
          )
          PY

      - name: Resolve Flutter dependencies
        run: |
          set -o pipefail
          flutter pub get 2>&1 | tee build/ci/pub-get.log

      - name: Patch flutter_localization Swift 5 incompatibility
        run: |
          set -euo pipefail
          PLUGIN_FILE="$HOME/.pub-cache/hosted/pub.dev/flutter_localization-0.4.1/ios/flutter_localization/Sources/flutter_localization/FlutterLocalizationPlugin.swift"
          test -f "$PLUGIN_FILE"
          python3 - "$PLUGIN_FILE" <<'PY'
          import pathlib
          import sys
          path = pathlib.Path(sys.argv[1])
          source = path.read_text(encoding='utf-8')
          bad = 'registrar.messenger(),'
          good = 'registrar.messenger()'
          if bad in source:
              path.write_text(source.replace(bad, good), encoding='utf-8')
              print('Patched iOS flutter_localization Swift 5 trailing comma')
          elif good in source:
              print('iOS flutter_localization is already compatible')
          else:
              raise SystemExit('Could not locate iOS registrar.messenger() call')
          PY

      - name: Run Library and Fin regression tests
        run: |
          set -o pipefail
          flutter test test/library_addon_service_test.dart 2>&1 | tee build/ci/test-addon.log
          flutter test test/library_catalog_service_test.dart 2>&1 | tee build/ci/test-catalog.log
          flutter test test/library_aidoku_native_service_test.dart 2>&1 | tee build/ci/test-aidoku.log
          flutter test test/library_metadata_provider_service_test.dart 2>&1 | tee build/ci/test-metadata.log
          flutter test test/library_acquisition_service_test.dart 2>&1 | tee build/ci/test-acquisition.log
          flutter test test/library_no_native_sources_test.dart 2>&1 | tee build/ci/test-no-native.log
          flutter test test/fin_library_service_test.dart 2>&1 | tee build/ci/test-fin.log
          flutter test test/fin_persistence_regression_test.dart 2>&1 | tee build/ci/test-fin-persistence.log

      - name: Analyze Flutter sources
        run: |
          set -o pipefail
          flutter analyze --no-fatal-warnings --no-fatal-infos 2>&1 | tee build/ci/analyze.log

      - name: Scaffold iOS platform if missing
        run: |
          set -euo pipefail
          if [ ! -d ios ]; then
            flutter create \
              --platforms=ios \
              --org com.neogamelab \
              --project-name neostation \
              .
          fi

      - name: Configure iOS
        run: |
          set -euo pipefail
          sed -i '' "s/platform :ios, '13.0'/platform :ios, '18.0'/" ios/Podfile
          sed -i '' \
            's/IPHONEOS_DEPLOYMENT_TARGET = 13.0;/IPHONEOS_DEPLOYMENT_TARGET = 18.0;/g' \
            ios/Runner.xcodeproj/project.pbxproj

          PLIST=ios/Runner/Info.plist
          /usr/libexec/PlistBuddy -c "Delete :UISupportedInterfaceOrientations" "$PLIST" 2>/dev/null || true
          /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations array" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations:0 string UIInterfaceOrientationLandscapeLeft" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations:1 string UIInterfaceOrientationLandscapeRight" "$PLIST"
          /usr/libexec/PlistBuddy -c "Delete :UISupportedInterfaceOrientations~ipad" "$PLIST" 2>/dev/null || true
          /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations~ipad array" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations~ipad:0 string UIInterfaceOrientationLandscapeLeft" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations~ipad:1 string UIInterfaceOrientationLandscapeRight" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :UIFileSharingEnabled bool true" "$PLIST" 2>/dev/null || true
          /usr/libexec/PlistBuddy -c "Add :LSSupportsOpeningDocumentsInPlace bool true" "$PLIST" 2>/dev/null || true

          /usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$PLIST" 2>/dev/null || true
          /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string com.neogamelab.neostation" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string neostation" "$PLIST"

          /usr/libexec/PlistBuddy -c "Delete :LSApplicationQueriesSchemes" "$PLIST" 2>/dev/null || true
          /usr/libexec/PlistBuddy -c "Add :LSApplicationQueriesSchemes array" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :LSApplicationQueriesSchemes:0 string retroarch" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :LSApplicationQueriesSchemes:1 string shortcuts" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :LSApplicationQueriesSchemes:2 string armsx2" "$PLIST"
          /usr/libexec/PlistBuddy -c "Add :LSApplicationQueriesSchemes:3 string melonx" "$PLIST"
          plutil -lint "$PLIST"

      - name: Patch device_info_plus for runner SDK
        run: |
          DEVICE_INFO_FILE=$(find "$HOME/.pub-cache" \
            -path "*device_info_plus*/FPPDeviceInfoPlusPlugin.m" \
            -print -quit)
          if [ -n "$DEVICE_INFO_FILE" ]; then
            sed -i '' '/isiOSAppOnVision/d' "$DEVICE_INFO_FILE"
          fi

      - name: Generate iOS app icons
        run: |
          set -o pipefail
          dart run flutter_launcher_icons 2>&1 | tee build/ci/icons.log
          chmod +x build-utils/force_ios_fork_icon.sh
          build-utils/force_ios_fork_icon.sh 2>&1 | tee build/ci/fork-icon.log

      - name: Install CocoaPods dependencies
        run: |
          set -o pipefail
          (cd ios && pod install --repo-update) 2>&1 | tee build/ci/pods.log

      - name: Configure Flutter release
        run: |
          set -o pipefail
          flutter build ios \
            --release \
            --no-codesign \
            --config-only \
            --dart-define-from-file=.env \
            2>&1 | tee build/ci/flutter-build.log

      - name: Build unsigned IPA
        run: |
          set -euo pipefail
          rm -rf build/ios/DerivedData build/ios/unsigned
          mkdir -p build/ios
          xcodebuild \
            -workspace ios/Runner.xcworkspace \
            -scheme Runner \
            -configuration Release \
            -sdk iphoneos \
            -destination 'generic/platform=iOS' \
            -derivedDataPath build/ios/DerivedData \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY="" \
            DEVELOPMENT_TEAM="" \
            PROVISIONING_PROFILE_SPECIFIER="" \
            COMPILER_INDEX_STORE_ENABLE=NO \
            build 2>&1 | tee build/ios/xcodebuild-unsigned.log

          APP_PATH=$(find build/ios/DerivedData/Build/Products/Release-iphoneos \
            -maxdepth 1 -type d -name '*.app' -print -quit)
          test -n "$APP_PATH"
          test -d "$APP_PATH"
          mkdir -p build/ios/unsigned/Payload
          cp -R "$APP_PATH" build/ios/unsigned/Payload/Runner.app
          (cd build/ios/unsigned && zip -qr ../../../NeoStation-Library-Native-unsigned.ipa Payload)
          test -s NeoStation-Library-Native-unsigned.ipa

      - name: Remove temporary environment file
        if: always()
        run: rm -f .env

      - name: Upload build artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: NeoStation-Library-Native-unsigned-ipa
          path: |
            NeoStation-Library-Native-unsigned.ipa
            build/ci/*.log
            build/ios/xcodebuild-unsigned.log
          if-no-files-found: warn

      - name: Report build result
        if: always()
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          if [ -s NeoStation-Library-Native-unsigned.ipa ]; then
            state=success
            description="IPA build succeeded"
          else
            state=failure
            description="IPA build failed; inspect workflow artifact logs"
          fi
          gh api --method POST "repos/${GITHUB_REPOSITORY}/statuses/${GITHUB_SHA}" \
            -f state="$state" \
            -f context=library-native-diagnostic \
            -f description="$description" \
            -f target_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
'''
write(".github/workflows/build-library-native.yml", build_workflow)

# The one-shot cleanup workflow and this script remove themselves in the
# validated source commit. Only the stable build workflow remains afterwards.
(ROOT / ".github/workflows/cleanup-library-native-sources.yml").unlink(missing_ok=True)
Path(__file__).unlink(missing_ok=True)

print("Removed built-in Library sources and prepared a clean read-only build workflow.")
