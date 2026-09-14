import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/themes/app_themes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all fourteen built-in palettes remain available', () {
    const names = <String>[
      'dark', 'light', 'oled', 'valentine', 'dracula', 'nord', 'coffee',
      'tokyo_night', 'retro', 'abyss', 'cyberpunk', 'aqua', 'palenight', 'horizon',
    ];
    expect(ThemeProvider.availableThemes.keys, orderedEquals(names));
    for (final name in names) {
      expect(ThemeProvider.availableThemes[name], isNotNull);
      expect(ThemeProvider.themeDisplayNames[name], isNotEmpty);
    }
    expect(ThemeProvider.availableThemes['dark'], same(AppThemes.darkTheme));
    expect(ThemeProvider.availableThemes['light'], same(AppThemes.lightTheme));
  });
}
