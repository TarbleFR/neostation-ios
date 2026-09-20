import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ARMSX2 in-game UI follows the 12 NeoStation locales', () {
    final locale = File(
      'packages/armsx2_internal_bridge/ios/Classes/ARMSX2InGameLocalization.mm',
    ).readAsStringSync();
    final menu = File(
      'packages/armsx2_internal_bridge/ios/Classes/Armsx2SessionMenu.mm',
    ).readAsStringSync();
    final ra = File(
      'packages/armsx2_internal_bridge/ios/Classes/Armsx2RetroAchievementsMenu.mm',
    ).readAsStringSync();
    final native = File(
      'packages/armsx2_internal_bridge/ios/Classes/Armsx2InternalBridgePlugin.mm',
    ).readAsStringSync();
    final bridge = File(
      'packages/armsx2_internal_bridge/lib/armsx2_internal_bridge.dart',
    ).readAsStringSync();
    final launcher = File(
      'lib/services/game/game_launch_service.dart',
    ).readAsStringSync();

    for (final key in <String>[
      'de', 'es', 'pt', 'ru', 'zh', 'zh_Hant',
      'fr', 'it', 'id', 'ja', 'ko',
    ]) {
      expect(locale, contains('@"$key": @{'));
    }
    // English is the stable source-key table/fallback and is therefore the
    // twelfth locale even though it does not duplicate every source string.
    expect(locale, contains('return english ?: @""'));

    for (final label in <String>[
      'Graphics',
      'Compatibility / Cheats',
      'Controls',
      'Save State',
      'Load State',
      'Internal Resolution',
      'Screen Format',
      'Graphics Hacks',
      'Automatic',
      'Touch Controls',
      'Account',
      'Leaderboard notifications',
      'Manual graphics hacks',
      'GPU palette conversion',
      'CPU framebuffer conversion',
      'Disable depth emulation',
    ]) {
      expect(locale, contains('@"$label"'));
    }

    expect(menu, contains('ARMSX2LocalizedText'));
    expect(ra, contains('ARMSX2LocalizedText'));
    expect(native, contains('ARMSX2CanonicalLocale(args[@"uiLocale"])'));
    expect(bridge, contains("'uiLocale': uiLocale"));
    expect(
      launcher,
      contains('uiLocale: Localizations.localeOf(context).toLanguageTag()'),
    );

    // Native menus must track NeoStation's explicit locale, not iOS language.
    expect(menu, isNot(contains('NSLocale.preferredLanguages')));
    expect(ra, isNot(contains('NSLocale.preferredLanguages')));
    expect(native, isNot(contains('NSLocale.preferredLanguages')));
  });
}
