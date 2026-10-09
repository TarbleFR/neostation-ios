import 'package:flutter/widgets.dart';

/// Twelve-language copy used by the fork's one-time first-install experience.
abstract final class ForkOnboardingLocale {
  static const Map<String, String> _continueLabels = {
    'de': 'Weiter',
    'en': 'Continue',
    'es': 'Continuar',
    'fr': 'Continuer',
    'id': 'Lanjutkan',
    'it': 'Continua',
    'ja': '続ける',
    'ko': '계속',
    'pt': 'Continuar',
    'ru': 'Продолжить',
    'zh': '继续',
    'zh_Hant': '繼續',
  };

  static const Map<String, String> _welcomeTitles = {
    'de': 'Willkommen bei NeoStation',
    'en': 'Welcome to NeoStation',
    'es': 'Bienvenido a NeoStation',
    'fr': 'Bienvenue sur NeoStation',
    'id': 'Selamat datang di NeoStation',
    'it': 'Benvenuto in NeoStation',
    'ja': 'NeoStation へようこそ',
    'ko': 'NeoStation에 오신 것을 환영합니다',
    'pt': 'Bem-vindo ao NeoStation',
    'ru': 'Добро пожаловать в NeoStation',
    'zh': '欢迎使用 NeoStation',
    'zh_Hant': '歡迎使用 NeoStation',
  };

  static String continueLabel(BuildContext context) =>
      _lookup(_continueLabels, context);
  static String welcomeTitle(BuildContext context) =>
      _lookup(_welcomeTitles, context);

  static String _lookup(Map<String, String> values, BuildContext context) {
    final locale = Localizations.localeOf(context);
    return values[_localeKey(locale)] ?? values['en']!;
  }

  static String _localeKey(Locale locale) {
    if (locale.languageCode == 'zh') {
      final scriptCode = locale.scriptCode?.toLowerCase();
      final countryCode = locale.countryCode?.toUpperCase();
      if (scriptCode == 'hant' ||
          countryCode == 'TW' ||
          countryCode == 'HK' ||
          countryCode == 'MO') {
        return 'zh_Hant';
      }
    }
    return locale.languageCode;
  }
}
