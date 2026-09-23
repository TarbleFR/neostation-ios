import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('embedded iOS systems expose one truthful in-process engine identity', () {
    final gameTab = File(
      'lib/screens/game_screen/game_settings_dialog/'
      'game_settings_emulator_tab.dart',
    ).readAsStringSync();
    final systemDialog = File(
      'lib/widgets/system_emulator_settings_dialog/tabs.dart',
    ).readAsStringSync();

    final dialog = File(
      'lib/widgets/system_emulator_settings_dialog.dart',
    ).readAsStringSync();

    for (final source in <String>[gameTab, systemDialog]) {
      expect(source, contains('EmbeddedEmulatorLocale.integrated(context)'));
      expect(source, contains('embeddedEngine'));
    }
    for (final engine in <String>[
      'DolphiniOS',
      'ARMSX2',
      'RPCS3',
      'Dusklight',
    ]) {
      expect(gameTab + dialog, contains("'$engine'"), reason: engine);
    }
    for (final folder in <String>['gc', 'wii', 'ps2', 'ps3', 'ports']) {
      expect(gameTab + dialog, contains("'$folder'"), reason: folder);
    }
    expect(systemDialog, isNot(contains("folderName.toLowerCase() == 'ps3'")));
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
