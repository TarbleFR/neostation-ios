import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/neoswap_locale.dart';

void main() {
  test('all 12 NeoSwap catalogues match canonical data and placeholders', () {
    final source =
        jsonDecode(File('native/neoswap/localizations.json').readAsStringSync())
            as Map;
    final values = NeoSwapLocale.values;
    expect(values.keys.toSet(), {
      'en',
      'fr',
      'es',
      'de',
      'it',
      'pt',
      'ru',
      'id',
      'ja',
      'ko',
      'zh',
      'zh_Hant',
    });
    expect(values, source);
    final pattern = RegExp(r'\{\w+\}');
    for (final catalogue in values.values) {
      expect(catalogue.keys.toSet(), values['en']!.keys.toSet());
      for (final entry in catalogue.entries) {
        expect(entry.value.trim(), isNotEmpty);
        expect(
          pattern.allMatches(entry.value).map((m) => m[0]).toSet(),
          pattern
              .allMatches(values['en']![entry.key]!)
              .map((m) => m[0])
              .toSet(),
        );
      }
    }
    for (final locale in [
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      const Locale('zh', 'TW'),
      const Locale('zh', 'HK'),
      const Locale('zh', 'MO'),
    ]) {
      expect(NeoSwapLocale.localeKey(locale), 'zh_Hant');
    }
    expect(NeoSwapLocale.localeKey(const Locale('zh', 'CN')), 'zh');
  });
}
