import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/l10n/libretro_locale.dart';
import 'package:neostation/services/libretro_core_catalog.dart';

void main() {
  final placeholders = RegExp(r'\{\w+\}');
  final english = LibretroLocale.values['en']!;

  // Product names and words that are genuinely identical in a language.
  const identical = <String>{
    'fr:menu', 'fr:cheatCode', 'fr:resolutionNative',
    'de:disc', 'de:cheatName', 'de:cheatCode',
    'it:menu', 'it:slot', 'it:achievementsPassword',
    'pt:menu', 'id:menu', 'id:slot',
  };

  test('libretro covers exactly the twelve NeoStation languages', () {
    expect(
      LibretroLocale.values.keys.toSet(),
      AppLocale.supportedLanguages.keys.toSet(),
    );
  });

  for (final entry in LibretroLocale.values.entries) {
    test('${entry.key}: complete, placeholders kept, no English fallback', () {
      expect(entry.value.keys.toSet(), english.keys.toSet());
      for (final message in english.entries) {
        final translated = entry.value[message.key]!;
        expect(translated.trim(), isNotEmpty, reason: message.key);
        expect(
          placeholders.allMatches(translated).map((m) => m[0]).toSet(),
          placeholders.allMatches(message.value).map((m) => m[0]).toSet(),
          reason: '${entry.key}:${message.key}',
        );
        final productName = message.key == 'achievements';
        if (entry.key != 'en' &&
            !productName &&
            !identical.contains('${entry.key}:${message.key}')) {
          expect(translated, isNot(message.value), reason: '${entry.key}:${message.key}');
        }
      }
    });
  }

  test('script and regional Chinese settings select Traditional Chinese', () {
    for (final locale in <Locale>[
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      const Locale('zh', 'TW'),
      const Locale('zh', 'HK'),
      const Locale('zh', 'MO'),
      const Locale('zh_Hant'),
    ]) {
      expect(
        LibretroLocale.forLocale(locale, 'resume'),
        LibretroLocale.values['zh_Hant']!['resume'],
      );
    }
    expect(
      LibretroLocale.forLocale(const Locale('zh'), 'resume'),
      LibretroLocale.values['zh']!['resume'],
    );
    expect(LibretroLocale.forLocale(const Locale('nl'), 'resume'), english['resume']);
  });

  test('native labels are exactly the keys the iOS session requires', () {
    final plugin = File(
      'packages/libretro_internal_bridge/ios/Classes/LibretroInternalBridgePlugin.m',
    ).readAsStringSync();
    final block = RegExp(
      r'LibretroRequiredUIText\(void\) \{\s*return @\[(.*?)\];',
      dotAll: true,
    ).firstMatch(plugin)!.group(1)!;
    final native = RegExp(r'@"(\w+)"').allMatches(block).map((m) => m[1]!).toSet();
    expect(native, LibretroLocale.nativeKeys.toSet());
    for (final locale in LibretroLocale.values.keys) {
      final labels = LibretroLocale.nativeUI(Locale(locale));
      expect(labels.keys.toSet(), native, reason: locale);
      expect(labels.values.every((value) => value.trim().isNotEmpty), isTrue, reason: locale);
    }
  });

  test('every native error code maps to a translated message', () {
    final sources = Directory('packages/libretro_internal_bridge/ios/Classes')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.m'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    final codes = RegExp(r'@"(LIBRETRO_[A-Z_]+)"').allMatches(sources).map((m) => m[1]!).toSet();
    expect(codes, isNotEmpty);
    for (final code in codes) {
      expect(LibretroLocale.launchErrorKeys.containsKey(code), isTrue, reason: code);
    }
    for (final key in LibretroLocale.launchErrorKeys.values) {
      expect(english.containsKey(key), isTrue, reason: key);
    }
    expect(
      LibretroLocale.launchError(const Locale('fr'), 'LIBRETRO_BIOS_MISSING'),
      LibretroLocale.values['fr']!['errorBiosMissing'],
    );
    expect(
      LibretroLocale.launchError(const Locale('fr'), 'SOMETHING_ELSE'),
      LibretroLocale.values['fr']!['errorUnknown'],
    );
  });

  test('curated settings resolve every label in every language', () {
    for (final core in LibretroCoreCatalog.cores.values) {
      for (final setting in core.settings) {
        expect(english.containsKey(setting.labelKey), isTrue, reason: setting.key);
        for (final key in setting.valueLabelKeys.values) {
          expect(english.containsKey(key), isTrue, reason: key);
        }
        for (final value in setting.valueLabelKeys.keys) {
          expect(setting.values, contains(value), reason: value);
        }
      }
      final settings = LibretroLocale.coreSettings(const Locale('ja'), core);
      expect(settings.length, core.settings.length, reason: core.id);
    }
  });

  test('retro_language follows the NeoStation language', () {
    expect(LibretroLocale.retroLanguage(const Locale('en')), 0);
    expect(LibretroLocale.retroLanguage(const Locale('fr')), 2);
    expect(LibretroLocale.retroLanguage(const Locale('pt')), 8);
    expect(LibretroLocale.retroLanguage(const Locale('zh')), 12);
    expect(LibretroLocale.retroLanguage(const Locale('zh_Hant')), 11);
    expect(LibretroLocale.retroLanguage(const Locale('id')), 24);
    expect(LibretroLocale.retroLanguage(const Locale('nl')), 0);
  });
}
