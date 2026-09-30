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
    "swapAllocated", "swapDonor", "swapReserved", "swapUnavailable", "swapClientUnavailable",
    "swapDisabled", "swapWaiting", "swapSmall", "swapRejected", "swapReleased",
    "swapActive",
)
LOCALES = {"en", "es", "ru", "zh", "zh_Hant", "pt", "fr", "de", "it", "id", "ja", "ko"}
ENGLISH = (
    "Allocated", "Donor", "Virtual reserve", "Reservation unavailable", "Core telemetry unavailable",
    "Client disabled", "No eligible allocation yet", "Only small buffers so far",
    "Last allocation rejected", "Temporary buffers released", "Buffers in use",
)
FRENCH = (
    "Alloué", "Donneur", "Réserve virtuelle", "Réserve indisponible", "Diagnostic cœur indisponible",
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
        assert set(KEYS) <= values.keys(), (locale, set(KEYS) - values.keys())
        selected = {key: values[key] for key in KEYS}
        for key, value in selected.items():
            assert value.strip() and value != key, (locale, key)
            # These short status labels introduce no interpolation parameters.
            assert not re.findall(r"\{\w+\}|%(?:\d+\$)?[-+.#\d]*[a-zA-Z@]", value), (locale, key)
        catalogues[locale] = selected
    assert tuple(catalogues["en"].values()) == ENGLISH
    assert tuple(catalogues["fr"].values()) == FRENCH
    overlay = (CLASSES / "RPCS3PerformanceOverlay.mm").read_text()
    used = set(re.findall(r'@"(swap[A-Z]\w*)"', overlay))
    assert used == set(KEYS), (used - set(KEYS), set(KEYS) - used)
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
  Check(checks == 132, @"All twelve catalogues were exercised");
  std::puts("PASS: production Foundation lookup executes 132 NeoSwap translations plus traditional Chinese variants and locale fallback; no iPhone runtime claim");
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


if __name__ == "__main__":
    values = catalogues()
    print("PASS: all 11 shipped NeoSwap overlay keys have explicit values in 12 catalogues; English/French contract and placeholders verified", flush=True)
    if sys.platform == "darwin":
        execute_native_lookup(values)
    else:
        print("NOT EXECUTED: production Foundation lookup requires macOS; source coverage only on this host")
