import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PS3 system and game settings identify embedded RPCS3', () {
    final gameTab = File(
      'lib/screens/game_screen/game_settings_dialog/'
      'game_settings_emulator_tab.dart',
    ).readAsStringSync();
    final systemDialog = File(
      'lib/widgets/system_emulator_settings_dialog/tabs.dart',
    ).readAsStringSync();

    for (final source in <String>[gameTab, systemDialog]) {
      expect(source, contains("const Text('RPCS3')"));
      expect(source, contains('EmbeddedEmulatorLocale.integrated(context)'));
    }
    expect(gameTab, contains("'ps3'"));
    expect(systemDialog, contains("folderName.toLowerCase() == 'ps3'"));
  });

  test('embedded status is translated in all NeoStation locales', () {
    final source = File(
      'lib/l10n/embedded_emulator_locale.dart',
    ).readAsStringSync();
    for (final locale in <String>[
      'en',
      'fr',
      'de',
      'es',
      'it',
      'pt',
      'ru',
      'id',
      'ja',
      'ko',
      'zh',
      'zh_Hant',
    ]) {
      expect(source, contains("'$locale':"), reason: locale);
    }
  });
}
