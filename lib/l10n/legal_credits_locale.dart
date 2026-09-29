import 'package:flutter/widgets.dart';

/// Localized labels for the NeoStation iOS legal/credits surface.
///
/// Project names and license identifiers intentionally remain untranslated.
/// The surrounding UI covers every locale offered by NeoStation.
abstract final class LegalCreditsLocale {
  static const Map<String, String> _cardTitles = {
    'de': 'Open-Source-Lizenzen & Danksagungen',
    'en': 'Open-source licenses & credits',
    'es': 'Licencias de código abierto y créditos',
    'fr': 'Licences open source et crédits',
    'id': 'Lisensi sumber terbuka & kredit',
    'it': 'Licenze open source e crediti',
    'ja': 'オープンソースライセンスとクレジット',
    'ko': '오픈 소스 라이선스 및 크레딧',
    'pt': 'Licenças de código aberto e créditos',
    'ru': 'Лицензии открытого ПО и авторы',
    'zh': '开源许可与致谢',
    'zh_Hant': '開源授權與致謝',
  };

  static const Map<String, String> _cardDescriptions = {
    'de': 'Integrierte Projekte, Autoren, Lizenzen und Quellcode',
    'en': 'Embedded projects, authors, licenses and source',
    'es': 'Proyectos integrados, autores, licencias y código fuente',
    'fr': 'Projets intégrés, auteurs, licences et sources',
    'id': 'Proyek terintegrasi, pembuat, lisensi, dan sumber',
    'it': 'Progetti integrati, autori, licenze e sorgenti',
    'ja': '統合プロジェクト、作者、ライセンス、ソース',
    'ko': '통합 프로젝트, 제작자, 라이선스 및 소스',
    'pt': 'Projetos integrados, autores, licenças e código-fonte',
    'ru': 'Встроенные проекты, авторы, лицензии и исходники',
    'zh': '集成项目、作者、许可与源代码',
    'zh_Hant': '整合專案、作者、授權與原始碼',
  };

  static const Map<String, String> _dialogTitles = {
    'de': 'Lizenzen & Danksagungen',
    'en': 'Licenses & credits',
    'es': 'Licencias y créditos',
    'fr': 'Licences et crédits',
    'id': 'Lisensi & kredit',
    'it': 'Licenze e crediti',
    'ja': 'ライセンスとクレジット',
    'ko': '라이선스 및 크레딧',
    'pt': 'Licenças e créditos',
    'ru': 'Лицензии и авторы',
    'zh': '许可与致谢',
    'zh_Hant': '授權與致謝',
  };

  static const Map<String, String> _intros = {
    'de': 'NeoStation iOS baut auf vielen Open-Source-Projekten auf. Jede Komponente behält ihre eigene Lizenz und Urheberschaft. Die Nennung bedeutet keine Empfehlung durch die jeweiligen Projekte.',
    'en': 'NeoStation iOS builds on many open-source projects. Every component keeps its own license and authorship. Attribution does not imply endorsement by those projects.',
    'es': 'NeoStation iOS se basa en numerosos proyectos de código abierto. Cada componente conserva su propia licencia y autoría. La atribución no implica respaldo de esos proyectos.',
    'fr': 'NeoStation iOS s’appuie sur de nombreux projets open source. Chaque composant conserve sa propre licence et ses auteurs. Leur mention n’implique aucune approbation de leur part.',
    'id': 'NeoStation iOS dibangun di atas banyak proyek sumber terbuka. Setiap komponen tetap memiliki lisensi dan kepengarangan masing-masing. Atribusi tidak berarti dukungan dari proyek tersebut.',
    'it': 'NeoStation iOS si basa su numerosi progetti open source. Ogni componente conserva la propria licenza e paternità. L’attribuzione non implica approvazione da parte di tali progetti.',
    'ja': 'NeoStation iOS は多くのオープンソースプロジェクトを基盤としています。各コンポーネントのライセンスと作者表記はそのまま維持され、記載は各プロジェクトによる承認を意味しません。',
    'ko': 'NeoStation iOS는 여러 오픈 소스 프로젝트를 기반으로 합니다. 각 구성 요소의 라이선스와 저작자 표시는 그대로 유지되며, 표기는 해당 프로젝트의 보증을 의미하지 않습니다.',
    'pt': 'O NeoStation iOS baseia-se em vários projetos de código aberto. Cada componente mantém sua própria licença e autoria. A atribuição não implica endosso desses projetos.',
    'ru': 'NeoStation iOS использует множество проектов с открытым исходным кодом. Каждый компонент сохраняет свою лицензию и авторство. Указание авторства не означает одобрения со стороны этих проектов.',
    'zh': 'NeoStation iOS 基于多个开源项目构建。每个组件均保留其自身许可和作者信息。署名并不代表相关项目对 NeoStation 的认可。',
    'zh_Hant': 'NeoStation iOS 建構於多個開源專案之上。每個元件均保留其自身授權與作者資訊。署名不代表相關專案對 NeoStation 的認可。',
  };

  static const Map<String, String> _fullRecords = {
    'de': 'Vollständige Hinweise und Quellen',
    'en': 'Full notices and source records',
    'es': 'Avisos completos y registros de fuentes',
    'fr': 'Notices complètes et sources',
    'id': 'Pemberitahuan lengkap dan catatan sumber',
    'it': 'Avvisi completi e registri sorgente',
    'ja': '完全な通知とソース記録',
    'ko': '전체 고지 및 소스 기록',
    'pt': 'Avisos completos e registros de fonte',
    'ru': 'Полные уведомления и сведения об исходниках',
    'zh': '完整声明与源代码记录',
    'zh_Hant': '完整聲明與原始碼記錄',
  };

  static const Map<String, String> _closeLabels = {
    'de': 'Schließen',
    'en': 'Close',
    'es': 'Cerrar',
    'fr': 'Fermer',
    'id': 'Tutup',
    'it': 'Chiudi',
    'ja': '閉じる',
    'ko': '닫기',
    'pt': 'Fechar',
    'ru': 'Закрыть',
    'zh': '关闭',
    'zh_Hant': '關閉',
  };

  static String cardTitle(BuildContext context) => _lookup(_cardTitles, context);
  static String cardDescription(BuildContext context) =>
      _lookup(_cardDescriptions, context);
  static String dialogTitle(BuildContext context) =>
      _lookup(_dialogTitles, context);
  static String intro(BuildContext context) => _lookup(_intros, context);
  static String fullRecord(BuildContext context) =>
      _lookup(_fullRecords, context);
  static String close(BuildContext context) => _lookup(_closeLabels, context);

  static String _lookup(Map<String, String> values, BuildContext context) {
    final locale = Localizations.localeOf(context);
    return values[_localeKey(locale)] ?? values['en']!;
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
