#!/usr/bin/env python3
"""Guard the removed importer and the retained theme/background/music surfaces."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def main() -> None:
    retired = ('lib/services/custom_theme_service.dart', 'lib/themes/custom_theme.dart')
    for name in retired:
        assert not (ROOT / name).exists(), name
    obsolete = re.compile(r'\b(?:ImportThemeCard|CustomThemeService|ThemeImportResult|isCustomTheme|customThemes|importTheme(?:Success|Exists|Error)?|deleteTheme(?:Title|Confirm)?)\b')
    for file in (ROOT / 'lib').rglob('*.dart'):
        assert not obsolete.search(file.read_text()), str(file)
    screen = (ROOT / 'lib/screens/settings_screen/new_settings_options/themes_settings_content.dart').read_text()
    provider = (ROOT / 'lib/providers/theme_provider.dart').read_text()
    assert 'getThemeList().length + 3' in screen
    assert 'final itemCount = allThemes.length + 2;' in screen
    assert 'if (index < 0 || index >= getItemCount(context)) return;' in screen
    for token in ('_CustomBackgroundCard(', '_HomeMusicCard(', '_pickCustomBackground()', '_pickHomeMusic()', 'HomeMusicService'):
        assert token in screen, token
    assert 'falling back to system' in provider
    assert 'resolvePersistedCustomBackgroundForTesting' in provider
    assert len(re.findall(r"^    '[^']+': AppThemes\.", provider, re.M)) == 14
    assert '## System Art' in (ROOT / 'THEMES.md').read_text()
    main_dart = (ROOT / 'lib/main.dart').read_text()
    assert "['full_themes', 'custom_themes']" in main_dart
    assert 'followLinks: false' in main_dart
    print('Theme importer removal and retained features: OK')

if __name__ == '__main__':
    main()
