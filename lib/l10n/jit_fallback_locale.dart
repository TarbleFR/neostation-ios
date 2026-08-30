import 'package:flutter/widgets.dart';

/// Localized strings for the global StikDebug emergency fallback switch.
class JitFallbackLocale {
  JitFallbackLocale._();

  static const title = 'title';
  static const checking = 'checking';
  static const integratedStatus = 'integratedStatus';
  static const fallbackStatus = 'fallbackStatus';
  static const integratedDescription = 'integratedDescription';
  static const fallbackDescription = 'fallbackDescription';
  static const enabled = 'enabled';
  static const disabled = 'disabled';
  static const saveFailed = 'saveFailed';

  static String get(BuildContext context, String key) {
    final locale = Localizations.localeOf(context);
    final localeKey = _localeKey(locale);
    return _values[localeKey]?[key] ?? _values['en']![key] ?? key;
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
      return 'zh';
    }
    return _values.containsKey(locale.languageCode)
        ? locale.languageCode
        : 'en';
  }

  static const Map<String, Map<String, String>> _values = {
    'en': {
      title: 'StikDebug fallback',
      checking: 'Checking JIT method…',
      integratedStatus: 'Integrated StikJIT',
      fallbackStatus: 'StikDebug via Shortcuts',
      integratedDescription:
          'StikJIT is used for all compatible emulators. Enable this only if the integrated JIT stops working.',
      fallbackDescription:
          'All compatible emulators use StikDebug through their existing Shortcuts.',
      enabled: 'StikDebug fallback enabled.',
      disabled: 'Integrated StikJIT restored.',
      saveFailed: 'The JIT fallback setting could not be saved.',
    },
    'de': {
      title: 'StikDebug-Notfallmodus',
      checking: 'JIT-Methode wird geprüft…',
      integratedStatus: 'Integriertes StikJIT',
      fallbackStatus: 'StikDebug über Kurzbefehle',
      integratedDescription:
          'StikJIT wird für alle kompatiblen Emulatoren verwendet. Aktiviere diesen Modus nur, wenn das integrierte JIT nicht mehr funktioniert.',
      fallbackDescription:
          'Alle kompatiblen Emulatoren verwenden StikDebug über ihre vorhandenen Kurzbefehle.',
      enabled: 'StikDebug-Notfallmodus aktiviert.',
      disabled: 'Integriertes StikJIT wiederhergestellt.',
      saveFailed:
          'Die Einstellung des JIT-Notfallmodus konnte nicht gespeichert werden.',
    },
    'es': {
      title: 'Modo de respaldo StikDebug',
      checking: 'Comprobando el método JIT…',
      integratedStatus: 'StikJIT integrado',
      fallbackStatus: 'StikDebug mediante Atajos',
      integratedDescription:
          'StikJIT se usa para todos los emuladores compatibles. Activa este modo solo si el JIT integrado deja de funcionar.',
      fallbackDescription:
          'Todos los emuladores compatibles usan StikDebug mediante sus Atajos existentes.',
      enabled: 'Modo de respaldo StikDebug activado.',
      disabled: 'StikJIT integrado restaurado.',
      saveFailed: 'No se pudo guardar el modo de respaldo JIT.',
    },
    'fr': {
      title: 'Mode de secours StikDebug',
      checking: 'Vérification de la méthode JIT…',
      integratedStatus: 'StikJIT intégré',
      fallbackStatus: 'StikDebug via Raccourcis',
      integratedDescription:
          'StikJIT est utilisé pour tous les émulateurs compatibles. Activez ce mode uniquement si le JIT intégré ne fonctionne plus.',
      fallbackDescription:
          'Tous les émulateurs compatibles utilisent StikDebug via leurs Raccourcis existants.',
      enabled: 'Mode de secours StikDebug activé.',
      disabled: 'StikJIT intégré rétabli.',
      saveFailed:
          'Le réglage du mode de secours JIT n’a pas pu être enregistré.',
    },
    'id': {
      title: 'Mode cadangan StikDebug',
      checking: 'Memeriksa metode JIT…',
      integratedStatus: 'StikJIT bawaan',
      fallbackStatus: 'StikDebug melalui Pintasan',
      integratedDescription:
          'StikJIT digunakan untuk semua emulator yang kompatibel. Aktifkan mode ini hanya jika JIT bawaan berhenti berfungsi.',
      fallbackDescription:
          'Semua emulator yang kompatibel menggunakan StikDebug melalui Pintasan yang sudah ada.',
      enabled: 'Mode cadangan StikDebug diaktifkan.',
      disabled: 'StikJIT bawaan dipulihkan.',
      saveFailed: 'Pengaturan mode cadangan JIT tidak dapat disimpan.',
    },
    'it': {
      title: 'Modalità di riserva StikDebug',
      checking: 'Verifica del metodo JIT…',
      integratedStatus: 'StikJIT integrato',
      fallbackStatus: 'StikDebug tramite Comandi Rapidi',
      integratedDescription:
          'StikJIT viene usato per tutti gli emulatori compatibili. Attiva questa modalità solo se il JIT integrato smette di funzionare.',
      fallbackDescription:
          'Tutti gli emulatori compatibili usano StikDebug tramite i Comandi Rapidi esistenti.',
      enabled: 'Modalità di riserva StikDebug attivata.',
      disabled: 'StikJIT integrato ripristinato.',
      saveFailed: 'Impossibile salvare l’impostazione di riserva JIT.',
    },
    'ja': {
      title: 'StikDebug フォールバック',
      checking: 'JIT方式を確認中…',
      integratedStatus: '内蔵StikJIT',
      fallbackStatus: 'ショートカット経由のStikDebug',
      integratedDescription:
          '対応するすべてのエミュレーターで内蔵StikJITを使用します。内蔵JITが動作しなくなった場合のみ有効にしてください。',
      fallbackDescription:
          '対応するすべてのエミュレーターで既存のショートカット経由のStikDebugを使用します。',
      enabled: 'StikDebugフォールバックを有効にしました。',
      disabled: '内蔵StikJITに戻しました。',
      saveFailed: 'JITフォールバック設定を保存できませんでした。',
    },
    'ko': {
      title: 'StikDebug 대체 모드',
      checking: 'JIT 방식 확인 중…',
      integratedStatus: '내장 StikJIT',
      fallbackStatus: '단축어를 통한 StikDebug',
      integratedDescription:
          '호환되는 모든 에뮬레이터에 내장 StikJIT를 사용합니다. 내장 JIT가 더 이상 작동하지 않을 때만 이 모드를 켜세요.',
      fallbackDescription:
          '호환되는 모든 에뮬레이터가 기존 단축어를 통해 StikDebug를 사용합니다.',
      enabled: 'StikDebug 대체 모드를 켰습니다.',
      disabled: '내장 StikJIT로 복원했습니다.',
      saveFailed: 'JIT 대체 모드 설정을 저장할 수 없습니다.',
    },
    'pt': {
      title: 'Modo de contingência StikDebug',
      checking: 'Verificando o método JIT…',
      integratedStatus: 'StikJIT integrado',
      fallbackStatus: 'StikDebug por Atalhos',
      integratedDescription:
          'O StikJIT é usado em todos os emuladores compatíveis. Ative este modo apenas se o JIT integrado deixar de funcionar.',
      fallbackDescription:
          'Todos os emuladores compatíveis usam o StikDebug através dos Atalhos existentes.',
      enabled: 'Modo de contingência StikDebug ativado.',
      disabled: 'StikJIT integrado restaurado.',
      saveFailed: 'Não foi possível salvar o modo de contingência JIT.',
    },
    'ru': {
      title: 'Резервный режим StikDebug',
      checking: 'Проверка метода JIT…',
      integratedStatus: 'Встроенный StikJIT',
      fallbackStatus: 'StikDebug через Команды',
      integratedDescription:
          'Встроенный StikJIT используется для всех совместимых эмуляторов. Включайте этот режим только если встроенный JIT перестал работать.',
      fallbackDescription:
          'Все совместимые эмуляторы используют StikDebug через существующие Команды.',
      enabled: 'Резервный режим StikDebug включён.',
      disabled: 'Встроенный StikJIT восстановлен.',
      saveFailed:
          'Не удалось сохранить настройку резервного режима JIT.',
    },
    'zh': {
      title: 'StikDebug 备用模式',
      checking: '正在检查 JIT 方式…',
      integratedStatus: '内置 StikJIT',
      fallbackStatus: '通过快捷指令使用 StikDebug',
      integratedDescription:
          '所有兼容的模拟器都会使用内置 StikJIT。仅在内置 JIT 无法工作时启用此模式。',
      fallbackDescription:
          '所有兼容的模拟器都会通过现有快捷指令使用 StikDebug。',
      enabled: '已启用 StikDebug 备用模式。',
      disabled: '已恢复内置 StikJIT。',
      saveFailed: '无法保存 JIT 备用模式设置。',
    },
    'zh_Hant': {
      title: 'StikDebug 備援模式',
      checking: '正在檢查 JIT 方式…',
      integratedStatus: '內建 StikJIT',
      fallbackStatus: '透過捷徑使用 StikDebug',
      integratedDescription:
          '所有相容的模擬器都會使用內建 StikJIT。僅在內建 JIT 無法運作時啟用此模式。',
      fallbackDescription:
          '所有相容的模擬器都會透過現有捷徑使用 StikDebug。',
      enabled: '已啟用 StikDebug 備援模式。',
      disabled: '已恢復內建 StikJIT。',
      saveFailed: '無法儲存 JIT 備援模式設定。',
    },
  };
}
