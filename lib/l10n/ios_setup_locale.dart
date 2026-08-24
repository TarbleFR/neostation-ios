import 'package:flutter/widgets.dart';

/// iOS-specific first-run setup copy used by the RetroArch linking step.
abstract final class IosSetupLocale {
  static const Map<String, String> _linkTitles = {
    'de': 'RetroArch verknüpfen',
    'en': 'Link RetroArch',
    'es': 'Vincular RetroArch',
    'fr': 'Lier RetroArch',
    'id': 'Tautkan RetroArch',
    'it': 'Collega RetroArch',
    'ja': 'RetroArch をリンク',
    'ko': 'RetroArch 연결',
    'pt': 'Vincular RetroArch',
    'ru': 'Подключить RetroArch',
    'zh': '连接 RetroArch',
    'zh_Hant': '連結 RetroArch',
  };

  static const Map<String, String> _linkDescriptions = {
    'de': 'Verknüpfe den eigenen Ordner von RetroArch, damit NeoStation deine Spiele sehen und mit einem Tipp direkt starten kann.',
    'en': 'Link RetroArch\'s own folder so NeoStation can see your games and launch them directly with one tap.',
    'es': 'Vincula la carpeta propia de RetroArch para que NeoStation pueda ver tus juegos e iniciarlos directamente con un toque.',
    'fr': 'Liez le dossier propre à RetroArch afin que NeoStation puisse voir vos jeux et les lancer directement en un toucher.',
    'id': 'Tautkan folder milik RetroArch agar NeoStation dapat melihat game Anda dan menjalankannya langsung dengan satu ketukan.',
    'it': 'Collega la cartella di RetroArch affinché NeoStation possa vedere i tuoi giochi e avviarli direttamente con un tocco.',
    'ja': 'RetroArch のフォルダをリンクすると、NeoStation からゲームを認識してワンタップで直接起動できます。',
    'ko': 'RetroArch 폴더를 연결하면 NeoStation에서 게임을 확인하고 한 번의 탭으로 바로 실행할 수 있습니다.',
    'pt': 'Vincule a pasta do RetroArch para que o NeoStation possa ver seus jogos e iniciá-los diretamente com um toque.',
    'ru': 'Подключите папку RetroArch, чтобы NeoStation мог видеть ваши игры и запускать их напрямую одним нажатием.',
    'zh': '连接 RetroArch 自己的文件夹，让 NeoStation 能够识别你的游戏并一键直接启动。',
    'zh_Hant': '連結 RetroArch 自己的資料夾，讓 NeoStation 能夠識別你的遊戲並一鍵直接啟動。',
  };

  static const Map<String, String> _linked = {
    'de': 'Verknüpft und synchronisiert.',
    'en': 'Linked and synced.',
    'es': 'Vinculado y sincronizado.',
    'fr': 'Lié et synchronisé.',
    'id': 'Tertaut dan tersinkron.',
    'it': 'Collegato e sincronizzato.',
    'ja': 'リンクして同期しました。',
    'ko': '연결 및 동기화되었습니다.',
    'pt': 'Vinculado e sincronizado.',
    'ru': 'Подключено и синхронизировано.',
    'zh': '已连接并同步。',
    'zh_Hant': '已連結並同步。',
  };

  static const Map<String, String> _restartTitles = {
    'de': 'Fast geschafft',
    'en': 'Almost there',
    'es': 'Ya casi está',
    'fr': 'Presque terminé',
    'id': 'Hampir selesai',
    'it': 'Ci siamo quasi',
    'ja': 'あと少しです',
    'ko': '거의 다 됐어요',
    'pt': 'Quase lá',
    'ru': 'Почти готово',
    'zh': '快完成了',
    'zh_Hant': '快完成了',
  };

  static const Map<String, String> _restartDescriptions = {
    'de': 'RetroArch ist verknüpft. Starte NeoStation neu, um deine synchronisierten Spiele hier zu sehen.',
    'en': 'RetroArch is linked. Relaunch NeoStation to see your synced games here.',
    'es': 'RetroArch está vinculado. Reinicia NeoStation para ver aquí tus juegos sincronizados.',
    'fr': 'RetroArch est lié. Relancez NeoStation pour voir ici vos jeux synchronisés.',
    'id': 'RetroArch sudah tertaut. Jalankan ulang NeoStation untuk melihat game yang telah disinkronkan di sini.',
    'it': 'RetroArch è collegato. Riavvia NeoStation per vedere qui i giochi sincronizzati.',
    'ja': 'RetroArch はリンクされています。NeoStation を再起動すると、同期済みのゲームがここに表示されます。',
    'ko': 'RetroArch가 연결되었습니다. NeoStation을 다시 실행하면 동기화된 게임이 여기에 표시됩니다.',
    'pt': 'O RetroArch está vinculado. Reinicie o NeoStation para ver aqui seus jogos sincronizados.',
    'ru': 'RetroArch подключён. Перезапустите NeoStation, чтобы увидеть здесь синхронизированные игры.',
    'zh': 'RetroArch 已连接。重新启动 NeoStation 即可在这里看到已同步的游戏。',
    'zh_Hant': 'RetroArch 已連結。重新啟動 NeoStation 即可在這裡看到已同步的遊戲。',
  };

  static const Map<String, String> _linkActionLabels = {
    'de': 'Verknüpfen',
    'en': 'Link',
    'es': 'Vincular',
    'fr': 'Lier',
    'id': 'Tautkan',
    'it': 'Collega',
    'ja': 'リンク',
    'ko': '연결',
    'pt': 'Vincular',
    'ru': 'Связать',
    'zh': '连接',
    'zh_Hant': '連結',
  };

  static const Map<String, String> _installActionLabels = {
    'de': 'Installieren',
    'en': 'Install',
    'es': 'Instalar',
    'fr': 'Installer',
    'id': 'Instal',
    'it': 'Installa',
    'ja': 'インストール',
    'ko': '설치',
    'pt': 'Instalar',
    'ru': 'Установить',
    'zh': '安装',
    'zh_Hant': '安裝',
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

  static String linkTitle(BuildContext context) =>
      _lookup(_linkTitles, context);
  static String linkDescription(BuildContext context) =>
      _lookup(_linkDescriptions, context);
  static String linked(BuildContext context) => _lookup(_linked, context);
  static String restartTitle(BuildContext context) =>
      _lookup(_restartTitles, context);
  static String restartDescription(BuildContext context) =>
      _lookup(_restartDescriptions, context);
  static String linkAction(BuildContext context) =>
      _lookup(_linkActionLabels, context);
  static String installAction(BuildContext context) =>
      _lookup(_installActionLabels, context);
  static String continueLabel(BuildContext context) =>
      _lookup(_continueLabels, context);

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
