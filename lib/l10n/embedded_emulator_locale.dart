import 'package:flutter/widgets.dart';

/// Small shared localization surface for emulators compiled into NeoStation.
///
/// Keep emulator product names untranslated; only the embedded-status text is
/// localized in the same twelve locales exposed by NeoStation.
abstract final class EmbeddedEmulatorLocale {
  static const Map<String, String> _integrated = <String, String>{
    'en': 'Embedded in NeoStation',
    'fr': 'Embarqué dans NeoStation',
    'de': 'In NeoStation integriert',
    'es': 'Integrado en NeoStation',
    'it': 'Integrato in NeoStation',
    'pt': 'Integrado no NeoStation',
    'ru': 'Встроен в NeoStation',
    'id': 'Tersemat di NeoStation',
    'ja': 'NeoStation に内蔵',
    'ko': 'NeoStation에 내장됨',
    'zh': '内置于 NeoStation',
    'zh_Hant': '內建於 NeoStation',
  };

  static String integrated(BuildContext context) {
    final locale = Localizations.maybeLocaleOf(context) ?? const Locale('en');
    var key = locale.languageCode;
    if (key == 'zh') {
      final script = locale.scriptCode?.toLowerCase();
      final country = locale.countryCode?.toUpperCase();
      if (script == 'hant' ||
          country == 'TW' ||
          country == 'HK' ||
          country == 'MO') {
        key = 'zh_Hant';
      }
    }
    return _integrated[key] ?? _integrated['en']!;
  }
}
