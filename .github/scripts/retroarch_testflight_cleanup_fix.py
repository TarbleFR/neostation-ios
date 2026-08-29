from pathlib import Path

p = Path('lib/services/retroarch_library_service.dart')
s = p.read_text(encoding='utf-8')

# Purging removed App Store/generic keys is cheap and must be idempotent. Do it
# every time the TestFlight service is loaded so an older preference cannot
# survive merely because another call already ran migration in this process.
s = s.replace("  static bool _legacyAppStoreStateCleaned = false;\n", "")
s = s.replace(
    "    if (_legacyAppStoreStateCleaned) return;\n    _legacyAppStoreStateCleaned = true;\n",
    "",
)

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

if "prefs.getString(_legacyPrefsKey)" in s:
    raise SystemExit('Legacy RetroArch cache is still read by TestFlight service')
if "_legacyAppStoreStateCleaned" in s:
    raise SystemExit('One-shot App Store cleanup guard is still present')
if "_legacyPrefsKey," not in s:
    raise SystemExit('Legacy RetroArch cache key is not in removal list')

p.write_text(s, encoding='utf-8')
