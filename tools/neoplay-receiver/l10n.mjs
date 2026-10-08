// Complete NeoPlay Desktop translations, matching the 12 NeoStation iOS locales.
// Language selection is per-user and never changes the network protocol.
export const LOCALES = Object.freeze(['en','fr','de','es','it','pt','ru','id','ja','ko','zh','zh-Hant']);
export const LANGUAGE_NAMES = Object.freeze({
  en:'English', fr:'Français', de:'Deutsch', es:'Español',
  it:'Italiano', pt:'Português', ru:'Русский', id:'Bahasa Indonesia',
  ja:'日本語', ko:'한국어', zh:'简体中文', 'zh-Hant':'繁體中文'
});
const KEYS = [
  'auto', 'sidebarTag', 'receive', 'connection', 'diagnostics', 'serviceActive', 'localOnly',
  'mainTitle', 'subtitle', 'fullscreen', 'disconnect', 'readyButton',
  'pin', 'pinHint', 'status', 'readyStatus', 'initializing', 'session',
  'transport', 'lanSecure', 'video', 'videoMode', 'audio', 'audioMode', 'privacy',
  'waiting', 'waitingHint', 'language', 'quality', 'original', 'enhanced', 'crisp',
  'qualityDescription', 'statusPair', 'receiving', 'disconnected', 'connectionError',
  'audioUnlock', 'decodeError', 'playbackError', 'tooSlow', 'codecError',
  'qualitySource', 'qualityDisplay'
];
const DATA = {
  en: [
    'Automatic', 'Desktop Receiver', 'Receive', 'Local connection', 'Diagnostics', 'Service active', 'Local network only',
    'NeoStation reception', 'Stream the iPhone screen to your PC with minimal latency.', 'Fullscreen', 'Disconnect', 'Activate NeoPlay',
    'Pairing code', 'Valid for 5 minutes. Changes after each session.', 'Status', 'Ready', 'Starting the local receiver…', 'Session',
    'Transport', 'Local network secured by code', 'Video', 'Live H.264 · low latency', 'Audio', 'Synchronized PCM', 'NeoPlay stays on your local network. No Internet relay or account is required.',
    'Waiting for NeoStation iOS', 'Open NeoPlay in NeoStation, select this PC and enter the code shown.', 'Language', 'Sharpness', 'Original · fastest', 'Enhanced', 'Extra sharp',
    'The enhancement only sharpens the received image. It cannot recreate detail absent from the iPhone capture.', 'Select this PC in NeoPlay. PIN valid for five minutes.', 'Receiving', 'Receiver disconnected. Activate NeoPlay to restart.', 'Cannot connect to local NeoPlay.', 'Click Activate NeoPlay to enable sound.',
    'Decode failed', 'Playback failed', 'Receiver too slow. Reconnect at lower resolution.', 'Codec unavailable', 'Source', 'Display'
  ],
  fr: [
    'Automatique', 'Récepteur Windows', 'Réception', 'Connexion locale', 'Diagnostics', 'Service actif', 'Réseau local uniquement',
    'Réception NeoStation', 'Diffusez l’écran de l’iPhone sur ce PC avec une latence minimale.', 'Plein écran', 'Déconnecter', 'Activer NeoPlay',
    'Code d’association', 'Valide 5 minutes. Change après chaque session.', 'État', 'Prêt', 'Démarrage du récepteur local…', 'Session',
    'Transport', 'Réseau local sécurisé par code', 'Vidéo', 'H.264 temps réel · faible latence', 'Audio', 'PCM synchronisé', 'NeoPlay reste sur votre réseau local. Aucun relais Internet ni compte nécessaire.',
    'En attente de NeoStation iOS', 'Ouvrez NeoPlay dans NeoStation, sélectionnez ce PC et saisissez le code affiché.', 'Langue', 'Netteté', 'Original · rapide', 'Améliorée', 'Renforcée',
    'Le traitement accentue la netteté de l’image reçue sans recréer les détails absents de la capture iPhone.', 'Sélectionnez ce PC dans NeoPlay. Code valide cinq minutes.', 'Réception', 'Récepteur déconnecté. Réactivez NeoPlay pour recommencer.', 'Connexion au NeoPlay local impossible.', 'Cliquez sur Activer NeoPlay pour autoriser le son.',
    'Échec du décodage', 'Échec de lecture', 'Récepteur trop lent. Reconnectez-vous avec une résolution inférieure.', 'Codec indisponible', 'Source', 'Affichage'
  ],
  de: [
    'Automatisch', 'Windows-Empfänger', 'Empfang', 'Lokale Verbindung', 'Diagnose', 'Dienst aktiv', 'Nur lokales Netzwerk',
    'NeoStation-Empfang', 'iPhone-Bildschirm mit minimaler Verzögerung auf dem PC anzeigen.', 'Vollbild', 'Trennen', 'NeoPlay aktivieren',
    'Kopplungscode', '5 Minuten gültig. Ändert sich nach jeder Sitzung.', 'Status', 'Bereit', 'Lokaler Empfänger wird gestartet…', 'Sitzung',
    'Übertragung', 'Lokales Netzwerk mit Code geschützt', 'Video', 'H.264 live · geringe Latenz', 'Audio', 'Synchronisiertes PCM', 'NeoPlay bleibt im lokalen Netzwerk. Kein Internet-Relay oder Konto nötig.',
    'Warte auf NeoStation iOS', 'NeoPlay in NeoStation öffnen, diesen PC auswählen und den Code eingeben.', 'Sprache', 'Schärfe', 'Original · schnell', 'Verbessert', 'Extra scharf',
    'Die Schärfung verbessert nur das empfangene Bild und kann fehlende Details nicht rekonstruieren.', 'Diesen PC in NeoPlay auswählen. Code fünf Minuten gültig.', 'Empfang', 'Empfänger getrennt. NeoPlay erneut aktivieren.', 'Lokaler NeoPlay-Empfänger nicht erreichbar.', 'NeoPlay aktivieren, um Ton zuzulassen.',
    'Dekodierung fehlgeschlagen', 'Wiedergabe fehlgeschlagen', 'Empfänger zu langsam. Mit geringerer Auflösung erneut verbinden.', 'Codec nicht verfügbar', 'Quelle', 'Anzeige'
  ],
  es: [
    'Automático', 'Receptor de Windows', 'Recepción', 'Conexión local', 'Diagnóstico', 'Servicio activo', 'Solo red local',
    'Recepción NeoStation', 'Transmite la pantalla del iPhone al PC con la mínima latencia.', 'Pantalla completa', 'Desconectar', 'Activar NeoPlay',
    'Código de vinculación', 'Válido durante 5 minutos. Cambia tras cada sesión.', 'Estado', 'Listo', 'Iniciando el receptor local…', 'Sesión',
    'Transporte', 'Red local protegida con código', 'Vídeo', 'H.264 en directo · baja latencia', 'Audio', 'PCM sincronizado', 'NeoPlay permanece en tu red local. No requiere cuenta ni retransmisión por Internet.',
    'Esperando a NeoStation iOS', 'Abre NeoPlay en NeoStation, selecciona este PC e introduce el código.', 'Idioma', 'Nitidez', 'Original · rápido', 'Mejorada', 'Extra nítida',
    'El filtro solo mejora la nitidez de la imagen recibida. No recupera detalles ausentes de la captura.', 'Selecciona este PC en NeoPlay. Código válido cinco minutos.', 'Recibiendo', 'Receptor desconectado. Vuelve a activar NeoPlay.', 'No se puede conectar al NeoPlay local.', 'Pulsa Activar NeoPlay para habilitar el sonido.',
    'Error de decodificación', 'Error de reproducción', 'Receptor demasiado lento. Vuelve a conectar con menor resolución.', 'Códec no disponible', 'Origen', 'Pantalla'
  ],
  it: [
    'Automatico', 'Ricevitore Windows', 'Ricezione', 'Connessione locale', 'Diagnostica', 'Servizio attivo', 'Solo rete locale',
    'Ricezione NeoStation', 'Trasmetti lo schermo iPhone al PC con latenza minima.', 'Schermo intero', 'Disconnetti', 'Attiva NeoPlay',
    'Codice di associazione', 'Valido 5 minuti. Cambia dopo ogni sessione.', 'Stato', 'Pronto', 'Avvio del ricevitore locale…', 'Sessione',
    'Trasporto', 'Rete locale protetta da codice', 'Video', 'H.264 in diretta · bassa latenza', 'Audio', 'PCM sincronizzato', 'NeoPlay resta nella rete locale. Non servono account o relay Internet.',
    'In attesa di NeoStation iOS', 'Apri NeoPlay in NeoStation, scegli questo PC e inserisci il codice.', 'Lingua', 'Nitidezza', 'Originale · veloce', 'Migliorata', 'Extra nitida',
    'Il filtro aumenta la nitidezza dell’immagine ricevuta ma non ricrea dettagli assenti dalla cattura.', 'Seleziona questo PC in NeoPlay. Codice valido cinque minuti.', 'Ricezione', 'Ricevitore disconnesso. Riattiva NeoPlay.', 'Impossibile collegarsi a NeoPlay locale.', 'Premi Attiva NeoPlay per abilitare l’audio.',
    'Decodifica non riuscita', 'Riproduzione non riuscita', 'Ricevitore troppo lento. Riconnettiti a risoluzione inferiore.', 'Codec non disponibile', 'Sorgente', 'Schermo'
  ],
  pt: [
    'Automático', 'Recetor Windows', 'Receção', 'Ligação local', 'Diagnóstico', 'Serviço ativo', 'Apenas rede local',
    'Receção NeoStation', 'Transmita o ecrã do iPhone para o PC com latência mínima.', 'Ecrã inteiro', 'Desligar', 'Ativar NeoPlay',
    'Código de emparelhamento', 'Válido durante 5 minutos. Muda após cada sessão.', 'Estado', 'Pronto', 'A iniciar o recetor local…', 'Sessão',
    'Transporte', 'Rede local protegida por código', 'Vídeo', 'H.264 em direto · baixa latência', 'Áudio', 'PCM sincronizado', 'NeoPlay permanece na sua rede local. Não requer conta ou retransmissão pela Internet.',
    'À espera de NeoStation iOS', 'Abra NeoPlay no NeoStation, escolha este PC e introduza o código.', 'Idioma', 'Nitidez', 'Original · rápido', 'Melhorada', 'Extra nítida',
    'O filtro melhora a nitidez da imagem recebida, mas não recupera detalhes ausentes da captura.', 'Selecione este PC no NeoPlay. Código válido cinco minutos.', 'A receber', 'Recetor desligado. Volte a ativar NeoPlay.', 'Não é possível ligar ao NeoPlay local.', 'Clique em Ativar NeoPlay para permitir o áudio.',
    'Falha na descodificação', 'Falha na reprodução', 'Recetor demasiado lento. Volte a ligar com resolução inferior.', 'Codec indisponível', 'Origem', 'Ecrã'
  ],
  ru: [
    'Автоматически', 'Приёмник Windows', 'Приём', 'Локальное соединение', 'Диагностика', 'Служба работает', 'Только локальная сеть',
    'Приём NeoStation', 'Передача экрана iPhone на ПК с минимальной задержкой.', 'Полный экран', 'Отключить', 'Включить NeoPlay',
    'Код сопряжения', 'Действует 5 минут. Меняется после каждого сеанса.', 'Состояние', 'Готово', 'Запуск локального приёмника…', 'Сеанс',
    'Передача', 'Локальная сеть с защитой кодом', 'Видео', 'H.264 в реальном времени · низкая задержка', 'Звук', 'Синхронный PCM', 'NeoPlay работает только в локальной сети. Учётная запись и интернет-сервер не нужны.',
    'Ожидание NeoStation iOS', 'Откройте NeoPlay в NeoStation, выберите этот ПК и введите код.', 'Язык', 'Резкость', 'Оригинал · быстро', 'Улучшенная', 'Повышенная',
    'Фильтр повышает резкость полученного изображения, но не восстанавливает отсутствующие детали.', 'Выберите этот ПК в NeoPlay. Код действует пять минут.', 'Приём', 'Приёмник отключён. Запустите NeoPlay снова.', 'Не удаётся подключиться к локальному NeoPlay.', 'Нажмите «Включить NeoPlay», чтобы разрешить звук.',
    'Ошибка декодирования', 'Ошибка воспроизведения', 'Приёмник слишком медленный. Подключитесь с меньшим разрешением.', 'Кодек недоступен', 'Источник', 'Экран'
  ],
  id: [
    'Otomatis', 'Penerima Windows', 'Penerimaan', 'Koneksi lokal', 'Diagnostik', 'Layanan aktif', 'Hanya jaringan lokal',
    'Penerimaan NeoStation', 'Tampilkan layar iPhone di PC dengan jeda seminimal mungkin.', 'Layar penuh', 'Putuskan', 'Aktifkan NeoPlay',
    'Kode pemasangan', 'Berlaku 5 menit. Berubah setelah setiap sesi.', 'Status', 'Siap', 'Memulai penerima lokal…', 'Sesi',
    'Transport', 'Jaringan lokal diamankan dengan kode', 'Video', 'H.264 langsung · latensi rendah', 'Audio', 'PCM tersinkron', 'NeoPlay tetap berada di jaringan lokal. Tidak perlu akun atau perantara Internet.',
    'Menunggu NeoStation iOS', 'Buka NeoPlay di NeoStation, pilih PC ini, lalu masukkan kode.', 'Bahasa', 'Ketajaman', 'Asli · cepat', 'Ditingkatkan', 'Sangat tajam',
    'Filter meningkatkan ketajaman gambar yang diterima, tetapi tidak dapat memulihkan detail yang tidak ditangkap.', 'Pilih PC ini di NeoPlay. Kode berlaku lima menit.', 'Menerima', 'Penerima terputus. Aktifkan NeoPlay lagi.', 'Tidak dapat terhubung ke NeoPlay lokal.', 'Klik Aktifkan NeoPlay untuk mengizinkan audio.',
    'Dekode gagal', 'Pemutaran gagal', 'Penerima terlalu lambat. Sambungkan ulang dengan resolusi lebih rendah.', 'Kodek tidak tersedia', 'Sumber', 'Tampilan'
  ],
  ja: [
    '自動', 'Windows レシーバー', '受信', 'ローカル接続', '診断', 'サービス稼働中', 'ローカルネットワークのみ',
    'NeoStation 受信', 'iPhone の画面を低遅延で PC に表示します。', '全画面表示', '切断', 'NeoPlay を有効化',
    'ペアリングコード', '有効期限は5分です。セッションごとに更新されます。', '状態', '準備完了', 'ローカルレシーバーを起動中…', 'セッション',
    '通信', 'コードで保護されたローカルネットワーク', '映像', 'リアルタイム H.264・低遅延', '音声', '同期 PCM', 'NeoPlay はローカルネットワークのみを使用します。アカウントやインターネット中継は不要です。',
    'NeoStation iOS を待機中', 'NeoStation で NeoPlay を開き、この PC を選んでコードを入力してください。', '言語', 'シャープネス', 'オリジナル・高速', '強調', '高シャープネス',
    '受信画像の輪郭を強調します。元のキャプチャにない細部を復元することはできません。', 'NeoPlay でこの PC を選択してください。コードは5分間有効です。', '受信中', '接続が切れました。NeoPlay を再度有効にしてください。', 'ローカル NeoPlay に接続できません。', '音声を有効にするには NeoPlay を有効化してください。',
    'デコードに失敗', '再生に失敗', '受信が追いつきません。解像度を下げて再接続してください。', 'コーデックが利用できません', 'ソース', '表示'
  ],
  ko: [
    '자동', 'Windows 수신기', '수신', '로컬 연결', '진단', '서비스 실행 중', '로컬 네트워크 전용',
    'NeoStation 수신', 'iPhone 화면을 최소 지연으로 PC에 전송합니다.', '전체 화면', '연결 해제', 'NeoPlay 활성화',
    '페어링 코드', '5분 동안 유효하며 세션마다 변경됩니다.', '상태', '준비됨', '로컬 수신기 시작 중…', '세션',
    '전송', '코드로 보호되는 로컬 네트워크', '비디오', '실시간 H.264 · 낮은 지연', '오디오', '동기화된 PCM', 'NeoPlay는 로컬 네트워크에서만 작동합니다. 계정이나 인터넷 중계가 필요하지 않습니다.',
    'NeoStation iOS 대기 중', 'NeoStation에서 NeoPlay를 열고 이 PC를 선택한 후 코드를 입력하세요.', '언어', '선명도', '원본 · 빠름', '향상됨', '매우 선명함',
    '수신된 화면을 선명하게 보정하지만 캡처되지 않은 세부 정보를 복원할 수는 없습니다.', 'NeoPlay에서 이 PC를 선택하세요. 코드는 5분간 유효합니다.', '수신 중', '수신기 연결이 끊어졌습니다. NeoPlay를 다시 활성화하세요.', '로컬 NeoPlay에 연결할 수 없습니다.', '오디오를 활성화하려면 NeoPlay를 활성화하세요.',
    '디코딩 실패', '재생 실패', '수신 속도가 느립니다. 해상도를 낮춰 다시 연결하세요.', '코덱을 사용할 수 없음', '소스', '디스플레이'
  ],
  zh: [
    '自动', 'Windows 接收器', '接收', '本地连接', '诊断', '服务已启动', '仅限本地网络',
    'NeoStation 接收', '将 iPhone 画面低延迟传输到电脑。', '全屏', '断开连接', '启用 NeoPlay',
    '配对码', '有效期为 5 分钟，每次会话后更新。', '状态', '就绪', '正在启动本地接收器…', '会话',
    '传输', '通过配对码保护的本地网络', '视频', '实时 H.264 · 低延迟', '音频', '同步 PCM', 'NeoPlay 仅在本地网络运行，无需账号或互联网中继。',
    '等待 NeoStation iOS', '在 NeoStation 中打开 NeoPlay，选择此电脑并输入代码。', '语言', '锐化', '原始 · 最快', '增强', '更清晰',
    '仅对接收画面进行锐化，无法恢复 iPhone 原始画面中缺失的细节。', '在 NeoPlay 中选择此电脑。配对码有效期为五分钟。', '正在接收', '接收器已断开。请重新启用 NeoPlay。', '无法连接本地 NeoPlay。', '点击启用 NeoPlay 以允许音频播放。',
    '解码失败', '播放失败', '接收器速度太慢，请降低分辨率后重连。', '不支持该编解码器', '来源', '显示'
  ],
  'zh-Hant': [
    '自動', 'Windows 接收器', '接收', '本機連線', '診斷', '服務運作中', '僅限區域網路',
    'NeoStation 接收', '以極低延遲將 iPhone 畫面傳輸到電腦。', '全螢幕', '中斷連線', '啟用 NeoPlay',
    '配對碼', '有效時間為 5 分鐘，每次工作階段後更新。', '狀態', '就緒', '正在啟動本機接收器…', '工作階段',
    '傳輸', '透過配對碼保護的區域網路', '影片', '即時 H.264 · 低延遲', '音訊', '同步 PCM', 'NeoPlay 僅在區域網路運作，無須帳號或網際網路轉送。',
    '等待 NeoStation iOS', '在 NeoStation 中開啟 NeoPlay，選擇此電腦並輸入代碼。', '語言', '銳利度', '原始 · 最快', '增強', '更清晰',
    '僅增強接收畫面的銳利度，無法還原 iPhone 原始擷取中缺失的細節。', '在 NeoPlay 中選擇此電腦。配對碼有效時間為五分鐘。', '正在接收', '接收器已斷線。請重新啟用 NeoPlay。', '無法連接本機 NeoPlay。', '按一下啟用 NeoPlay 以允許音訊。',
    '解碼失敗', '播放失敗', '接收器速度太慢，請降低解析度後重新連線。', '不支援此編解碼器', '來源', '顯示'
  ]
};

KEYS.push('cadence', 'linkQuality', 'linkAutomatic', 'linkAdjusting', 'nativeHint');
const LINK_LABELS = {
  en:['Frame rate','Link quality','Automatic','Adapting','Native 4K at 60 fps requires a 4K capture at 60 fps and a fast, stable local link.'],
  fr:['Cadence','Qualité du lien','Automatique','Adaptation en cours','La 4K native à 60 fps nécessite une capture 4K à 60 fps et un réseau local rapide et stable.'],
  de:['Bildrate','Verbindungsqualität','Automatisch','Anpassung läuft','Natives 4K mit 60 fps erfordert eine 4K-Aufnahme mit 60 fps und ein schnelles, stabiles lokales Netzwerk.'],
  es:['Fotogramas por segundo','Calidad del enlace','Automática','Adaptando','4K nativo a 60 fps requiere una captura 4K a 60 fps y una conexión local rápida y estable.'],
  it:['Frequenza fotogrammi','Qualità del collegamento','Automatica','Adattamento in corso','Il 4K nativo a 60 fps richiede una cattura 4K a 60 fps e una rete locale veloce e stabile.'],
  pt:['Taxa de quadros','Qualidade da ligação','Automática','A adaptar','4K nativo a 60 fps exige uma captura 4K a 60 fps e uma ligação local rápida e estável.'],
  ru:['Частота кадров','Качество соединения','Автоматически','Адаптация','Для нативного 4K при 60 fps нужны захват 4K при 60 fps и быстрая стабильная локальная сеть.'],
  id:['Laju bingkai','Kualitas koneksi','Otomatis','Menyesuaikan','4K asli pada 60 fps memerlukan tangkapan 4K pada 60 fps dan koneksi lokal yang cepat dan stabil.'],
  ja:['フレームレート','接続品質','自動','調整中','ネイティブ4K・60 fpsには、4K・60 fpsのキャプチャと高速で安定したローカル接続が必要です。'],
  ko:['프레임 속도','연결 품질','자동','조정 중','네이티브 4K 60 fps에는 4K 60 fps 캡처와 빠르고 안정적인 로컬 연결이 필요합니다.'],
  zh:['帧率','连接质量','自动','正在调整','原生 4K 60 fps 需要 4K 60 fps 画面采集以及快速稳定的本地连接。'],
  'zh-Hant':['幀率','連線品質','自動','正在調整','原生 4K 60 fps 需要 4K 60 fps 畫面擷取及快速穩定的區域網路連線。']
};
for (const code of LOCALES) DATA[code].push(...LINK_LABELS[code]);

export function resolveLocale(value) {
  const normalized = String(value || '').replaceAll('_','-').toLowerCase();
  if (normalized.startsWith('zh')) return /zh-(tw|hk|mo|hant)/.test(normalized) ? 'zh-Hant' : 'zh';
  const language = normalized.split('-')[0];
  return LOCALES.includes(language) ? language : 'en';
}
export function stringsFor(locale) {
  const translations = DATA[resolveLocale(locale)] || DATA.en;
  return Object.fromEntries(KEYS.map((key, index) => [key, translations[index] ?? DATA.en[index]]));
}
export function translationCoverage() {
  return Object.fromEntries(LOCALES.map(code => [code, {
    expected: KEYS.length, provided: DATA[code]?.length ?? 0,
    complete: DATA[code]?.length === KEYS.length && DATA[code].every(s => typeof s === 'string' && s.trim().length > 0)
  }]));
}
let selected = 'en';
export function locale() { return selected; }
export function t(key) { return stringsFor(selected)[key] || stringsFor('en')[key] || key; }
export function setupTranslations(doc = globalThis.document, nav = globalThis.navigator, storage = globalThis.localStorage) {
  const chooser = doc?.querySelector?.('#language-select');
  if (!chooser) { selected = 'en'; return selected; }
  let remembered = 'auto';
  try { remembered = storage?.getItem('neoplay.language') || 'auto'; } catch {}
  const fallback = resolveLocale(nav?.languages?.[0] || nav?.language || 'en');
  const show = choice => {
    selected = choice === 'auto' ? fallback : resolveLocale(choice);
    const entries = stringsFor(selected);
    for (const el of doc.querySelectorAll?.('[data-i18n]') || []) {
      if (el.dataset?.i18n && entries[el.dataset.i18n]) el.textContent = entries[el.dataset.i18n];
    }
    doc.documentElement?.setAttribute?.('lang', selected);
    if (chooser.value !== choice) chooser.value = choice;
    return selected;
  };
  chooser.addEventListener?.('change', () => {
    const value = chooser.value;
    try { storage?.setItem('neoplay.language', value); } catch {}
    show(value);
    globalThis.window?.dispatchEvent?.(new Event('neoplay-languagechange'));
  });
  return show(remembered === 'auto' || LOCALES.includes(remembered) ? remembered : 'auto');
}
