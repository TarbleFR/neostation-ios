import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/dolphin_import_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/game_details_tabs_header.dart';

void main() {
  // Layout/gesture coverage does not require a native audio engine in unit tests.
  setUp(() => SfxService().setEnabled(false));
  tearDown(() => SfxService().setEnabled(true));
  test('all twelve languages cover import, in-game menu and placeholder parameters', () {
    final values = DolphinImportLocale.values;
    expect(values.keys.toSet(), {'en', 'es', 'pt', 'ru', 'zh', 'zh_Hant', 'fr', 'de', 'it', 'id', 'ja', 'ko'});
    for (final locale in values.entries) {
      expect(locale.value.keys.toSet(), values['en']!.keys.toSet(), reason: locale.key);
      for (final entry in locale.value.entries) {
        expect(entry.value.trim(), isNotEmpty, reason: '${locale.key}/${entry.key}');
        final placeholders = RegExp(r'\{\w+\}');
        expect(placeholders.allMatches(entry.value).map((m) => m.group(0)).toSet(),
            placeholders.allMatches(values['en']![entry.key]!).map((m) => m.group(0)).toSet());
      }
    }
    expect(DolphinImportLocale.labelsFor(const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'))['resume'], '繼續遊戲');
    expect(DolphinImportLocale.labelsFor(const Locale('zh', 'TW'))['resume'], '繼續遊戲');
  });

  for (final width in [430.0, 220.0]) {
    testWidgets('import shares the pill without covering any media tab at width $width', (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      DetailTab selected = DetailTab.wheel;
      await tester.pumpWidget(ScreenUtilInit(
        designSize: const Size(844, 390),
        builder: (context, child) => MaterialApp(home: Scaffold(body: Align(
          alignment: Alignment.topRight,
          child: SizedBox(width: width, child: GameDetailsTabsHeader(
            isScreenshotVideoHidden: false,
            hasRetroAchievements: true,
            currentTab: selected,
            onTabChanged: (tab) => selected = tab,
            trailingAction: const Icon(Icons.file_upload_outlined),
          )),
        ))),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final importRect = tester.getRect(find.byIcon(Icons.file_upload_outlined));
      for (final icon in [Symbols.gamepad_rounded, Symbols.widgets_rounded, Symbols.image_rounded,
                         Symbols.description_rounded, Symbols.emoji_events_rounded]) {
        final finder = find.byIcon(icon);
        expect(finder, findsOneWidget);
        expect(tester.getRect(finder).overlaps(importRect), isFalse);
        expect(tester.getRect(finder).right, lessThan(importRect.left));
      }
      await tester.tap(find.byIcon(Symbols.emoji_events_rounded));
      expect(selected, DetailTab.achievements);
      await tester.tap(find.byIcon(Symbols.image_rounded));
      expect(selected, DetailTab.screenshotVideo);
    });
  }
}
