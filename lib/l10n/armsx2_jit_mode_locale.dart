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
      title: 'ARMSX2 Direct Launch (automatic NeoSync unavailable)',
      checking: 'Checking launch mode…',
      legacyStatus: 'Standard (NeoSync)',
      autoLoadStatus: 'Direct (Load Last Game)',
      legacyDescription:
          'Default and recommended. After JIT, NeoStation sends the selected game to ARMSX2 so its normal intro/BIOS flow is preserved. Disable Automatic Load Last Game in ARMSX2 for this mode. Automatic NeoSync remains available after the game closes.',
      autoLoadDescription:
          'Faster direct resume. Enable Automatic Load Last Game in ARMSX2 too. (Automatic NeoSync after the game is unavailable in this mode.)',
      enabled:
          'ARMSX2 Direct mode enabled. Automatic NeoSync is unavailable in this mode.',
      disabled: 'ARMSX2 Standard mode restored (NeoSync compatible).',
      saveFailed: 'The ARMSX2 launch mode could not be saved.',
    },
    'de': {
      title: 'ARMSX2-Direktstart (automatisches NeoSync nicht verfügbar)',
      checking: 'Startmodus wird geprüft…',
      legacyStatus: 'Standard (NeoSync)',
      autoLoadStatus: 'Direkt (Letztes Spiel laden)',
      legacyDescription:
          'Standard und empfohlen. Nach JIT sendet NeoStation das ausgewählte Spiel an ARMSX2, sodass Intro/BIOS normal verwendet werden. Für diesen Modus „Automatic Load Last Game“ in ARMSX2 deaktivieren. Automatisches NeoSync bleibt nach dem Spiel verfügbar.',
      autoLoadDescription:
          'Schneller Direktstart. „Automatic Load Last Game“ muss auch in ARMSX2 aktiviert sein. (Automatisches NeoSync nach dem Spiel ist in diesem Modus nicht verfügbar.)',
      enabled:
          'ARMSX2-Direktmodus aktiviert. Automatisches NeoSync ist in diesem Modus nicht verfügbar.',
      disabled: 'ARMSX2-Standardmodus wiederhergestellt (NeoSync-kompatibel).',
      saveFailed: 'Der ARMSX2-Startmodus konnte nicht gespeichert werden.',
    },
    'es': {
      title: 'Inicio directo ARMSX2 (NeoSync automático no disponible)',
      checking: 'Comprobando el modo de inicio…',
      legacyStatus: 'Estándar (NeoSync)',
      autoLoadStatus: 'Directo (Cargar último juego)',
      legacyDescription:
          'Predeterminado y recomendado. Tras JIT, NeoStation envía el juego seleccionado a ARMSX2 para conservar la intro/BIOS normal. Desactiva Automatic Load Last Game en ARMSX2 para este modo. NeoSync automático sigue disponible al cerrar el juego.',
      autoLoadDescription:
          'Reanudación directa más rápida. Activa también Automatic Load Last Game en ARMSX2. (NeoSync automático después del juego no está disponible en este modo.)',
      enabled:
          'Modo directo ARMSX2 activado. NeoSync automático no está disponible en este modo.',
      disabled: 'Modo estándar ARMSX2 restaurado (compatible con NeoSync).',
      saveFailed: 'No se pudo guardar el modo de inicio de ARMSX2.',
    },
    'fr': {
      title: 'ARMSX2 — Lancement direct (NeoSync auto indisponible)',
      checking: 'Vérification du mode de lancement…',
      legacyStatus: 'Standard (NeoSync)',
      autoLoadStatus: 'Direct (Load Last Game)',
      legacyDescription:
          'Mode par défaut et recommandé. Après le JIT, NeoStation envoie le jeu sélectionné à ARMSX2 afin de conserver le fonctionnement normal de l’intro et du BIOS. Désactive Automatic Load Last Game dans ARMSX2 pour ce mode. NeoSync automatique reste disponible à la fermeture du jeu.',
      autoLoadDescription:
          'Reprise directe plus rapide. Active aussi Automatic Load Last Game dans ARMSX2. (NeoSync automatique après la partie est indisponible dans ce mode.)',
      enabled:
          'Mode direct ARMSX2 activé. NeoSync automatique est indisponible dans ce mode.',
      disabled: 'Mode Standard ARMSX2 rétabli (compatible NeoSync).',
      saveFailed: 'Le mode de lancement ARMSX2 n’a pas pu être enregistré.',
    },
    'id': {
      title: 'Peluncuran Langsung ARMSX2 (NeoSync otomatis tidak tersedia)',
      checking: 'Memeriksa mode peluncuran…',
      legacyStatus: 'Standar (NeoSync)',
      autoLoadStatus: 'Langsung (Muat Game Terakhir)',
      legacyDescription:
          'Default dan disarankan. Setelah JIT, NeoStation mengirim game yang dipilih ke ARMSX2 agar intro/BIOS berjalan normal. Nonaktifkan Automatic Load Last Game di ARMSX2 untuk mode ini. NeoSync otomatis tetap tersedia setelah game ditutup.',
      autoLoadDescription:
          'Peluncuran langsung lebih cepat. Aktifkan juga Automatic Load Last Game di ARMSX2. (NeoSync otomatis setelah bermain tidak tersedia dalam mode ini.)',
      enabled:
          'Mode langsung ARMSX2 diaktifkan. NeoSync otomatis tidak tersedia dalam mode ini.',
      disabled: 'Mode Standar ARMSX2 dipulihkan (kompatibel NeoSync).',
      saveFailed: 'Mode peluncuran ARMSX2 tidak dapat disimpan.',
    },
    'it': {
      title: 'Avvio diretto ARMSX2 (NeoSync automatico non disponibile)',
      checking: 'Verifica modalità di avvio…',
      legacyStatus: 'Standard (NeoSync)',
      autoLoadStatus: 'Diretto (Carica ultimo gioco)',
      legacyDescription:
          'Predefinito e consigliato. Dopo JIT, NeoStation invia il gioco selezionato ad ARMSX2 mantenendo il normale flusso intro/BIOS. Disattiva Automatic Load Last Game in ARMSX2 per questa modalità. NeoSync automatico resta disponibile alla chiusura del gioco.',
      autoLoadDescription:
          'Ripresa diretta più rapida. Attiva anche Automatic Load Last Game in ARMSX2. (NeoSync automatico dopo il gioco non è disponibile in questa modalità.)',
      enabled:
          'Modalità diretta ARMSX2 attivata. NeoSync automatico non è disponibile in questa modalità.',
      disabled: 'Modalità Standard ARMSX2 ripristinata (compatibile NeoSync).',
      saveFailed: 'Impossibile salvare la modalità di avvio di ARMSX2.',
    },
    'ja': {
      title: 'ARMSX2 ダイレクト起動（自動NeoSyncは利用不可）',
      checking: '起動モードを確認中…',
      legacyStatus: '標準（NeoSync）',
      autoLoadStatus: 'ダイレクト（最後のゲームをロード）',
      legacyDescription:
          '既定かつ推奨です。JIT後にNeoStationが選択したゲームをARMSX2へ送り、通常のイントロ／BIOSの流れを維持します。このモードではARMSX2のAutomatic Load Last Gameを無効にしてください。ゲーム終了後の自動NeoSyncは利用できます。',
      autoLoadDescription:
          'より高速なダイレクト再開です。ARMSX2でもAutomatic Load Last Gameを有効にしてください。（このモードではゲーム終了後の自動NeoSyncは利用できません。）',
      enabled: 'ARMSX2ダイレクトモードを有効にしました。自動NeoSyncは利用できません。',
      disabled: 'ARMSX2標準モードに戻しました（NeoSync対応）。',
      saveFailed: 'ARMSX2の起動モードを保存できませんでした。',
    },
    'ko': {
      title: 'ARMSX2 직접 실행 (자동 NeoSync 사용 불가)',
      checking: '실행 모드 확인 중…',
      legacyStatus: '표준 (NeoSync)',
      autoLoadStatus: '직접 (마지막 게임 불러오기)',
      legacyDescription:
          '기본값이며 권장됩니다. JIT 후 NeoStation이 선택한 게임을 ARMSX2에 전달해 일반 인트로/BIOS 흐름을 유지합니다. 이 모드에서는 ARMSX2의 Automatic Load Last Game을 끄세요. 게임 종료 후 자동 NeoSync를 사용할 수 있습니다.',
      autoLoadDescription:
          '더 빠른 직접 재개입니다. ARMSX2에서도 Automatic Load Last Game을 켜세요. (이 모드에서는 게임 종료 후 자동 NeoSync를 사용할 수 없습니다.)',
      enabled: 'ARMSX2 직접 모드를 켰습니다. 이 모드에서는 자동 NeoSync를 사용할 수 없습니다.',
      disabled: 'ARMSX2 표준 모드로 복원했습니다 (NeoSync 호환).',
      saveFailed: 'ARMSX2 실행 모드를 저장할 수 없습니다.',
    },
    'pt': {
      title: 'Início direto ARMSX2 (NeoSync automático indisponível)',
      checking: 'Verificando modo de inicialização…',
      legacyStatus: 'Padrão (NeoSync)',
      autoLoadStatus: 'Direto (Carregar último jogo)',
      legacyDescription:
          'Padrão e recomendado. Após o JIT, o NeoStation envia o jogo selecionado ao ARMSX2, mantendo o fluxo normal de introdução/BIOS. Desative Automatic Load Last Game no ARMSX2 para este modo. O NeoSync automático permanece disponível ao fechar o jogo.',
      autoLoadDescription:
          'Retomada direta mais rápida. Ative também Automatic Load Last Game no ARMSX2. (O NeoSync automático após o jogo não está disponível neste modo.)',
      enabled:
          'Modo direto ARMSX2 ativado. O NeoSync automático não está disponível neste modo.',
      disabled: 'Modo Padrão ARMSX2 restaurado (compatível com NeoSync).',
      saveFailed: 'Não foi possível salvar o modo de inicialização do ARMSX2.',
    },
    'ru': {
      title: 'Прямой запуск ARMSX2 (авто-NeoSync недоступен)',
      checking: 'Проверка режима запуска…',
      legacyStatus: 'Стандартный (NeoSync)',
      autoLoadStatus: 'Прямой (загрузить последнюю игру)',
      legacyDescription:
          'Режим по умолчанию и рекомендуемый. После JIT NeoStation передаёт выбранную игру в ARMSX2, сохраняя обычный запуск через заставку/BIOS. Для этого режима отключите Automatic Load Last Game в ARMSX2. Автоматический NeoSync после закрытия игры остаётся доступен.',
      autoLoadDescription:
          'Более быстрый прямой запуск. Также включите Automatic Load Last Game в ARMSX2. (Автоматический NeoSync после игры в этом режиме недоступен.)',
      enabled:
          'Прямой режим ARMSX2 включён. Автоматический NeoSync в этом режиме недоступен.',
      disabled: 'Стандартный режим ARMSX2 восстановлен (совместим с NeoSync).',
      saveFailed: 'Не удалось сохранить режим запуска ARMSX2.',
    },
    'zh': {
      title: 'ARMSX2 直接启动（自动 NeoSync 不可用）',
      checking: '正在检查启动模式…',
      legacyStatus: '标准（NeoSync）',
      autoLoadStatus: '直接（载入上次游戏）',
      legacyDescription:
          '默认且推荐。JIT 后 NeoStation 会把所选游戏发送给 ARMSX2，保留正常的启动画面/BIOS 流程。此模式请在 ARMSX2 中关闭 Automatic Load Last Game。游戏关闭后仍可使用自动 NeoSync。',
      autoLoadDescription:
          '更快的直接继续。请同时在 ARMSX2 中开启 Automatic Load Last Game。（此模式下游戏结束后的自动 NeoSync 不可用。）',
      enabled: '已启用 ARMSX2 直接模式。此模式下自动 NeoSync 不可用。',
      disabled: '已恢复 ARMSX2 标准模式（支持 NeoSync）。',
      saveFailed: '无法保存 ARMSX2 启动模式。',
    },
    'zh_Hant': {
      title: 'ARMSX2 直接啟動（自動 NeoSync 不可用）',
      checking: '正在檢查啟動模式…',
      legacyStatus: '標準（NeoSync）',
      autoLoadStatus: '直接（載入上次遊戲）',
      legacyDescription:
          '預設且建議使用。JIT 後 NeoStation 會把所選遊戲傳給 ARMSX2，保留正常的啟動畫面／BIOS 流程。此模式請在 ARMSX2 關閉 Automatic Load Last Game。遊戲關閉後仍可使用自動 NeoSync。',
      autoLoadDescription:
          '更快的直接繼續。請同時在 ARMSX2 開啟 Automatic Load Last Game。（此模式下遊戲結束後的自動 NeoSync 不可用。）',
      enabled: '已啟用 ARMSX2 直接模式。此模式下自動 NeoSync 不可用。',
      disabled: '已恢復 ARMSX2 標準模式（支援 NeoSync）。',
      saveFailed: '無法儲存 ARMSX2 啟動模式。',
    },
  };
}
