import 'package:flutter/widgets.dart';

/// Localized labels for the fork's main-menu music setting.
abstract final class HomeMusicLocale {
  static const Map<String, String> _titles = {
    'de': 'Musik im Hauptmenü',
    'en': 'Main menu music',
    'es': 'Música del menú principal',
    'fr': 'Musique du menu principal',
    'id': 'Musik menu utama',
    'it': 'Musica del menu principale',
    'ja': 'メインメニューの音楽',
    'ko': '메인 메뉴 음악',
    'pt': 'Música do menu principal',
    'ru': 'Музыка главного меню',
    'zh': '主菜单音乐',
    'zh_Hant': '主選單音樂',
  };

  static const Map<String, String> _subtitles = {
    'de': 'MP3, WAV, OGG oder FLAC auswählen; NeoStation speichert eine Kopie im Ordner menu_music',
    'en': 'Choose an MP3, WAV, OGG or FLAC file; NeoStation keeps a copy in its menu_music folder',
    'es': 'Elige un MP3, WAV, OGG o FLAC; NeoStation guarda una copia en la carpeta menu_music',
    'fr': 'Choisissez un MP3, WAV, OGG ou FLAC ; NeoStation en conserve une copie dans le dossier menu_music',
    'id': 'Pilih MP3, WAV, OGG, atau FLAC; NeoStation menyimpan salinannya di folder menu_music',
    'it': 'Scegli un MP3, WAV, OGG o FLAC; NeoStation ne conserva una copia nella cartella menu_music',
    'ja': 'MP3、WAV、OGG、FLAC を選択すると、NeoStation が menu_music フォルダーにコピーを保存します',
    'ko': 'MP3, WAV, OGG 또는 FLAC을 선택하면 NeoStation이 menu_music 폴더에 복사본을 저장합니다',
    'pt': 'Escolha um MP3, WAV, OGG ou FLAC; o NeoStation mantém uma cópia na pasta menu_music',
    'ru': 'Выберите MP3, WAV, OGG или FLAC; NeoStation сохранит копию в папке menu_music',
    'zh': '选择 MP3、WAV、OGG 或 FLAC；NeoStation 会在 menu_music 文件夹中保存副本',
    'zh_Hant': '選擇 MP3、WAV、OGG 或 FLAC；NeoStation 會在 menu_music 資料夾中保存副本',
  };

  static const Map<String, String> _active = {
    'de': 'Aktiv',
    'en': 'Active',
    'es': 'Activa',
    'fr': 'Active',
    'id': 'Aktif',
    'it': 'Attiva',
    'ja': '有効',
    'ko': '활성',
    'pt': 'Ativa',
    'ru': 'Включена',
    'zh': '已启用',
    'zh_Hant': '已啟用',
  };

  static const Map<String, String> _disabled = {
    'de': 'Deaktiviert',
    'en': 'Disabled',
    'es': 'Desactivada',
    'fr': 'Désactivée',
    'id': 'Nonaktif',
    'it': 'Disattivata',
    'ja': '無効',
    'ko': '비활성',
    'pt': 'Desativada',
    'ru': 'Выключена',
    'zh': '已停用',
    'zh_Hant': '已停用',
  };

  static const Map<String, String> _replace = {
    'de': 'Musik ersetzen',
    'en': 'Replace music',
    'es': 'Cambiar música',
    'fr': 'Remplacer la musique',
    'id': 'Ganti musik',
    'it': 'Sostituisci musica',
    'ja': '音楽を変更',
    'ko': '음악 바꾸기',
    'pt': 'Substituir música',
    'ru': 'Заменить музыку',
    'zh': '更换音乐',
    'zh_Hant': '更換音樂',
  };

  static String title(BuildContext context) => _lookup(_titles, context);
  static String subtitle(BuildContext context) => _lookup(_subtitles, context);
  static String active(BuildContext context) => _lookup(_active, context);
  static String disabled(BuildContext context) => _lookup(_disabled, context);
  static String replace(BuildContext context) => _lookup(_replace, context);

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
