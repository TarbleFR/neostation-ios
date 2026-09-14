#!/usr/bin/env python3
"""Remove only the retired JSON color-theme importer from tracked sources.

Run once before committing; not a runtime/build-time feature flag. The built-in
catalog, custom background/music, System Art and all emulator code are retained.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
MARKER = 'NEOSTATION_THEME_IMPORTER_RETIRED_265'


def replace(text: str, old: str, new: str = '') -> str:
    if text.count(old) != 1:
        raise RuntimeError(f'Expected one source anchor, found {text.count(old)}: {old[:100]!r}')
    return text.replace(old, new, 1)


def between(text: str, first: str, last: str, replacement: str = '') -> str:
    start = text.index(first)
    end = text.index(last, start)
    return text[:start] + replacement + text[end:]


def main() -> None:
    provider = ROOT / 'lib/providers/theme_provider.dart'
    if MARKER in provider.read_text():
        print('Theme importer already retired')
        return
    text = provider.read_text()
    text = replace(text, "import 'package:neostation/services/custom_theme_service.dart';\n")
    text = between(text, '  Future<void> _loadCustomThemes()', '  Future<Directory> _customBackgroundDirectory()')
    text = replace(text, '      await _loadCustomThemes();\n')
    text = replace(text, "      } else if (AppThemes.customThemes.containsKey(savedThemeName)) {\n        _currentTheme = AppThemes.customThemes[savedThemeName]!.themeData;\n        _currentThemeName = savedThemeName;\n        _notifyThemeChanged();\n")
    text = replace(text, '    ThemeData? resolved = availableThemes[themeName];\n    resolved ??= AppThemes.customThemes[themeName]?.themeData;\n', '    final resolved = availableThemes[themeName];\n')
    text = text[:text.index('  List<Map<String, String>> getThemeList()')] + '''  // NEOSTATION_THEME_IMPORTER_RETIRED_265: built-ins only; unknown persisted
  // theme IDs already fall back to system in _loadSavedTheme(). Background and
  // music preferences are deliberately independent and are never reset here.
  List<Map<String, String>> getThemeList() => availableThemes.keys.map((key) {
    return {'name': key, 'displayName': themeDisplayNames[key] ?? key};
  }).toList();
}
'''
    provider.write_text(text)

    file = ROOT / 'lib/themes/app_themes.dart'
    text = replace(file.read_text(), "import 'package:neostation/themes/custom_theme.dart';\n")
    text = between(text, '  /// Registry of user-imported themes', '  static String getLogoPath()')
    text = replace(text, '''      final custom = customThemes[resolvedThemeName];
      if (custom != null) {
        return custom.customColors;
      }

''')
    text = replace(text, '''    final custom = customThemes[themeName];
    if (custom != null) {
      return custom.themeData;
    }

''')
    file.write_text(text)

    file = ROOT / 'lib/screens/settings_screen/new_settings_options/themes_settings_content.dart'
    text = file.read_text()
    text = re.sub(r"^import '[^']*confirm_action_dialog.dart';\n", '', text, flags=re.M)
    text = text.replace('themeProvider.getThemeList().length + 4', 'themeProvider.getThemeList().length + 3')
    text = replace(text, '  void selectItem(int index) async {\n', '  void selectItem(int index) async {\n    if (index < 0 || index >= getItemCount(context)) return;\n')
    text = replace(text, '    final importIndex = themes.length + 3;\n')
    text = replace(text, '''    } else if (index == importIndex) {
      await _importTheme();
      return;
''')
    text = between(text, '  /// Opens a file picker, imports the selected daisyUI', '  void deleteFocusedTheme', '  /// Gamepad entry point: clears only the custom background or menu music.\n')
    text = between(text, '    final themeIndex = index - 1;', '  @override\n  Widget build', '  }\n\n')
    text = replace(text, '    final importIndex = allThemes.length + 2;\n')
    text = replace(text, '    final itemCount = allThemes.length + 3;', '    final itemCount = allThemes.length + 2;')
    text = between(text, '              if (index == importIndex) {', '              final t = allThemes[index];')
    text = replace(text, "              final isCustom = themeProvider.isCustomTheme(t['name']!);\n")
    text = replace(text, '''                  onLongPress: isCustom
                      ? () => _deleteTheme(t['name']!, t['displayName']!)
                      : null,
                  onDelete: isCustom
                      ? () => _deleteTheme(t['name']!, t['displayName']!)
                      : null,
''')
    file.write_text(text)

    file = ROOT / 'lib/widgets/theme_card.dart'
    text = file.read_text()
    # The importer is the final class. Keep the complete built-in preview painter.
    text = text[:text.index('class ImportThemeCard')].rstrip() + '\n'
    text = replace(text, '    this.onLongPress,\n    this.onDelete,\n')
    text = between(text, '  /// Optional long-press handler', '  final bool isSelected;')
    text = replace(text, '                        onLongPress: widget.onLongPress,\n')
    text = between(text, '                  // Delete badge for imported themes', '                ],\n              ),')
    # Remove the importer doc comment which used to precede the final class.
    text = re.sub(r'\n(?:///[^^\n]*\n)+\Z', '\n', text)
    file.write_text(text.rstrip() + '\n')

    keys = r'(?:importTheme(?:Success|Exists|Error)?|deleteTheme(?:Title|Confirm))'
    for file in (ROOT / 'lib/l10n').glob('app_locale*.dart'):
        text = file.read_text()
        if file.name == 'app_locale.dart':
            text, count = re.subn(r'^  static const String ' + keys + r" = '[^']+';\n", '', text, flags=re.M)
        else:
            # Values may span two lines; stop at the next locale entry.
            text, count = re.subn(r'^  AppLocale\.' + keys + r':[^\n]*(?:\n(?!  AppLocale\.)[^\n]*)*\n(?=  AppLocale\.)', '', text, flags=re.M)
        if count != 6:
            raise RuntimeError(f'{file.name}: expected exactly six obsolete locale entries, found {count}')
        file.write_text(text)

    file = ROOT / 'lib/main.dart'
    text = file.read_text()
    text = replace(text, "  const directoryName = 'full_themes';", "  const directoryNames = ['full_themes', 'custom_themes'];")
    text = replace(text, '''    final retiredDirectory = Directory(path.join(dataPath, directoryName));
    if (await retiredDirectory.exists()) {
      await retiredDirectory.delete(recursive: true);
    }
''', '''    for (final directoryName in directoryNames) {
      final retiredDirectory = Directory(path.join(dataPath, directoryName));
      // Never follow a link into other user data during an upgrade cleanup.
      final type = await FileSystemEntity.type(retiredDirectory.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        await retiredDirectory.delete(recursive: true);
      } else if (type == FileSystemEntityType.link) {
        await Link(retiredDirectory.path).delete();
      }
    }
''')
    file.write_text(text)

    file = ROOT / 'THEMES.md'
    text = between(file.read_text(), '## Imported custom UI themes', '## System Art')
    file.write_text(text)
    for name in ('lib/services/custom_theme_service.dart', 'lib/themes/custom_theme.dart', 'test/custom_theme_test.dart'):
        (ROOT / name).unlink()
    print('Theme importer retired; built-ins/background/music/System Art preserved')


if __name__ == '__main__':
    main()
