import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/ports_locale.dart';

void main() {
  test('KartPad Ports strings cover all NeoStation locales', () {
    expect(PortsLocale.values, hasLength(12));
    for (final entry in PortsLocale.values.entries) {
      expect(entry.value['import'], isNotEmpty, reason: entry.key);
      expect(entry.value['kartpad'], isNotEmpty, reason: entry.key);
      expect(entry.value['kartpadLaunchFailed'], isNotEmpty, reason: entry.key);
      expect(entry.value['kartpadBusy'], isNotEmpty, reason: entry.key);
      expect(entry.value['kartpadRestartRequired'], isNotEmpty, reason: entry.key);
      expect(entry.value['returnToLibrary'], isNotEmpty, reason: entry.key);
      expect(entry.value['returnToGame'], isNotEmpty, reason: entry.key);
      expect(entry.value['kartpadRvzPrepareFailed'], isNotEmpty, reason: entry.key);
      for (final key in <String>[
        'settings',
        'gameLanguage',
        'languageRestartHint',
        'restartRequiredTitle',
        'languageRestartMessage',
        'restartGame',
        'cancel',
        'okay',
        'languageApplyFailed',
        'closeFailed',
        'graphicsRestartMessage',
        'closeNeoStation',
        'later',
        'advancedGraphics',
        'sharperPicture',
        'disableBloom',
        'skipShaders',
        'frameInterpolation',
        'frameInterpolationOff',
        'frameInterpolation120',
        'frameInterpolation180',
        'graphics',
        'renderResolution',
        'aspectRatio',
        'fpsCounter',
        'settingsRestartHint',
        'languageEnglish',
        'languageGerman',
        'languageFrench',
        'languageSpanish',
        'languageItalian',
        'languageDutch',
      ]) {
        expect(entry.value[key], isNotEmpty, reason: '${entry.key}: $key');
      }
    }
  });

  test('KartPad native UI uses the active locale', () {
    expect(
      PortsLocale.kartPadNativeUI(const Locale('fr'))['returnToLibrary'],
      'Retour à NeoStation',
    );
    expect(
      PortsLocale.kartPadNativeUI(const Locale('fr'))['returnToGame'],
      'Revenir au jeu',
    );
    expect(
      PortsLocale.kartPadNativeUI(const Locale('fr'))['settings'],
      'Réglages KartPad',
    );
    expect(
      PortsLocale.kartPadNativeUI(const Locale('fr'))['gameLanguage'],
      'Langue du jeu',
    );
    expect(
      PortsLocale.kartPadNativeUI(const Locale('fr'))['languageRestartHint'],
      contains('confirmation'),
    );
    expect(
      PortsLocale.kartPadNativeUI(const Locale('fr'))['languageRestartMessage'],
      contains('NeoStation reste ouvert'),
    );
    expect(
      PortsLocale.kartPadNativeUI(const Locale('fr'))['restartRequiredTitle'],
      'Redémarrer le jeu ?',
    );
    expect(
      PortsLocale.kartPadNativeUI(const Locale('fr'))['advancedGraphics'],
      'Graphismes avancés',
    );
    expect(
      PortsLocale.kartPadLaunchError(
        const Locale('fr'),
        'KARTPAD_CORE_NOT_READY',
      ),
      PortsLocale.forLocale(const Locale('fr'), 'kartpadCorePending'),
    );
  });
  test('KartPad consent, failure and close labels reach every native locale', () {
    for (final language in PortsLocale.values.keys) {
      final locale = language == 'zh_Hant'
          ? const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')
          : Locale(language);
      final native = PortsLocale.kartPadNativeUI(locale);
      for (final key in <String>[
        'restartGame', 'cancel', 'okay', 'languageApplyFailed', 'closeFailed',
        'languageRestartMessage', 'returnToGame', 'returnToLibrary',
      ]) {
        expect(native[key], PortsLocale.values[language]![key], reason: '$language/$key');
      }
    }
    expect(PortsLocale.kartPadNativeUI(const Locale('fr'))['restartGame'], 'Redémarrer le jeu');
    expect(PortsLocale.kartPadNativeUI(const Locale('fr'))['cancel'], 'Annuler');
  });

}
