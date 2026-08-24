import 'package:flutter/widgets.dart';

/// Twelve-language copy used by the fork's one-time first-install experience.
abstract final class ForkOnboardingLocale {
  static const Map<String, String> _languageTitles = {
    'de': 'Sprache auswählen',
    'en': 'Choose your language',
    'es': 'Elige tu idioma',
    'fr': 'Choisissez votre langue',
    'id': 'Pilih bahasa',
    'it': 'Scegli la lingua',
    'ja': '言語を選択',
    'ko': '언어 선택',
    'pt': 'Escolha seu idioma',
    'ru': 'Выберите язык',
    'zh': '选择语言',
    'zh_Hant': '選擇語言',
  };

  static const Map<String, String> _languageSubtitles = {
    'de': 'NeoStation verwendet diese Sprache in der gesamten App. Sie kann später in den Einstellungen geändert werden.',
    'en': 'NeoStation will use this language throughout the app. You can change it later in Settings.',
    'es': 'NeoStation usará este idioma en toda la aplicación. Puedes cambiarlo más tarde en Ajustes.',
    'fr': 'NeoStation utilisera cette langue dans toute l’application. Vous pourrez la modifier plus tard dans les paramètres.',
    'id': 'NeoStation akan menggunakan bahasa ini di seluruh aplikasi. Anda dapat mengubahnya nanti di Pengaturan.',
    'it': 'NeoStation userà questa lingua in tutta l’app. Potrai cambiarla in seguito nelle Impostazioni.',
    'ja': 'NeoStation はアプリ全体でこの言語を使用します。後から設定で変更できます。',
    'ko': 'NeoStation은 앱 전체에서 이 언어를 사용합니다. 나중에 설정에서 변경할 수 있습니다.',
    'pt': 'O NeoStation usará este idioma em todo o aplicativo. Você poderá alterá-lo depois nas Configurações.',
    'ru': 'NeoStation будет использовать этот язык во всём приложении. Позже его можно изменить в настройках.',
    'zh': 'NeoStation 将在整个应用中使用此语言。之后可在设置中更改。',
    'zh_Hant': 'NeoStation 將在整個應用程式中使用此語言。之後可在設定中更改。',
  };

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

  static const Map<String, String> _welcomeBodies = {
    'de': 'Willkommen bei diesem NeoStation-Fork. Er wurde entwickelt, damit du deine Spielesammlung einfach, immersiv und angenehm genießen kannst. Mach es dir bequem und viel Spaß.',
    'en': 'Welcome to this NeoStation fork. It was designed to make your game library simple, immersive, and enjoyable. Settle in and enjoy.',
    'es': 'Bienvenido a este fork de NeoStation. Está pensado para que disfrutes de tu biblioteca de juegos de forma sencilla, inmersiva y agradable. Ponte cómodo y disfruta.',
    'fr': 'Bienvenue sur ce fork de NeoStation. Il a été pensé pour rendre votre bibliothèque de jeux simple, immersive et agréable à parcourir. Installez-vous et profitez-en.',
    'id': 'Selamat datang di fork NeoStation ini. Fork ini dirancang agar pustaka game Anda terasa sederhana, imersif, dan menyenangkan. Silakan bersantai dan nikmati.',
    'it': 'Benvenuto in questo fork di NeoStation. È stato pensato per rendere la tua libreria di giochi semplice, immersiva e piacevole da esplorare. Mettiti comodo e divertiti.',
    'ja': 'この NeoStation フォークへようこそ。ゲームライブラリをシンプルで没入感があり、快適に楽しめるよう設計されています。ゆっくりお楽しみください。',
    'ko': '이 NeoStation 포크에 오신 것을 환영합니다. 게임 라이브러리를 간단하고 몰입감 있게, 즐겁게 이용할 수 있도록 만들어졌습니다. 편하게 즐겨 주세요.',
    'pt': 'Bem-vindo a este fork do NeoStation. Ele foi pensado para tornar sua biblioteca de jogos simples, imersiva e agradável de explorar. Fique à vontade e aproveite.',
    'ru': 'Добро пожаловать в этот форк NeoStation. Он создан, чтобы пользоваться вашей библиотекой игр было просто, атмосферно и приятно. Устраивайтесь поудобнее и наслаждайтесь.',
    'zh': '欢迎使用这个 NeoStation 分支版本。它旨在让你的游戏库更简洁、更具沉浸感，也更舒适易用。放松下来，尽情享受吧。',
    'zh_Hant': '歡迎使用這個 NeoStation 分支版本。它旨在讓你的遊戲庫更簡潔、更具沉浸感，也更舒適易用。放鬆下來，盡情享受吧。',
  };

  static const Map<String, String> _startLabels = {
    'de': 'Starten',
    'en': 'Start',
    'es': 'Comenzar',
    'fr': 'Commencer',
    'id': 'Mulai',
    'it': 'Inizia',
    'ja': 'はじめる',
    'ko': '시작',
    'pt': 'Começar',
    'ru': 'Начать',
    'zh': '开始',
    'zh_Hant': '開始',
  };

  static String languageTitle(BuildContext context) =>
      _lookup(_languageTitles, context);
  static String languageSubtitle(BuildContext context) =>
      _lookup(_languageSubtitles, context);
  static String continueLabel(BuildContext context) =>
      _lookup(_continueLabels, context);
  static String welcomeTitle(BuildContext context) =>
      _lookup(_welcomeTitles, context);
  static String welcomeBody(BuildContext context) =>
      _lookup(_welcomeBodies, context);
  static String startLabel(BuildContext context) =>
      _lookup(_startLabels, context);

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
