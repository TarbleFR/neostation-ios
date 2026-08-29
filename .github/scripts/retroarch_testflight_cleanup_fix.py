from pathlib import Path

p = Path('lib/services/retroarch_library_service.dart')
s = p.read_text(encoding='utf-8')

# The old generic cache was shared by TestFlight and App Store-era builds. It
# must now be treated exactly like every removed App Store preference.
if "    _legacyPrefsKey,\n" not in s:
    marker = "  static const List<String> _removedAppStorePreferenceKeys = <String>[\n"
    if marker not in s:
        raise SystemExit('RetroArch removal-list marker not found')
    s = s.replace(marker, marker + "    _legacyPrefsKey,\n", 1)

# The current TestFlight cache is the only accepted launch index. Never migrate
# the old generic cache back into the TestFlight namespace.
s = s.replace(
    "      final raw = prefs.getString(_prefsKey) ?? prefs.getString(_legacyPrefsKey);",
    "      final raw = prefs.getString(_prefsKey);",
)
s = s.replace(
    "      final raw =\n          prefs.getString(_prefsKey) ?? prefs.getString(_legacyPrefsKey);",
    "      final raw = prefs.getString(_prefsKey);",
)

# Keep cleanup idempotent if an older branch revision still had a one-shot guard.
s = s.replace("  static bool _legacyAppStoreStateCleaned = false;\n", "")
s = s.replace(
    "    if (_legacyAppStoreStateCleaned) return;\n    _legacyAppStoreStateCleaned = true;\n",
    "",
)

if "prefs.getString(_legacyPrefsKey)" in s:
    raise SystemExit('Legacy RetroArch cache is still read by TestFlight service')
if "_legacyAppStoreStateCleaned" in s:
    raise SystemExit('One-shot App Store cleanup guard is still present')
if "    _legacyPrefsKey,\n" not in s:
    raise SystemExit('Legacy RetroArch cache key is not in removal list')

p.write_text(s, encoding='utf-8')
