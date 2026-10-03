import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/neoplay_locale.dart';
import 'package:neostation/l10n/neoplay_discovery_locale.dart';

void main() {
  test('NeoPlay has complete catalogues in all twelve supported languages', () {
    expect(NeoPlayLocale.values.keys.toSet(), {'en','es','ru','zh','zh_Hant','pt','fr','de','it','id','ja','ko'});
    final keys = NeoPlayLocale.values['en']!.keys.toSet();
    for (final locale in NeoPlayLocale.values.entries) {
      expect(locale.value.keys.toSet(), keys, reason: locale.key);
      expect(locale.value.values.every((value) => value.isNotEmpty), isTrue);
    }
  });
  test('Discovery recovery has complete catalogues and parameters in all twelve languages', () {
    expect(NeoPlayDiscoveryLocale.values.keys.toSet(), NeoPlayLocale.values.keys.toSet());
    final keys = NeoPlayDiscoveryLocale.values['en']!.keys.toSet();
    final parameters = RegExp(r'\{[^}]+\}');
    for (final locale in NeoPlayDiscoveryLocale.values.entries) {
      expect(locale.value.keys.toSet(), keys, reason: locale.key);
      for (final key in keys) {
        expect(locale.value[key]!.isNotEmpty, isTrue);
        expect(parameters.allMatches(locale.value[key]!).map((match) => match[0]).toSet(),
            parameters.allMatches(NeoPlayDiscoveryLocale.values['en']![key]!).map((match) => match[0]).toSet());
      }
    }
  });
  testWidgets('Traditional Chinese uses the Traditional catalogue', (tester) async {
    await tester.pumpWidget(Localizations(locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'), delegates: const [DefaultWidgetsLocalizations.delegate], child: Directionality(textDirection: TextDirection.ltr, child: Builder(builder: (context) => Text(NeoPlayLocale.get(context, 'subtitle'))))));
    expect(find.text('在另一個螢幕上遊玩'), findsOneWidget);
  });
  testWidgets('Discovery recovery selects Traditional Chinese', (tester) async {
    await tester.pumpWidget(Localizations(locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'), delegates: const [DefaultWidgetsLocalizations.delegate], child: Directionality(textDirection: TextDirection.ltr, child: Builder(builder: (context) => Text(NeoPlayDiscoveryLocale.get(context, 'refresh'))))));
    expect(find.text('重新搜尋'), findsOneWidget);
    expect(find.text('重新搜索'), findsNothing);
  });
}
