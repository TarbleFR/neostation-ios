import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/library_visibility_locale.dart';
import 'package:neostation/l10n/retroarch_locale.dart';

void main() {
  test('RetroArch native catalogue matches all 12 Flutter locales', () {
    final native = jsonDecode(
      File('native/retroarch/localizations.json').readAsStringSync(),
    );
    expect(RetroArchLocale.values, native);
    const expectedLocales = {
      'en',
      'es',
      'ru',
      'zh',
      'zh_Hant',
      'pt',
      'fr',
      'de',
      'it',
      'id',
      'ja',
      'ko',
    };
    final placeholder = RegExp(r'\{\w+\}');
    for (final catalogues in [
      RetroArchLocale.values,
      LibraryVisibilityLocale.values,
    ]) {
      expect(catalogues.keys.toSet(), expectedLocales);
      final english = catalogues['en']!;
      for (final catalogue in catalogues.values) {
        expect(catalogue.keys.toSet(), english.keys.toSet());
        for (final entry in catalogue.entries) {
          expect(entry.value.trim(), isNotEmpty);
          expect(
            placeholder.allMatches(entry.value).map((m) => m[0]).toList()
              ..sort(),
            placeholder
                .allMatches(english[entry.key]!)
                .map((m) => m[0])
                .toList()
              ..sort(),
          );
        }
      }
    }
  });

  test('Chinese script and region select Traditional Chinese', () {
    for (final locale in [
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      // FlutterLocalization uses this raw MapLocale language code in NeoStation.
      const Locale('zh_Hant'),
      const Locale('zh-Hant'),
      const Locale('zh_Hant_TW'),
      const Locale('zh_TW'),
      const Locale('zh_HK'),
      const Locale('zh_MO'),
      const Locale('zh', 'TW'),
      const Locale('zh', 'HK'),
      const Locale('zh', 'MO'),
    ]) {
      expect(RetroArchLocale.localeKey(locale), 'zh_Hant');
      expect(LibraryVisibilityLocale.localeKey(locale), 'zh_Hant');
      expect(RetroArchLocale.textForLocale(locale, 'resumeGame'), '繼續遊戲');
    }
    for (final locale in [
      const Locale('zh', 'CN'),
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    ]) {
      expect(RetroArchLocale.localeKey(locale), 'zh');
      expect(LibraryVisibilityLocale.localeKey(locale), 'zh');
    }
    expect(RetroArchLocale.localeKey(const Locale('xx')), 'en');
    expect(LibraryVisibilityLocale.localeKey(const Locale('xx')), 'en');
  });

  test('Native UI is translated and independent of constant catalogues', () {
    final translated = RetroArchLocale.nativeUI(const Locale('fr'));
    expect(translated['resumeGame'], 'Reprendre le jeu');
    translated['resumeGame'] = 'changed';
    expect(RetroArchLocale.values['fr']!['resumeGame'], 'Reprendre le jeu');
  });

  testWidgets(
    'Menus use the selected app language instead of device language',
    (tester) async {
      tester.binding.platformDispatcher.localeTestValue = const Locale('en');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      const locales = [
        Locale('en'),
        Locale('es'),
        Locale('ru'),
        Locale('zh'),
        Locale('zh_Hant'),
        Locale('pt'),
        Locale('fr'),
        Locale('de'),
        Locale('it'),
        Locale('id'),
        Locale('ja'),
        Locale('ko'),
      ];
      for (final locale in locales) {
        Map<String, String>? native;
        await tester.pumpWidget(
          WidgetsApp(
            color: const Color(0xFF000000),
            locale: locale,
            supportedLocales: locales,
            localizationsDelegates: const [
              DefaultWidgetsLocalizations.delegate,
            ],
            builder: (context, child) {
              native = RetroArchLocale.nativeUI(
                Localizations.localeOf(context),
              );
              return Column(
                children: [
                  Text(RetroArchLocale.text(context, 'resumeGame')),
                  Text(LibraryVisibilityLocale.text(context, 'title')),
                  Text(
                    RetroArchLocale.format(context, 'migrationCopied', {
                      'count': 3,
                      'skipped': 1,
                    }),
                  ),
                ],
              );
            },
          ),
        );
        await tester.pumpAndSettle();
        final expected =
            RetroArchLocale.values[RetroArchLocale.localeKey(locale)]!;
        expect(find.text(expected['resumeGame']!), findsOneWidget);
        expect(
          find.text(LibraryVisibilityLocale.textForLocale(locale, 'title')),
          findsOneWidget,
        );
        expect(native, expected);
        expect(
          find.text(
            expected['migrationCopied']!
                .replaceAll('{count}', '3')
                .replaceAll('{skipped}', '1'),
          ),
          findsOneWidget,
        );
      }
    },
  );

  test(
    'Launch explanations map actual error codes without technical diagnostics',
    () {
      const locale = Locale('fr');
      for (final entry in {
        'RETROARCH_GAME_IMPORT_REQUIRED': 'gameImportRequired',
        'RETROARCH_GAME_UNREADABLE': 'gameUnreadable',
        'RETROARCH_SESSION_ACTIVE': 'busy',
        'RETROARCH_CORE_UNAVAILABLE': 'coreUnavailable',
        'RETROARCH_CORE_NOT_READY': 'coreUnavailable',
        'RETROARCH_UNSUPPORTED_CORE': 'unsupportedCore',
        'RETROARCH_CORE_NOT_ALLOWED': 'unsupportedCore',
        'RETROARCH_GAME_PATH_INVALID': 'gameUnreadable',
        'RETROARCH_BACKEND_UNAVAILABLE': 'embeddedUnavailable',
        'RETROARCH_FRONTEND_UNAVAILABLE': 'embeddedUnavailable',
        'RETROARCH_BRIDGE_ERROR': 'launchFailed',
      }.entries) {
        expect(
          RetroArchLocale.launchError(locale, entry.key),
          RetroArchLocale.textForLocale(locale, entry.value),
        );
      }
      expect(
        RetroArchLocale.launchError(locale, null),
        RetroArchLocale.textForLocale(locale, 'launchFailed'),
      );
    },
  );
}
