#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
L10N = ROOT / "lib" / "l10n"
LOCALES = ("en","fr","de","es","it","pt","ru","id","ja","ko","zh","zh_Hant")

def require(ok, message):
    if not ok:
        raise SystemExit(message)

def app_keys(path):
    return set(re.findall(r"AppLocale\.(\w+)\s*:", path.read_text(encoding="utf-8")))

def require_locales(path):
    text = path.read_text(encoding="utf-8")
    missing = [x for x in LOCALES if not re.search(r"['\"]" + re.escape(x) + r"['\"]\s*:", text)]
    require(not missing, str(path.relative_to(ROOT)) + " missing locales: " + ",".join(missing))

def main():
    files = {p.stem.replace("app_locale_",""): p for p in L10N.glob("app_locale_*.dart")}
    require(set(files) == set(LOCALES), "unexpected AppLocale files: " + str(sorted(files)))
    expected = app_keys(files["en"])
    require(len(expected) >= 900, "English AppLocale unexpectedly small")
    for locale, path in files.items():
        keys = app_keys(path)
        require(keys == expected, locale + " AppLocale key mismatch")

    for name in (
        "rpcs3_ui_locale.dart","armsx2_ui_locale.dart","library_feature_locale.dart",
        "secondary_ui_locale.dart","ios_roms_help_locale.dart","ra_ui_locale.dart",
        "dolphin_import_locale.dart"
    ):
        require_locales(L10N / name)

    dolphin = (L10N / "dolphin_extended_locale.dart").read_text(encoding="utf-8")
    for locale in LOCALES:
        require("'" + locale + "':" in dolphin, "Dolphin extension missing " + locale)
    for key in ("recording","recordingHelp","hacks","hacksHelp","achievementsHelp","deleteGames","launchFailed"):
        require(key in dolphin, "Dolphin extension missing " + key)

    arms = (ROOT / "packages/armsx2_internal_bridge/ios/Classes/ARMSX2InGameLocalization.mm").read_text(encoding="utf-8")
    for locale in LOCALES[1:]:
        require('@\"' + locale + '\": @{' in arms, "ARMSX2 native missing " + locale)
    for phrase in (
        "%@ unlabelled commands","Loading…","Open to scan patches and imported cheats",
        "The patch catalogue could not be read. Reopen this menu to retry.",
        "Named entries can be selected individually."
    ):
        require(phrase in arms, "ARMSX2 missing: " + phrase)

    rpcs3 = (ROOT / "packages/rpcs3_internal_bridge/ios/Classes/RPCS3InGameLocalization.mm").read_text(encoding="utf-8")
    for locale in LOCALES:
        require('@\"' + locale + '\": @{' in rpcs3, "RPCS3 native missing " + locale)

    offenders = []
    patterns = [
        re.compile(r"languageCode\s*==\s*['\"]fr['\"]"),
        re.compile(r"bool\s+get\s+_fr\b"),
        re.compile(r"\bfinal\s+fr\s*="),
    ]
    for path in (ROOT / "lib").rglob("*.dart"):
        if "l10n" in path.parts:
            continue
        text = path.read_text(encoding="utf-8")
        if any(p.search(text) for p in patterns):
            offenders.append(str(path.relative_to(ROOT)))
    require(not offenders, "FR/EN-only UI remains: " + ",".join(offenders))

    forbidden = {
        "Add your ROMs": ROOT / "lib/screens",
        "OPEN SETTINGS": ROOT / "lib/screens",
        "PLAY TIME": ROOT / "lib/screens",
        "Select Background Media": ROOT / "lib/widgets",
        "Select Logo Image": ROOT / "lib/widgets",
        "JIT activé": ROOT / "lib/widgets",
    }
    for phrase, base in forbidden.items():
        hits = [str(p.relative_to(ROOT)) for p in base.rglob("*.dart") if phrase in p.read_text(encoding="utf-8")]
        require(not hits, "hard-coded visible text remains: " + phrase + " " + str(hits))

    print("PASS: 12 locales, %d AppLocale keys" % len(expected))

if __name__ == "__main__":
    main()
