import 'package:flutter/widgets.dart';

/// Localized labels for the main-menu custom background feature.
abstract final class CustomBackgroundLocale {
  static const Map<String, String> _titles = {
    'de': 'Benutzerdefinierter Hintergrund',
    'en': 'Custom Background',
    'es': 'Fondo personalizado',
    'fr': 'Fond personnalisé',
    'id': 'Latar belakang kustom',
    'it': 'Sfondo personalizzato',
    'ja': 'カスタム背景',
    'ko': '사용자 지정 배경',
    'pt': 'Fundo personalizado',
    'ru': 'Пользовательский фон',
    'zh': '自定义背景',
    'zh_Hant': '自訂背景',
  };

  static const Map<String, String> _subtitles = {
    'de': 'Bild, animiertes GIF oder Video für das Hauptmenü auswählen',
    'en': 'Choose an image, animated GIF, or video for the main menu',
    'es': 'Elige una imagen, GIF animado o vídeo para el menú principal',
    'fr': 'Choisir une image, un GIF animé ou une vidéo pour le menu principal',
    'id': 'Pilih gambar, GIF animasi, atau video untuk menu utama',
    'it': 'Scegli un’immagine, una GIF animata o un video per il menu principale',
    'ja': 'メインメニュー用の画像、アニメーションGIF、または動画を選択',
    'ko': '메인 메뉴용 이미지, 애니메이션 GIF 또는 동영상을 선택',
    'pt': 'Escolha uma imagem, GIF animado ou vídeo para o menu principal',
    'ru': 'Выберите изображение, анимированный GIF или видео для главного меню',
    'zh': '为主菜单选择图片、动态 GIF 或视频',
    'zh_Hant': '為主選單選擇圖片、動態 GIF 或影片',
  };

  static const Map<String, String> _active = {
    'de': 'Benutzerdefinierter Hintergrund aktiv',
    'en': 'Custom background active',
    'es': 'Fondo personalizado activo',
    'fr': 'Fond personnalisé actif',
    'id': 'Latar belakang kustom aktif',
    'it': 'Sfondo personalizzato attivo',
    'ja': 'カスタム背景が有効です',
    'ko': '사용자 지정 배경 사용 중',
    'pt': 'Fundo personalizado ativo',
    'ru': 'Пользовательский фон активен',
    'zh': '自定义背景已启用',
    'zh_Hant': '自訂背景已啟用',
  };

  static const Map<String, String> _updated = {
    'de': 'Benutzerdefinierter Hintergrund aktualisiert.',
    'en': 'Custom background updated.',
    'es': 'Fondo personalizado actualizado.',
    'fr': 'Fond personnalisé mis à jour.',
    'id': 'Latar belakang kustom diperbarui.',
    'it': 'Sfondo personalizzato aggiornato.',
    'ja': 'カスタム背景を更新しました。',
    'ko': '사용자 지정 배경을 업데이트했습니다.',
    'pt': 'Fundo personalizado atualizado.',
    'ru': 'Пользовательский фон обновлён.',
    'zh': '自定义背景已更新。',
    'zh_Hant': '自訂背景已更新。',
  };

  static const Map<String, String> _removed = {
    'de': 'Benutzerdefinierter Hintergrund entfernt.',
    'en': 'Custom background removed.',
    'es': 'Fondo personalizado eliminado.',
    'fr': 'Fond personnalisé supprimé.',
    'id': 'Latar belakang kustom dihapus.',
    'it': 'Sfondo personalizzato rimosso.',
    'ja': 'カスタム背景を削除しました。',
    'ko': '사용자 지정 배경을 제거했습니다.',
    'pt': 'Fundo personalizado removido.',
    'ru': 'Пользовательский фон удалён.',
    'zh': '自定义背景已移除。',
    'zh_Hant': '自訂背景已移除。',
  };

  static String title(BuildContext context) => _lookup(_titles, context);
  static String subtitle(BuildContext context) => _lookup(_subtitles, context);
  static String active(BuildContext context) => _lookup(_active, context);
  static String updated(BuildContext context) => _lookup(_updated, context);
  static String removed(BuildContext context) => _lookup(_removed, context);

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
