import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/l10n/dusklight_locale.dart';

void main() {
  final placeholders = RegExp(r'\{\w+\}');
  final english = DusklightLocale.values['en']!;

  test('Dusklight covers exactly the twelve NeoStation languages', () {
    expect(DusklightLocale.values.keys.toSet(),
        AppLocale.supportedLanguages.keys.toSet());
    expect(DusklightLocale.emptyLibrary.keys.toSet(),
        AppLocale.supportedLanguages.keys.toSet());
  });

  for (final entry in DusklightLocale.values.entries) {
    test('${entry.key}: no missing messages, placeholders or English fallbacks', () {
      expect(entry.value.keys.toSet(), english.keys.toSet());
      for (final message in english.entries) {
        final translated = entry.value[message.key]!;
        expect(translated.trim(), isNotEmpty);
        expect(placeholders.allMatches(translated).map((m) => m[0]).toSet(),
            placeholders.allMatches(message.value).map((m) => m[0]).toSet());
        if (entry.key != 'en') {
          expect(translated, isNot(message.value), reason: message.key);
        }
      }
      final locale = entry.key == 'zh_Hant'
          ? const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')
          : Locale(entry.key);
      for (final error in DusklightLocale.launchErrorKeys.entries) {
        expect(DusklightLocale.launchError(locale, error.key),
            entry.value[error.value]);
      }
      final imported = DusklightLocale.forLocale(locale, 'imported', count: 3);
      expect(imported, contains('3'));
      expect(imported, isNot(contains('{count}')));
    });
  }

  test('script and regional Chinese settings select the correct translation', () {
    for (final locale in <Locale>[
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      const Locale('zh', 'TW'), const Locale('zh', 'HK'), const Locale('zh', 'MO'),
    ]) {
      expect(DusklightLocale.forLocale(locale, 'coreMissing'),
          DusklightLocale.values['zh_Hant']!['coreMissing']);
    }
    expect(DusklightLocale.forLocale(const Locale('zh', 'CN'), 'coreMissing'),
        DusklightLocale.values['zh']!['coreMissing']);
  });

  test('unknown native errors stay localized without claiming the Core is absent', () {
    expect(DusklightLocale.launchError(const Locale('fr'), 'UNRECOGNIZED'),
        DusklightLocale.values['fr']!['launchFailed']);
    expect(DusklightLocale.launchError(const Locale('fr'), 'DUSKLIGHT_CORE_LOAD_FAILED'),
        isNot(DusklightLocale.launchError(const Locale('fr'), 'DUSKLIGHT_CORE_NOT_READY')));
  });

  test('all native launch errors have a translation and raw detail stays separate', () {
    final native = File('packages/dusklight_internal_bridge/ios/Classes/DusklightInternalBridgePlugin.mm')
        .readAsStringSync();
    for (final match in RegExp(r'@"(DUSKLIGHT_[A-Z_]+)"').allMatches(native)) {
      expect(DusklightLocale.launchErrorKeys, contains(match[1]));
    }
    final router = File('lib/services/game/game_launch_service.dart').readAsStringSync();
    final start = router.indexOf("system.folderName.toLowerCase() == 'ports'");
    final end = router.indexOf('if (Platform.isIOS) {', start);
    final ports = router.substring(start, end);
    expect(ports, contains('DusklightLocale.launchError(locale, report.errorCode)'));
    expect(ports, contains(r'${report.technicalDetails}\n${report.message}'));
    final widget = File('lib/widgets/dusklight_internal_playlist_actions.dart').readAsStringSync();
    expect(widget, isNot(contains('bool get _fr')));
  });
}
