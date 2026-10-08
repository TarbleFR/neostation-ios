import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

void main() {
  test('sync outcomes are translated in all twelve catalogs without lost parameters', () {
    final catalogs = [
      AppLocale.en,
      AppLocale.es,
      AppLocale.ru,
      AppLocale.zh,
      AppLocale.zhHant,
      AppLocale.pt,
      AppLocale.fr,
      AppLocale.de,
      AppLocale.it,
      AppLocale.id,
      AppLocale.ja,
      AppLocale.ko,
    ];
    for (final key in [
      AppLocale.iosRetroarchSyncing,
      AppLocale.iosRetroarchSyncTimedOut,
      AppLocale.iosRetroarchSyncEmpty,
      AppLocale.iosRetroarchSyncInvalid,
    ]) {
      for (final catalog in catalogs) {
        expect(catalog[key], isNotEmpty, reason: key);
        expect(
          RegExp(r'\{[^}]+\}')
              .allMatches(catalog[key] as String)
              .map((m) => m.group(0))
              .toSet(),
          RegExp(r'\{[^}]+\}')
              .allMatches(AppLocale.en[key] as String)
              .map((m) => m.group(0))
              .toSet(),
        );
      }
    }
    expect(AppLocale.zhHant[AppLocale.iosRetroarchSyncEmpty], contains('遊戲'));
    expect(AppLocale.zh[AppLocale.iosRetroarchSyncEmpty], contains('游戏'));
  });
}
