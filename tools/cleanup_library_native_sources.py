from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BACKUP_BRANCH = "backup/library-native-before-library-native-sources-cleanup-20260823"


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def write(rel: str, text: str) -> None:
    path = ROOT / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"Missing anchor for {label}")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# Library policy: Gallica is no longer bundled. It remains fully compatible
# when the user imports a source that declares provider.type = gallica-opds.
# MangaDex, Manga Provider registry support, Aidoku and other compatibility
# layers are intentionally left untouched.
# ---------------------------------------------------------------------------
addon_path = "lib/services/library_addon_service.dart"
addon = read(addon_path)

addon = addon.replace(
    "  static const String gallicaAddonId = 'native.gallica.bnf';\n",
    "",
)

old_load = """              if (addon.isRepositoryDeprecationStub) {
                needsPersist = true;
                continue;
              }
              _addons.add(addon);
"""
new_load = """              if (addon.isBuiltIn || addon.origin.startsWith('builtin:')) {
                // Migration from older builds: bundled Library sources are
                // removed. Every visible source must now come from an import.
                needsPersist = true;
                continue;
              }
              if (addon.isRepositoryDeprecationStub) {
                needsPersist = true;
                continue;
              }
              _addons.add(addon);
"""
if old_load in addon:
    addon = addon.replace(old_load, new_load, 1)
elif "addon.isBuiltIn || addon.origin.startsWith('builtin:')" not in addon:
    raise RuntimeError("Could not add built-in source migration")

# The cleanup workflow may already have removed the injection block before this
# script runs, so both states are accepted.
addon = re.sub(
    r"\n    if \(_addons\.indexWhere\(\(item\) => item\.id == gallicaAddonId\) < 0\) \{\n"
    r"      _addons\.add\(_builtInGallicaAddon\(\)\);\n"
    r"      needsPersist = true;\n"
    r"    \}\n",
    "\n",
    addon,
    count=1,
)

start = addon.find("  LibraryAddon _builtInGallicaAddon() {\n")
if start >= 0:
    end_marker = "  Future<LibraryAddonBatchInstallResult> installDocumentFromUrl(\n"
    end = addon.find(end_marker, start)
    if end < 0:
        raise RuntimeError("Could not remove built-in Gallica factory")
    addon = addon[:start] + addon[end:]

# A user-imported manifest can never promote itself to a protected/native
# source. It is always an ordinary removable imported source.
map_anchor = """    if (decoded is Map) {
      final object = Map<String, dynamic>.from(decoded);
"""
map_replacement = """    if (decoded is Map) {
      final object = Map<String, dynamic>.from(decoded);
      object.remove('builtIn');
"""
if map_replacement not in addon:
    addon = replace_once(addon, map_anchor, map_replacement, "import builtIn stripping")

addon = addon.replace("    if (id == gallicaAddonId) return false;\n", "")

if "_builtInGallicaAddon" in addon or "gallicaAddonId" in addon:
    raise RuntimeError("Built-in Gallica code still exists")
if "gallicaProviderType = 'gallica-opds'" not in addon or "isGallicaSource" not in addon:
    raise RuntimeError("Imported Gallica compatibility was accidentally removed")
write(addon_path, addon)


# ---------------------------------------------------------------------------
# Library UI: remove wording that implies permanent/native sources. Keep the
# imported Gallica language fallback because it is useful after explicit import.
# ---------------------------------------------------------------------------
screen_path = "lib/screens/library_screen/library_screen.dart"
screen = read(screen_path)
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

# The current one-shot workflow removes this block before invoking us. Restore
# it so explicitly imported Gallica stays filterable as French when OPDS omits
# dc:language on an individual entry.
lang_fallback = """    // Imported Gallica OPDS entries are primarily French. Keep them
    // filterable even when an individual Atom entry omits dc:language.
    if (result.isEmpty && entry.source?.isGallicaSource == true) {
      result.add('fr');
    }

"""
if "entry.source?.isGallicaSource == true" not in screen:
    anchor = "    return result;\n  }\n\n  String _languageLabel(String code) {\n"
    if anchor not in screen:
        raise RuntimeError("Could not restore imported Gallica language fallback")
    screen = screen.replace(
        anchor,
        lang_fallback + "    return result;\n  }\n\n  String _languageLabel(String code) {\n",
        1,
    )
write(screen_path, screen)


# ---------------------------------------------------------------------------
# Tests: no bundled Gallica, but imported Gallica OPDS remains supported.
# ---------------------------------------------------------------------------
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
    """\n    test('does not inject built-in Library sources', () async {
      final sources = await LibraryAddonService.instance.load();
      expect(sources.where((item) => item.isBuiltIn), isEmpty);
      expect(sources.where((item) => item.origin.startsWith('builtin:')), isEmpty);
    });

    test('keeps explicitly imported Gallica OPDS compatible', () async {
      final raw = jsonEncode({
        'schema': LibraryAddon.schemaV1,
        'id': 'user.gallica.bnf',
        'name': 'Gallica / BnF',
        'version': '1',
        'baseUrl': 'https://gallica.bnf.fr/',
        'provider': {'type': LibraryAddon.gallicaProviderType},
        'endpoints': {
          'catalog':
              'services/engine/search/opds?operation=searchRetrieve&version=1.2&maximumRecords=50',
        },
      });

      final result = await LibraryAddonService.instance.installDocumentFromJson(
        raw,
        origin: 'file:user-gallica.json',
      );
      final gallica = result.addons.single;
      expect(gallica.isBuiltIn, isFalse);
      expect(gallica.isGallicaSource, isTrue);
      expect(gallica.canBrowseOnIos, isTrue);
    });""",
    addon_test,
    count=1,
    flags=re.S,
)
if "gallicaAddonId" in addon_test or "built-in native catalog source" in addon_test:
    raise RuntimeError("Library add-on tests still expect bundled Gallica")
write(addon_test_path, addon_test)

no_native_test = r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Library source policy', () {
    test('Gallica is import-only while compatibility remains', () {
      final addons = File(
        'lib/services/library_addon_service.dart',
      ).readAsStringSync();
      final catalog = File(
        'lib/services/library_catalog_service.dart',
      ).readAsStringSync();
      final screen = File(
        'lib/screens/library_screen/library_screen.dart',
      ).readAsStringSync();

      expect(addons, isNot(contains('_builtInGallicaAddon')));
      expect(addons, isNot(contains('gallicaAddonId')));
      expect(addons, contains("gallicaProviderType = 'gallica-opds'"));
      expect(addons, contains('isGallicaSource'));
      expect(catalog, contains('parseGallicaOpdsDocument'));
      expect(screen, isNot(contains('Les sources natives sont conservées')));
      expect(screen, contains('entry.source?.isGallicaSource == true'));
    });

    test('other Library compatibility layers remain present', () {
      expect(File('lib/services/library_mangadex_service.dart').existsSync(), isTrue);
      expect(File('assets/data/manga-providers.json').existsSync(), isTrue);
      expect(
        File('lib/services/library_metadata_provider_service.dart').existsSync(),
        isTrue,
      );
    });
  });
}
'''
write("test/library_no_native_sources_test.dart", no_native_test)


# ---------------------------------------------------------------------------
# Repository cleanup: restore the stable IPA workflow, make it read-only, and
# remove the iterative patch/apply machinery now that validated sources are
# committed.
# ---------------------------------------------------------------------------
subprocess.run(
    ["git", "fetch", "origin", BACKUP_BRANCH],
    cwd=ROOT,
    check=True,
)
subprocess.run(
    [
        "git",
        "checkout",
        f"origin/{BACKUP_BRANCH}",
        "--",
        ".github/workflows/build-library-native.yml",
    ],
    cwd=ROOT,
    check=True,
)

build_path = ".github/workflows/build-library-native.yml"
build = read(build_path)
build = build.replace("  contents: write\n", "  contents: read\n", 1)
build, n = re.subn(
    r"\n      - name: Apply Library and Fin integration fixes\n.*?(?=\n      - name: Prepare build environment)",
    "",
    build,
    count=1,
    flags=re.S,
)
if n != 1:
    raise RuntimeError("Could not remove historical patch step from build workflow")
build, n = re.subn(
    r"\n      - name: Commit validated Library and Fin sources\n.*?(?=\n      - name: Scaffold iOS platform if missing)",
    "",
    build,
    count=1,
    flags=re.S,
)
if n != 1:
    raise RuntimeError("Could not remove source-mutating CI step")

fin_test = "          flutter test test/fin_library_service_test.dart 2>&1 | tee build/ci/test-fin.log\n"
extra_tests = (
    fin_test
    + "          flutter test test/fin_persistence_regression_test.dart 2>&1 | tee build/ci/test-fin-persistence.log\n"
    + "          flutter test test/library_no_native_sources_test.dart 2>&1 | tee build/ci/test-library-source-policy.log\n"
)
if "test/library_no_native_sources_test.dart" not in build:
    build = replace_once(build, fin_test, extra_tests, "build regression tests")
build = build.replace(
    "# Validation trigger: Fin security-scoped folder sync + direct Manga Provider JSON import.",
    "# Stable validation build: Fin persistence + import-only Gallica Library policy.",
)
write(build_path, build)

for rel in (
    ".github/workflows/apply-fin-gameid-fix.yml",
    ".github/workflows/apply-fin-metadata-fast.yml",
    ".github/workflows/apply-fin-metadata-integration.yml",
    ".github/workflows/apply-fin-persistence-fix.yml",
    ".github/workflows/apply-legal-library-downloads.yml",
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
    "cleanup-library-error.log",
):
    (ROOT / rel).unlink(missing_ok=True)

# This one-shot cleanup machinery deletes itself in the resulting source commit.
(ROOT / ".github/workflows/cleanup-library-native-sources.yml").unlink(missing_ok=True)
Path(__file__).unlink(missing_ok=True)

print("Gallica is now import-only; compatibility retained and repository cleanup prepared.")
