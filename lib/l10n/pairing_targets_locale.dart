import 'package:flutter/widgets.dart';

/// Localized note explaining the emulators targeted by the shared pairing file.
class PairingTargetsLocale {
  PairingTargetsLocale._();

  static String text(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final key = _localeKey(locale);
    return _values[key] ?? _values['en']!;
  }

  static String _localeKey(Locale locale) {
    if (locale.languageCode == 'zh') {
      final script = locale.scriptCode?.toLowerCase();
      final country = locale.countryCode?.toUpperCase();
      if (script == 'hant' || country == 'TW' || country == 'HK' || country == 'MO') {
        return 'zh_Hant';
      }
      return 'zh';
    }
    return _values.containsKey(locale.languageCode) ? locale.languageCode : 'en';
  }

  static const Map<String, String> _values = {
    'en': 'Used for MeloNX JIT. ARMSX2 and RPCS3 support is planned next.',
    'de': 'Wird für MeloNX-JIT verwendet. Unterstützung für ARMSX2 und RPCS3 ist als Nächstes geplant.',
    'es': 'Se usa para el JIT de MeloNX. La compatibilidad con ARMSX2 y RPCS3 está prevista próximamente.',
    'fr': 'Utilisé pour le JIT de MeloNX. La prise en charge d’ARMSX2 et de RPCS3 est prévue ensuite.',
    'id': 'Digunakan untuk JIT MeloNX. Dukungan ARMSX2 dan RPCS3 direncanakan berikutnya.',
    'it': 'Usato per il JIT di MeloNX. Il supporto per ARMSX2 e RPCS3 è previsto successivamente.',
    'ja': 'MeloNX の JIT に使用します。ARMSX2 と RPCS3 への対応も今後予定されています。',
    'ko': 'MeloNX JIT에 사용됩니다. ARMSX2와 RPCS3 지원도 이후 추가될 예정입니다.',
    'pt': 'Usado para o JIT do MeloNX. O suporte a ARMSX2 e RPCS3 está planejado para depois.',
    'ru': 'Используется для JIT MeloNX. Поддержка ARMSX2 и RPCS3 запланирована далее.',
    'zh': '用于 MeloNX 的 JIT。后续计划支持 ARMSX2 和 RPCS3。',
    'zh_Hant': '用於 MeloNX 的 JIT。後續計劃支援 ARMSX2 和 RPCS3。',
  };
}
