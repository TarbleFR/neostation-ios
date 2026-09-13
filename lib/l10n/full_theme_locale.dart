import 'package:flutter/widgets.dart';

/// Localized strings for the full-theme import and takeover experience.
abstract final class FullThemeLocale {
  static const Map<String, String> _title = {
    'de': 'Komplettes Theme',
    'en': 'Full Theme',
    'es': 'Tema completo',
    'fr': 'Thème complet',
    'id': 'Tema lengkap',
    'it': 'Tema completo',
    'ja': 'フルテーマ',
    'ko': '전체 테마',
    'pt': 'Tema completo',
    'ru': 'Полная тема',
    'zh': '完整主题',
    'zh_Hant': '完整主題',
  };

  static const Map<String, String> _import = {
    'de': 'Komplettes Theme importieren (.zip)',
    'en': 'Import Full Theme (.zip)',
    'es': 'Importar tema completo (.zip)',
    'fr': 'Importer un thème complet (.zip)',
    'id': 'Impor tema lengkap (.zip)',
    'it': 'Importa tema completo (.zip)',
    'ja': 'フルテーマをインポート (.zip)',
    'ko': '전체 테마 가져오기 (.zip)',
    'pt': 'Importar tema completo (.zip)',
    'ru': 'Импортировать полную тему (.zip)',
    'zh': '导入完整主题 (.zip)',
    'zh_Hant': '匯入完整主題 (.zip)',
  };

  static const Map<String, String> _replace = {
    'de': 'Komplettes Theme ersetzen',
    'en': 'Replace Full Theme',
    'es': 'Reemplazar tema completo',
    'fr': 'Remplacer le thème complet',
    'id': 'Ganti tema lengkap',
    'it': 'Sostituisci tema completo',
    'ja': 'フルテーマを置き換える',
    'ko': '전체 테마 교체',
    'pt': 'Substituir tema completo',
    'ru': 'Заменить полную тему',
    'zh': '替换完整主题',
    'zh_Hant': '替換完整主題',
  };

  static const Map<String, String> _remove = {
    'de': 'Komplettes Theme entfernen',
    'en': 'Remove Full Theme',
    'es': 'Eliminar tema completo',
    'fr': 'Supprimer le thème complet',
    'id': 'Hapus tema lengkap',
    'it': 'Rimuovi tema completo',
    'ja': 'フルテーマを削除',
    'ko': '전체 테마 제거',
    'pt': 'Remover tema completo',
    'ru': 'Удалить полную тему',
    'zh': '移除完整主题',
    'zh_Hant': '移除完整主題',
  };

  static const Map<String, String> _colorTheme = {
    'de': 'Farbtheme importieren (.json)',
    'en': 'Import Color Theme (.json)',
    'es': 'Importar tema de color (.json)',
    'fr': 'Importer un thème de couleurs (.json)',
    'id': 'Impor tema warna (.json)',
    'it': 'Importa tema colori (.json)',
    'ja': 'カラーテーマをインポート (.json)',
    'ko': '색상 테마 가져오기 (.json)',
    'pt': 'Importar tema de cores (.json)',
    'ru': 'Импортировать цветовую тему (.json)',
    'zh': '导入颜色主题 (.json)',
    'zh_Hant': '匯入色彩主題 (.json)',
  };

  static const Map<String, String> _description = {
    'de': 'Ersetzt Startseite und Spielelisten durch eine einheitliche Oberfläche.',
    'en': 'Replaces the home screen and game playlists with one unified interface.',
    'es': 'Sustituye la pantalla de inicio y las listas de juegos por una interfaz unificada.',
    'fr': 'Remplace l’accueil et les playlists de jeux par une interface unifiée.',
    'id': 'Mengganti layar utama dan daftar game dengan satu antarmuka terpadu.',
    'it': 'Sostituisce la schermata principale e le playlist con un’unica interfaccia.',
    'ja': 'ホーム画面とゲームリストを統一されたインターフェースに置き換えます。',
    'ko': '홈 화면과 게임 목록을 하나의 통합 인터페이스로 교체합니다.',
    'pt': 'Substitui a tela inicial e as listas de jogos por uma interface unificada.',
    'ru': 'Заменяет главный экран и списки игр единым интерфейсом.',
    'zh': '使用统一界面替换主界面和游戏列表。',
    'zh_Hant': '使用統一介面取代主畫面和遊戲清單。',
  };

  static const Map<String, String> _success = {
    'de': 'Komplettes Theme aktiviert: %s',
    'en': 'Full theme activated: %s',
    'es': 'Tema completo activado: %s',
    'fr': 'Thème complet activé : %s',
    'id': 'Tema lengkap diaktifkan: %s',
    'it': 'Tema completo attivato: %s',
    'ja': 'フルテーマを有効にしました: %s',
    'ko': '전체 테마 활성화됨: %s',
    'pt': 'Tema completo ativado: %s',
    'ru': 'Полная тема активирована: %s',
    'zh': '完整主题已启用：%s',
    'zh_Hant': '完整主題已啟用：%s',
  };

  static const Map<String, String> _error = {
    'de': 'Das komplette Theme konnte nicht importiert werden.',
    'en': 'The full theme could not be imported.',
    'es': 'No se pudo importar el tema completo.',
    'fr': 'Impossible d’importer le thème complet.',
    'id': 'Tema lengkap tidak dapat diimpor.',
    'it': 'Impossibile importare il tema completo.',
    'ja': 'フルテーマをインポートできませんでした。',
    'ko': '전체 테마를 가져올 수 없습니다.',
    'pt': 'Não foi possível importar o tema completo.',
    'ru': 'Не удалось импортировать полную тему.',
    'zh': '无法导入完整主题。',
    'zh_Hant': '無法匯入完整主題。',
  };

  static String title(BuildContext context) => _lookup(_title, context);
  static String import(BuildContext context) => _lookup(_import, context);
  static String replace(BuildContext context) => _lookup(_replace, context);
  static String remove(BuildContext context) => _lookup(_remove, context);
  static String colorTheme(BuildContext context) => _lookup(_colorTheme, context);
  static String description(BuildContext context) => _lookup(_description, context);
  static String success(BuildContext context, String name) =>
      _lookup(_success, context).replaceAll('%s', name);
  static String error(BuildContext context) => _lookup(_error, context);

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
