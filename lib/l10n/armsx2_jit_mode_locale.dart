import 'package:flutter/widgets.dart';

/// Localized strings for the ARMSX2 integrated-StikJIT launch behaviour.
class Armsx2JitModeLocale {
  Armsx2JitModeLocale._();

  static const title = 'title';
  static const checking = 'checking';
  static const legacyStatus = 'legacyStatus';
  static const autoLoadStatus = 'autoLoadStatus';
  static const legacyDescription = 'legacyDescription';
  static const autoLoadDescription = 'autoLoadDescription';
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
      title: 'ARMSX2 Automatic Load Last Game',
      checking: 'Checking launch mode…',
      legacyStatus: 'Legacy handoff',
      autoLoadStatus: 'Direct after JIT',
      legacyDescription:
          'Keeps the existing flow: after JIT, NeoStation returns to the foreground and sends the selected game to ARMSX2. Use this when the ARMSX2 intro/menu is enabled.',
      autoLoadDescription:
          'Enable only when Automatic Load Last Game is also enabled in ARMSX2. NeoStation stops after JIT so ARMSX2 can resume its last game without a second launch.',
      enabled: 'ARMSX2 direct automatic-load mode enabled.',
      disabled: 'ARMSX2 legacy post-JIT handoff restored.',
      saveFailed: 'The ARMSX2 launch mode could not be saved.',
    },
    'de': {
      title: 'ARMSX2 – Letztes Spiel automatisch laden',
      checking: 'Startmodus wird geprüft…',
      legacyStatus: 'Kompatibilitätsübergabe',
      autoLoadStatus: 'Direkt nach JIT',
      legacyDescription:
          'Behält den bisherigen Ablauf bei: Nach JIT kehrt NeoStation in den Vordergrund zurück und sendet das gewählte Spiel an ARMSX2. Verwende dies, wenn Intro/Menü in ARMSX2 aktiviert ist.',
      autoLoadDescription:
          'Nur aktivieren, wenn „Automatic Load Last Game“ auch in ARMSX2 aktiviert ist. NeoStation stoppt nach JIT, damit ARMSX2 das letzte Spiel ohne zweiten Start fortsetzen kann.',
      enabled: 'Direkter automatischer ARMSX2-Start aktiviert.',
      disabled: 'ARMSX2-Kompatibilitätsübergabe wiederhergestellt.',
      saveFailed: 'Der ARMSX2-Startmodus konnte nicht gespeichert werden.',
    },
    'es': {
      title: 'ARMSX2 — Cargar último juego automáticamente',
      checking: 'Comprobando el modo de inicio…',
      legacyStatus: 'Entrega compatible',
      autoLoadStatus: 'Directo después de JIT',
      legacyDescription:
          'Mantiene el flujo actual: después de JIT, NeoStation vuelve al primer plano y envía el juego seleccionado a ARMSX2. Úsalo si la intro o el menú de ARMSX2 están activados.',
      autoLoadDescription:
          'Actívalo solo si Automatic Load Last Game también está activado en ARMSX2. NeoStation se detiene después de JIT para que ARMSX2 reanude el último juego sin un segundo inicio.',
      enabled: 'Modo directo de carga automática de ARMSX2 activado.',
      disabled: 'Entrega compatible de ARMSX2 restaurada.',
      saveFailed: 'No se pudo guardar el modo de inicio de ARMSX2.',
    },
    'fr': {
      title: 'ARMSX2 — Chargement auto du dernier jeu',
      checking: 'Vérification du mode de lancement…',
      legacyStatus: 'Relance compatible',
      autoLoadStatus: 'Direct après le JIT',
      legacyDescription:
          'Conserve le fonctionnement actuel : après le JIT, NeoStation revient au premier plan puis envoie le jeu sélectionné à ARMSX2. À utiliser si l’intro ou le menu ARMSX2 reste activé.',
      autoLoadDescription:
          'À activer uniquement si Automatic Load Last Game est aussi activé dans ARMSX2. NeoStation s’arrête après le JIT et laisse ARMSX2 reprendre son dernier jeu sans deuxième lancement.',
      enabled: 'Mode ARMSX2 direct après JIT activé.',
      disabled: 'Relance ARMSX2 compatible après JIT rétablie.',
      saveFailed: 'Le mode de lancement ARMSX2 n’a pas pu être enregistré.',
    },
    'id': {
      title: 'ARMSX2 — Muat Otomatis Game Terakhir',
      checking: 'Memeriksa mode peluncuran…',
      legacyStatus: 'Serah-terima kompatibel',
      autoLoadStatus: 'Langsung setelah JIT',
      legacyDescription:
          'Mempertahankan alur lama: setelah JIT, NeoStation kembali ke depan lalu mengirim game yang dipilih ke ARMSX2. Gunakan jika intro/menu ARMSX2 aktif.',
      autoLoadDescription:
          'Aktifkan hanya jika Automatic Load Last Game juga aktif di ARMSX2. NeoStation berhenti setelah JIT agar ARMSX2 melanjutkan game terakhir tanpa peluncuran kedua.',
      enabled: 'Mode muat otomatis langsung ARMSX2 diaktifkan.',
      disabled: 'Serah-terima kompatibel ARMSX2 dipulihkan.',
      saveFailed: 'Mode peluncuran ARMSX2 tidak dapat disimpan.',
    },
    'it': {
      title: 'ARMSX2 — Carica automaticamente l’ultimo gioco',
      checking: 'Verifica modalità di avvio…',
      legacyStatus: 'Passaggio compatibile',
      autoLoadStatus: 'Diretto dopo il JIT',
      legacyDescription:
          'Mantiene il flusso attuale: dopo il JIT, NeoStation torna in primo piano e invia il gioco selezionato ad ARMSX2. Usalo se intro/menu di ARMSX2 sono attivi.',
      autoLoadDescription:
          'Attivalo solo se Automatic Load Last Game è attivo anche in ARMSX2. NeoStation si ferma dopo il JIT e lascia che ARMSX2 riprenda l’ultimo gioco senza un secondo avvio.',
      enabled: 'Modalità diretta di caricamento automatico ARMSX2 attivata.',
      disabled: 'Passaggio compatibile ARMSX2 ripristinato.',
      saveFailed: 'Impossibile salvare la modalità di avvio ARMSX2.',
    },
    'ja': {
      title: 'ARMSX2 — 最後のゲームを自動ロード',
      checking: '起動モードを確認中…',
      legacyStatus: '互換ハンドオフ',
      autoLoadStatus: 'JIT後に直接続行',
      legacyDescription:
          '従来の動作を維持します。JIT後にNeoStationを前面へ戻し、選択したゲームをARMSX2へ送ります。ARMSX2のイントロ／メニューを使う場合はこちらを使用してください。',
      autoLoadDescription:
          'ARMSX2側でもAutomatic Load Last Gameを有効にした場合のみ使用してください。NeoStationはJIT後に処理を止め、ARMSX2が二重起動せず最後のゲームを再開します。',
      enabled: 'ARMSX2のJIT後直接ロードを有効にしました。',
      disabled: 'ARMSX2の互換ハンドオフに戻しました。',
      saveFailed: 'ARMSX2の起動モードを保存できませんでした。',
    },
    'ko': {
      title: 'ARMSX2 — 마지막 게임 자동 불러오기',
      checking: '실행 모드 확인 중…',
      legacyStatus: '호환 핸드오프',
      autoLoadStatus: 'JIT 후 바로 계속',
      legacyDescription:
          '기존 방식을 유지합니다. JIT 후 NeoStation을 다시 전면으로 가져오고 선택한 게임을 ARMSX2에 전달합니다. ARMSX2 인트로/메뉴를 사용하는 경우 선택하세요.',
      autoLoadDescription:
          'ARMSX2에서도 Automatic Load Last Game을 켠 경우에만 사용하세요. NeoStation은 JIT 후 멈추고 ARMSX2가 두 번째 실행 없이 마지막 게임을 이어서 시작합니다.',
      enabled: 'ARMSX2 JIT 후 직접 자동 로드 모드를 켰습니다.',
      disabled: 'ARMSX2 호환 핸드오프를 복원했습니다.',
      saveFailed: 'ARMSX2 실행 모드를 저장할 수 없습니다.',
    },
    'pt': {
      title: 'ARMSX2 — Carregar último jogo automaticamente',
      checking: 'Verificando modo de inicialização…',
      legacyStatus: 'Transferência compatível',
      autoLoadStatus: 'Direto após o JIT',
      legacyDescription:
          'Mantém o fluxo atual: após o JIT, o NeoStation volta ao primeiro plano e envia o jogo selecionado ao ARMSX2. Use quando a introdução/menu do ARMSX2 estiver ativo.',
      autoLoadDescription:
          'Ative apenas se Automatic Load Last Game também estiver ativo no ARMSX2. O NeoStation para após o JIT e deixa o ARMSX2 retomar o último jogo sem um segundo lançamento.',
      enabled: 'Modo direto de carregamento automático do ARMSX2 ativado.',
      disabled: 'Transferência compatível do ARMSX2 restaurada.',
      saveFailed: 'Não foi possível salvar o modo de inicialização do ARMSX2.',
    },
    'ru': {
      title: 'ARMSX2 — Автозагрузка последней игры',
      checking: 'Проверка режима запуска…',
      legacyStatus: 'Совместимый переход',
      autoLoadStatus: 'Сразу после JIT',
      legacyDescription:
          'Сохраняет прежнюю схему: после JIT NeoStation возвращается на передний план и передаёт выбранную игру в ARMSX2. Используйте, если заставка/меню ARMSX2 включены.',
      autoLoadDescription:
          'Включайте только вместе с Automatic Load Last Game в ARMSX2. NeoStation завершает свою часть после JIT, а ARMSX2 продолжает последнюю игру без второго запуска.',
      enabled: 'Прямой режим автозагрузки ARMSX2 включён.',
      disabled: 'Совместимый переход ARMSX2 восстановлен.',
      saveFailed: 'Не удалось сохранить режим запуска ARMSX2.',
    },
    'zh': {
      title: 'ARMSX2 — 自动载入上次游戏',
      checking: '正在检查启动模式…',
      legacyStatus: '兼容交接模式',
      autoLoadStatus: 'JIT 后直接继续',
      legacyDescription:
          '保留原有流程：JIT 完成后 NeoStation 回到前台，再把所选游戏发送给 ARMSX2。若保留 ARMSX2 启动画面/菜单，请使用此模式。',
      autoLoadDescription:
          '仅在 ARMSX2 中也开启 Automatic Load Last Game 时启用。NeoStation 在 JIT 后停止交接，让 ARMSX2 直接继续上次游戏，避免二次启动。',
      enabled: '已启用 ARMSX2 JIT 后直接自动载入模式。',
      disabled: '已恢复 ARMSX2 兼容交接模式。',
      saveFailed: '无法保存 ARMSX2 启动模式。',
    },
    'zh_Hant': {
      title: 'ARMSX2 — 自動載入上次遊戲',
      checking: '正在檢查啟動模式…',
      legacyStatus: '相容交接模式',
      autoLoadStatus: 'JIT 後直接繼續',
      legacyDescription:
          '保留原有流程：JIT 完成後 NeoStation 回到前景，再把所選遊戲傳給 ARMSX2。若保留 ARMSX2 啟動畫面／選單，請使用此模式。',
      autoLoadDescription:
          '僅在 ARMSX2 中也開啟 Automatic Load Last Game 時啟用。NeoStation 在 JIT 後停止交接，讓 ARMSX2 直接繼續上次遊戲，避免第二次啟動。',
      enabled: '已啟用 ARMSX2 JIT 後直接自動載入模式。',
      disabled: '已恢復 ARMSX2 相容交接模式。',
      saveFailed: '無法儲存 ARMSX2 啟動模式。',
    },
  };
}
