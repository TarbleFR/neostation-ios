import 'package:flutter/widgets.dart';

abstract final class DusklightLocale {
  static const emptyLibrary = <String, String>{
    'en': 'Import Twilight Princess using Dusklight at the top right.',
    'fr': 'Importez Twilight Princess avec le bouton Dusklight en haut à droite.',
    'es': 'Importa Twilight Princess con Dusklight, arriba a la derecha.',
    'pt': 'Importe Twilight Princess com Dusklight no canto superior direito.',
    'de': 'Importiere Twilight Princess über Dusklight oben rechts.',
    'it': 'Importa Twilight Princess con Dusklight in alto a destra.',
    'ru': 'Импортируйте Twilight Princess кнопкой Dusklight справа вверху.',
    'zh': '使用右上角的 Dusklight 按钮导入 Twilight Princess。',
    'zh_Hant': '使用右上角的 Dusklight 按鈕匯入 Twilight Princess。',
    'id': 'Impor Twilight Princess melalui Dusklight di kanan atas.',
    'ja': '右上の Dusklight から Twilight Princess をインポートしてください。',
    'ko': '오른쪽 위 Dusklight 버튼으로 Twilight Princess를 가져오세요.',
  };

  static String emptyLibraryText(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final key = locale.languageCode == 'zh' &&
        (locale.scriptCode == 'Hant' || ['TW', 'HK', 'MO'].contains(locale.countryCode))
        ? 'zh_Hant' : locale.languageCode;
    return emptyLibrary[key] ?? emptyLibrary['en']!;
  }
}
