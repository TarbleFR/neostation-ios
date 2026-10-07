#!/usr/bin/env python3
"""Cover native NeoSwap overlay strings and execute production lookup on macOS."""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLASSES = ROOT / "packages/rpcs3_internal_bridge/ios/Classes"
SOURCE = CLASSES / "RPCS3InGameLocalization.mm"
KEYS = (
    "swapAllocated", "swapDonor", "swapTarget", "swapResident", "swapCompressed", "swapDonors",
    "swapUnavailable", "swapClientUnavailable",
    "swapDisabled", "swapWaiting", "swapSmall", "swapRejected", "swapReleased",
    "swapActive",
)
MEMORY_KEYS = ("memoryDevice", "memoryUnitGB", "memoryNeoSwap")
LOCALES = {"en", "es", "ru", "zh", "zh_Hant", "pt", "fr", "de", "it", "id", "ja", "ko"}
ENGLISH = (
    "RPCS3", "Shared", "Target", "Resident", "Compressed", "Donors",
    "Allocator unavailable", "Core telemetry unavailable",
    "Client disabled", "No eligible allocation yet", "Only small buffers so far",
    "Last allocation rejected", "Temporary buffers released", "Buffers in use",
)
FRENCH = (
    "RPCS3", "Partagé", "Cible", "Résident", "Comprimé", "Donneurs",
    "Allocateur indisponible", "Diagnostic cœur indisponible",
    "Client désactivé", "Aucune allocation éligible", "Buffers trop petits",
    "Dernière allocation refusée", "Buffers temporaires libérés", "Buffers utilisés",
)


def literal(value: str) -> str:
    return "@" + json.dumps(value, ensure_ascii=False)


def catalogues() -> dict:
    source = SOURCE.read_text()
    # The primary catalogue, before the unchanged savestate/menu additions.
    primary = source.split("Build256Translations()", 1)[0]
    rows = re.findall(r'@"([a-zA-Z_]+)": @\{(.*?)\n      \},', primary, re.S)
    assert len(rows) == 12 and {locale for locale, _ in rows} == LOCALES
    catalogues = {}
    for locale, block in rows:
        pairs = re.findall(r'@"([^"\\]*(?:\\.[^"\\]*)*)":\s*@"([^"\\]*(?:\\.[^"\\]*)*)"', block)
        parsed = [(json.loads('"' + key + '"'), json.loads('"' + value + '"')) for key, value in pairs]
        assert len(parsed) == len(dict(parsed)), f"Duplicate localization key: {locale}"
        values = dict(parsed)
        assert 'swapReserved' not in values, f"Obsolete virtual-reserve label: {locale}"
        assert set(KEYS) <= values.keys(), (locale, set(KEYS) - values.keys())
        assert set(MEMORY_KEYS) <= values.keys(), locale
        selected = {key: values[key] for key in KEYS + MEMORY_KEYS}
        for key, value in selected.items():
            assert value.strip() and value != key, (locale, key)
            # These short status labels introduce no interpolation parameters.
            assert not re.findall(r"\{\w+\}|%(?:\d+\$)?[-+.#\d]*[a-zA-Z@]", value), (locale, key)
        catalogues[locale] = selected
    assert tuple(catalogues["en"][key] for key in KEYS) == ENGLISH
    assert tuple(catalogues["fr"][key] for key in KEYS) == FRENCH
    assert all(values['swapAllocated'] == 'RPCS3' for values in catalogues.values())
    overlay = (CLASSES / "RPCS3PerformanceOverlay.mm").read_text()
    used = set(re.findall(r'@"(swap[A-Z]\w*)"', overlay))
    # Build381 deliberately removes the verbose NeoSwap status paragraph from
    # the on-screen graph. Keep the 12-locale catalogue for compatibility, but
    # only reject unknown swap keys if any are reintroduced.
    assert used <= set(KEYS), used - set(KEYS)
    assert all('@"' + key + '"' in overlay for key in MEMORY_KEYS)
    assert catalogues['fr']['memoryUnitGB'] == 'Go'
    assert catalogues['en']['memoryUnitGB'] == 'GB'
    assert 'NeoSwapMemoryGraph(' in overlay and 'NeoSwapDecimalGB(' in overlay
    assert 'fpsLine' not in overlay and 'donor_prepared_bytes' not in overlay
    assert 'memoryUsedBytes' not in overlay
    assert 'NeoSwapFPSValid(fps, validFields)' in overlay
    assert '@"FPS %.1f"' in overlay and '@"FPS —"' in overlay
    assert 'self.ratesLabel.text, self.deviceLabel.text, self.neoswapLabel.text' in overlay
    # 7 October 2026: the microprocess line is gone; the graph draws the merged
    # device RAM (orange) and the NeoSwap contribution (green) only.
    assert 'systemCyanColor' not in overlay and 'systemOrangeColor' in overlay and 'systemGreenColor' in overlay
    assert 'memoryMicroprocess' not in overlay and 'memoryPhysical' not in overlay
    assert 'allocationLine' not in overlay and 'residentLine' not in overlay
    assert 'append(deviceLine, sample.memory.deviceRam, sample.memory.deviceRamValid, deviceStarted);' in overlay
    assert 'append(neoswapLine, sample.memory.hostLoans, sample.memory.hostLoansValid, neoswapStarted);' in overlay
    assert 'memoryMicroprocess' not in source and 'memoryPhysical' not in source
    return catalogues


def execute_native_lookup(values: dict) -> None:
    entries = []
    for locale, rows in values.items():
        pairs = ",".join(literal(key) + ":" + literal(value) for key, value in rows.items())
        entries.append(literal(locale) + ":@{" + pairs + "}")
    expected = "@{" + ",".join(entries) + "}"
    main = r'''
#import "RPCS3InGameLocalization.h"
#include <cstdio>
#include <cstdlib>
static void Check(BOOL condition, NSString* label) {
  if (!condition) { std::fprintf(stderr, "FAILED: %s\n", label.UTF8String); std::abort(); }
}
int main() { @autoreleasepool {
  NSDictionary* expected = EXPECTED_CATALOGUES;
  unsigned checks = 0;
  for (NSString* locale in expected) {
    Check([RPCS3CanonicalLocale(locale) isEqualToString:locale], locale);
    for (NSString* key in expected[locale]) {
      NSString* actual = RPCS3LocalizedString(key, locale);
      Check([actual isEqualToString:expected[locale][key]], [NSString stringWithFormat:@"%@/%@", locale, key]);
      ++checks;
    }
  }
  for (NSString* variant in @[@"zh-Hant", @"zh-Hant-TW", @"zh_TW", @"zh-HK", @"zh_MO"]) {
    Check([RPCS3CanonicalLocale(variant) isEqualToString:@"zh_Hant"], variant);
    for (NSString* key in expected[@"zh_Hant"])
      Check([RPCS3LocalizedString(key, variant) isEqualToString:expected[@"zh_Hant"][key]], variant);
  }
  Check([RPCS3CanonicalLocale(@"fr-FR") isEqualToString:@"fr"], @"French region");
  Check([RPCS3CanonicalLocale(@"zh-CN") isEqualToString:@"zh"], @"Simplified Chinese");
  Check([RPCS3CanonicalLocale(@"unsupported") isEqualToString:@"en"], @"Unknown locale");
  for (NSString* key in expected[@"en"])
    Check([RPCS3LocalizedString(key, nil) isEqualToString:expected[@"en"][key]], @"Missing locale");
  Check(checks == 204, @"All twelve catalogues were exercised");
  std::puts("PASS: production Foundation lookup executes 204 NeoSwap translations plus traditional Chinese variants and locale fallback; no iPhone runtime claim");
} return 0; }
'''.replace("EXPECTED_CATALOGUES", expected)
    with tempfile.TemporaryDirectory(prefix="rpcs3-neoswap-locales-") as temporary:
        folder = Path(temporary)
        harness = folder / "main.mm"
        harness.write_text(main)
        binary = folder / "localization-test"
        subprocess.run(["xcrun", "clang++", "-std=c++20", "-fobjc-arc", "-fblocks",
                        "-Wall", "-Wextra", "-Werror", "-I" + str(CLASSES), str(SOURCE),
                        str(harness), "-framework", "Foundation", "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
        # Compile the actual UIKit view, not just the label catalogue.
        # This catches missing Sample fields before starting the IPA build.
        (folder / "neo_swap").symlink_to(ROOT / "packages/neo_swap/ios/Classes", target_is_directory=True)
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        subprocess.run(["xcrun", "--sdk", "iphoneos", "clang++", "-std=c++20",
                        "-fobjc-arc", "-fblocks", "-fsyntax-only", "-Wall", "-Wextra", "-Werror",
                        "-arch", "arm64", "-isysroot", sdk, "-miphoneos-version-min=18.0",
                        "-I" + str(folder), "-I" + str(CLASSES),
                        str(CLASSES / "RPCS3PerformanceOverlay.mm")], check=True)


if __name__ == "__main__":
    values = catalogues()
    print("PASS: all 14 legacy NeoSwap keys remain valid in 12 catalogues; merged device-RAM and NeoSwap two-series decimal-GB graph verified", flush=True)
    if sys.platform == "darwin":
        execute_native_lookup(values)
    else:
        print("NOT EXECUTED: production Foundation lookup requires macOS; source coverage only on this host")
