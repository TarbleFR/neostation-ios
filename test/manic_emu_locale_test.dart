import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/manic_emu_locale.dart';

void main() {
  test('every Manic EMU string is translated in all 12 languages', () {
    expect(ManicEmuLocale.supportedLocaleKeys, hasLength(12));

    for (final locale in ManicEmuLocale.supportedLocaleKeys) {
      for (final key in ManicEmuLocale.translationKeys) {
        final value = ManicEmuLocale.textForLocale(locale, key);
        expect(value.trim(), isNotEmpty, reason: '$locale is missing $key');
        expect(value, isNot(key), reason: '$locale is missing $key');
      }
    }
  });
}
