import 'package:flutter/widgets.dart';

/// Fork-specific labels for the About page.
///
/// These strings deliberately distinguish support for the iOS fork from
/// informational links to the upstream NeoStation project.
abstract final class ForkAboutLocale {
  static const Map<String, String> _patreonTitles = {
    'de': 'Diesen iOS-Fork auf Patreon unterstützen',
    'en': 'Support this iOS fork on Patreon',
    'es': 'Apoya este fork de iOS en Patreon',
    'fr': 'Soutenir ce fork iOS sur Patreon',
    'id': 'Dukung fork iOS ini di Patreon',
    'it': 'Supporta questo fork iOS su Patreon',
    'ja': 'PatreonでこのiOSフォークを支援',
    'ko': 'Patreon에서 이 iOS 포크 후원',
    'pt': 'Apoie este fork iOS no Patreon',
    'ru': 'Поддержать этот iOS-форк на Patreon',
    'zh': '在 Patreon 上支持此 iOS 分支',
    'zh_Hant': '在 Patreon 上支持此 iOS 分支',
  };

  static const Map<String, String> _upstreamWebsiteTitles = {
    'de': 'Offizielle NeoStation-Website (Informationen)',
    'en': 'Official NeoStation website (information)',
    'es': 'Sitio oficial de NeoStation (información)',
    'fr': 'Site officiel NeoStation (informations)',
    'id': 'Situs resmi NeoStation (informasi)',
    'it': 'Sito ufficiale NeoStation (informazioni)',
    'ja': 'NeoStation公式サイト（情報）',
    'ko': 'NeoStation 공식 사이트 (정보)',
    'pt': 'Site oficial do NeoStation (informações)',
    'ru': 'Официальный сайт NeoStation (информация)',
    'zh': 'NeoStation 官方网站（信息）',
    'zh_Hant': 'NeoStation 官方網站（資訊）',
  };

  static const Map<String, String> _upstreamWebsiteDescriptions = {
    'de': 'Informationen zum ursprünglichen NeoStation-Projekt',
    'en': 'Information about the original NeoStation project',
    'es': 'Información sobre el proyecto NeoStation original',
    'fr': 'Informations sur le projet NeoStation d’origine',
    'id': 'Informasi tentang proyek NeoStation asli',
    'it': 'Informazioni sul progetto NeoStation originale',
    'ja': 'オリジナルのNeoStationプロジェクトに関する情報',
    'ko': '원본 NeoStation 프로젝트에 대한 정보',
    'pt': 'Informações sobre o projeto NeoStation original',
    'ru': 'Информация об исходном проекте NeoStation',
    'zh': '有关原始 NeoStation 项目的信息',
    'zh_Hant': '關於原始 NeoStation 專案的資訊',
  };

  static String patreonTitle(BuildContext context) =>
      _lookup(_patreonTitles, context);
  static String upstreamWebsiteTitle(BuildContext context) =>
      _lookup(_upstreamWebsiteTitles, context);
  static String upstreamWebsiteDescription(BuildContext context) =>
      _lookup(_upstreamWebsiteDescriptions, context);

  static String _lookup(Map<String, String> values, BuildContext context) {
    final locale = Localizations.localeOf(context);
    final key = _localeKey(locale);
    return values[key] ?? values['en']!;
  }

  static String _localeKey(Locale locale) {
    if (locale.languageCode == 'zh') {
      final script = locale.scriptCode?.toLowerCase();
      final country = locale.countryCode?.toUpperCase();
      if (script == 'hant' ||
          country == 'TW' ||
          country == 'HK' ||
          country == 'MO') {
        return 'zh_Hant';
      }
    }
    return locale.languageCode;
  }
}
