import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/neoplay_locale.dart';

void main() {
  test('NeoPlay has complete catalogues in all twelve supported languages', () {
    expect(NeoPlayLocale.values.keys.toSet(), {'en','es','ru','zh','zh_Hant','pt','fr','de','it','id','ja','ko'});
    final keys = NeoPlayLocale.values['en']!.keys.toSet();
    for (final locale in NeoPlayLocale.values.entries) {
      expect(locale.value.keys.toSet(), keys, reason: locale.key);
      expect(locale.value.values.every((value) => value.isNotEmpty), isTrue);
    }
  });
  testWidgets('Traditional Chinese uses the Traditional catalogue', (tester) async {
    await tester.pumpWidget(Localizations(locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'), delegates: const [DefaultWidgetsLocalizations.delegate], child: Directionality(textDirection: TextDirection.ltr, child: Builder(builder: (context) => Text(NeoPlayLocale.get(context, 'subtitle'))))));
    expect(find.text('在另一個螢幕上遊玩'), findsOneWidget);
  });
}
