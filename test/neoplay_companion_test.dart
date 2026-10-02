import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/neoplay_companion_locale.dart';
import 'package:neostation/widgets/neoplay_apple_tv_card.dart';
import 'package:neostation/widgets/neoplay_game_hud_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('All companion translations preserve keys and substitution parameters', () {
    final all = NeoPlayCompanionLocale.values;
    expect(all.keys.toSet(), {'en','es','ru','zh','zh_Hant','pt','fr','de','it','id','ja','ko'});
    final placeholders = RegExp(r'\{[a-z]+\}');
    for (final locale in all.entries) {
      expect(locale.value.keys.toSet(),all['en']!.keys.toSet());
      for (final entry in locale.value.entries) {
        expect(entry.value,isNotEmpty);
        expect(placeholders.allMatches(entry.value).map((m) => m[0]).toSet(),placeholders.allMatches(all['en']![entry.key]!).map((m) => m[0]).toSet(), reason:'${locale.key}:${entry.key}');
      }
    }
    for (final locale in [const Locale('zh','TW'),const Locale.fromSubtags(languageCode:'zh',scriptCode:'Hant')]) {
      expect(NeoPlayCompanionLocale.forLocale(locale),same(all['zh_Hant']));
    }
  });
  testWidgets('Game battery UI is independent of streaming and follows launch/exit without capture calls', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final active = ValueNotifier(false), calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('neostation/neoplay'),(call) async { calls.add(call); return null; });
    addTearDown(() { messenger.setMockMethodCallHandler(const MethodChannel('neostation/neoplay'),null); active.dispose(); });
    await tester.pumpWidget(MaterialApp(home:NeoPlayGameHUDHost(stateSource:active,isGameActive:() => active.value,child:const SizedBox())));
    await tester.pumpAndSettle(); active.value = true; await tester.pumpAndSettle();
    active.value = false; await tester.pumpAndSettle();
    expect(calls.map((c) => c.method).toSet(),{'configureGameHUD'});
    expect(calls.map((c) => (c.arguments as Map)['active']).toList(),[false,true,false]);
    expect((calls[1].arguments as Map)['labels']['unavailable'],isNotEmpty);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    expect((calls.last.arguments as Map)['active'],false);
  });
  testWidgets('Apple TV entry explains system selection and never mistakes audio for game video', (tester) async {
    await tester.pumpWidget(const MaterialApp(home:Scaffold(body:NeoPlayAppleTVCard(facts:{'status':'audioOnly'},streamBusy:true))));
    expect(find.text(NeoPlayCompanionLocale.values['en']!['audioOnly']!),findsOneWidget);
    await tester.tap(find.byKey(const Key('neoplay-apple-tv-system-entry'))); await tester.pumpAndSettle();
    expect(find.text(NeoPlayCompanionLocale.values['en']!['appleTVSystem']!),findsOneWidget);
    expect(find.text(NeoPlayCompanionLocale.values['en']!['busyAppleTV']!),findsOneWidget);
    expect(find.text(NeoPlayCompanionLocale.values['en']!['appleTVBody']!),findsOneWidget);
    expect(find.byType(AndroidView),findsNothing);
    expect(tester.takeException(),isNull);
  });
}
