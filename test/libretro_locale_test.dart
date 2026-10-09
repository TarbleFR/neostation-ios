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
    // "Skins" and "shaders": loanwords French, Spanish, Portuguese and German
    // players use as is (Delta, Provenance and RetroArch use them too).
    'fr:skins', 'es:skins', 'pt:skins', 'de:skins',
    'fr:shaders', 'es:shaders', 'pt:shaders',
    // "Preset": the established loanword of Italian and Indonesian software.
    'it:shaderPreset', 'id:shaderPreset',
    // "Scanlines": the usual German retro-gaming term (RetroArch de).
    'de:shaderScanlines',
    // "Downloads": the German noun (Duden: der Download, die Downloads).
    'de:catalogDownloads',
    // Same word in that language: Portrait (fr), Gamma (fr, es, it, de),
    // Amplitude (fr, pt, de), Phase (fr, de).
    'fr:orientationPortrait',
    'fr:paramGamma', 'es:paramGamma', 'it:paramGamma', 'de:paramGamma',
    'fr:paramAmplitude', 'pt:paramAmplitude', 'de:paramAmplitude',
    'fr:paramPhase', 'de:paramPhase',
  };

  const nativeClasses = 'packages/libretro_internal_bridge/ios/Classes';

  // Every Objective-C implementation of the native bridge, concatenated.
  String nativeSources() => Directory(nativeClasses)
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.m'))
      .map((file) => file.readAsStringSync())
      .join('\n');

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
    final nativeList = RegExp(r'@"(\w+)"').allMatches(block).map((m) => m[1]!).toList();
    final native = nativeList.toSet();
    expect(native, LibretroLocale.nativeKeys.toSet());
    // Same order and no duplicate on either side.
    expect(nativeList, LibretroLocale.nativeKeys);
    expect(native.length, nativeList.length);
    expect(english.keys, containsAll(LibretroLocale.nativeKeys));
    for (final locale in LibretroLocale.values.keys) {
      final labels = LibretroLocale.nativeUI(Locale(locale));
      expect(labels.keys.toSet(), native, reason: locale);
      expect(labels.values.every((value) => value.trim().isNotEmpty), isTrue, reason: locale);
    }
  });

  test('every native error code maps to a translated message', () {
    final sources = nativeSources();
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

  test('every native skin import code maps to a translated message', () {
    final codes =
        RegExp(r'@"(SKIN_[A-Z_]+)"').allMatches(nativeSources()).map((m) => m[1]!).toSet();
    expect(codes, isNotEmpty);
    for (final code in codes) {
      expect(LibretroLocale.skinErrorKeys.containsKey(code), isTrue, reason: code);
    }
    for (final key in LibretroLocale.skinErrorKeys.values) {
      expect(english.containsKey(key), isTrue, reason: key);
    }
    final french = LibretroLocale.values['fr']!;
    expect(
      LibretroLocale.skinMessage(
        const Locale('fr'),
        'SKIN_CONSOLE_UNSUPPORTED',
        arguments: <String, Object?>{'type': 'com.example.game'},
      ),
      french['skinErrorConsoleUnsupported']!.replaceAll('{type}', 'com.example.game'),
    );
    expect(
      LibretroLocale.skinMessage(const Locale('fr'), 'SKIN_WARN_DEBUG_MISSING'),
      french['skinWarnDebugMissing'],
    );
    expect(
      LibretroLocale.skinMessage(const Locale('fr'), 'SOMETHING_ELSE'),
      french['skinsImportFailed'],
    );
  });

  test('every shader preset and parameter label is sent to the native session', () {
    final source = File('$nativeClasses/LibretroShaderLibrary.m').readAsStringSync();
    // MakePreset(identifier, nameKey, ...) and MakeParameter(identifier,
    // labelKey, ...), plus any other shader* / param* key literal.
    final declared = RegExp(r'Make(?:Preset|Parameter)\(\s*@"[^"]*",\s*@"(\w+)"')
        .allMatches(source)
        .map((m) => m[1]!)
        .toSet();
    final literals =
        RegExp(r'@"((?:shader|param)[A-Z]\w*)"').allMatches(source).map((m) => m[1]!).toSet();
    expect(declared, isNotEmpty);
    for (final key in <String>{...declared, ...literals}) {
      expect(LibretroLocale.nativeKeys, contains(key), reason: key);
    }
  });

  test('every label the native code asks for is sent to the native session', () {
    final requested =
        RegExp(r'\btext:@"(\w+)"').allMatches(nativeSources()).map((m) => m[1]!).toSet();
    expect(requested, isNotEmpty);
    for (final key in requested) {
      expect(LibretroLocale.nativeKeys, contains(key), reason: key);
    }
  });

  test('the native session receives the skin, format, shader and control labels', () {
    expect(
      LibretroLocale.nativeKeys,
      containsAll(<String>[
        'skins', 'screenFormat', 'shaders', 'controls',
        // Existing DS / 3DS layout labels, now shown by the native layout page.
        'settingScreenLayout', 'layoutTopBottom', 'layoutLeftRight',
        'layoutHybridTop', 'layoutTopOnly', 'layoutBottomOnly',
      ]),
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
