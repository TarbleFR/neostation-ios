/// Late-added Dolphin UI strings that must override older English placeholders.
abstract final class DolphinExtendedLocale {
  static const Map<String, Map<String, String>> _v = {
    'en': {
      'deleteFailed': 'Deletion failed: {error}',
      'deleteGames': 'Delete games',
      'selectedCount': '{count} game(s) selected',
      'deselectAll': 'Deselect all',
      'selectAll': 'Select all',
      'deleting': 'Deleting {done} / {total}…',
      'cancel': 'Cancel',
      'deleteCount': 'Delete ({count})',
    },
    'fr': {
      'deleteFailed': 'La suppression a échoué : {error}',
      'deleteGames': 'Supprimer des jeux',
      'selectedCount': '{count} jeu(x) sélectionné(s)',
      'deselectAll': 'Tout désélectionner',
      'selectAll': 'Tout sélectionner',
      'deleting': 'Suppression {done} / {total}…',
      'cancel': 'Annuler',
      'deleteCount': 'Supprimer ({count})',
    },
    'de': {
      'deleteFailed': 'Löschen fehlgeschlagen: {error}',
      'deleteGames': 'Spiele löschen',
      'selectedCount': '{count} Spiel(e) ausgewählt',
      'deselectAll': 'Auswahl aufheben',
      'selectAll': 'Alle auswählen',
      'deleting': 'Löschen {done} / {total}…',
      'cancel': 'Abbrechen',
      'deleteCount': 'Löschen ({count})',
      'recording':'Videoaufnahme','startRecording':'Aufnahme starten · 50 fps','stopRecording':'Aufnahme stoppen','shareRecording':'Letztes Video teilen','recordingBusy':'Video wird vorbereitet…','recordingNoVideo':'Noch kein fertiges Video.','recordingFailed':'Videoaufnahme fehlgeschlagen. Beende andere Bildschirmaufnahmen, prüfe den freien Speicher und versuche es erneut.','recordingHelp':'Ziel sind 50 fps bis 1920 × 1080 bei korrektem Seitenverhältnis. Die interne Auflösung wird vorübergehend auf 2× begrenzt. Die tatsächliche Bildrate hängt weiterhin von der Gerätelast ab. Videos: Dateien → NeoStation → Recordings → Dolphin.',
      'hacks':'Kompatibilitäts-Hacks','hacksHelp':'Diese Optionen können die Geschwindigkeit verbessern oder Grafikfehler beheben, aber einzelne Spiele beeinträchtigen. VBI Skip kann Abstürze verursachen; unsichere Optionen sollten deaktiviert bleiben.','viSkip':'VBI Skip','skipEfbAccess':'EFB-Zugriff der CPU überspringen','ignoreFormatChanges':'EFB-Formatänderungen ignorieren','efbCopyToTexture':'EFB-Kopien nur als Textur speichern','deferEfbCopies':'EFB-Kopien verzögern','fastDepth':'Schnelle Tiefenberechnung','disableBoundingBox':'Bounding Box deaktivieren','vertexRounding':'Vertex-Rundung',
      'achievements':'RetroAchievements','achievementsHelp':'Das in NeoStation konfigurierte Konto wird automatisch verwendet. Der Standardmodus lässt Savestates und Kompatibilitäts-Hacks verfügbar.','raAccount':'Konto','raStatus':'Spielstatus','raMode':'Modus','notConnected':'Nicht verbunden','active':'Für dieses Spiel aktiv','hardcore':'Hardcore','standard':'Standard'
    },
    'es': {
      'deleteFailed': 'Error al eliminar: {error}',
      'deleteGames': 'Eliminar juegos',
      'selectedCount': '{count} juego(s) seleccionado(s)',
      'deselectAll': 'Deseleccionar todo',
      'selectAll': 'Seleccionar todo',
      'deleting': 'Eliminando {done} / {total}…',
      'cancel': 'Cancelar',
      'deleteCount': 'Eliminar ({count})',
      'recording':'Grabación de vídeo','startRecording':'Iniciar grabación · 50 fps','stopRecording':'Detener grabación','shareRecording':'Compartir último vídeo','recordingBusy':'Preparando vídeo…','recordingNoVideo':'Aún no hay ningún vídeo terminado.','recordingFailed':'La grabación de vídeo ha fallado. Detén otras grabaciones de pantalla, comprueba el espacio disponible y vuelve a intentarlo.','recordingHelp':'Objetivo de 50 fps hasta 1920 × 1080 conservando la proporción. La resolución interna se limita temporalmente a 2×. La tasa de imágenes real sigue dependiendo de la carga del dispositivo. Vídeos: Archivos → NeoStation → Recordings → Dolphin.',
      'hacks':'Ajustes de compatibilidad','hacksHelp':'Estas opciones pueden mejorar el rendimiento o corregir gráficos, pero pueden afectar a juegos concretos. VBI Skip puede provocar bloqueos; deja desactivadas las opciones dudosas.','viSkip':'Omitir VBI','skipEfbAccess':'Omitir acceso EFB desde CPU','ignoreFormatChanges':'Ignorar cambios de formato EFB','efbCopyToTexture':'Guardar copias EFB solo como textura','deferEfbCopies':'Aplazar copias EFB','fastDepth':'Cálculo rápido de profundidad','disableBoundingBox':'Desactivar bounding box','vertexRounding':'Redondeo de vértices',
      'achievements':'RetroAchievements','achievementsHelp':'Se usa automáticamente la cuenta configurada en NeoStation. El modo estándar mantiene disponibles los estados guardados y los ajustes de compatibilidad.','raAccount':'Cuenta','raStatus':'Estado del juego','raMode':'Modo','notConnected':'No conectado','active':'Activo para este juego','hardcore':'Hardcore','standard':'Estándar'
    },
    'it': {
      'deleteFailed': 'Eliminazione non riuscita: {error}',
      'deleteGames': 'Elimina giochi',
      'selectedCount': '{count} gioco/i selezionato/i',
      'deselectAll': 'Deseleziona tutto',
      'selectAll': 'Seleziona tutto',
      'deleting': 'Eliminazione {done} / {total}…',
      'cancel': 'Annulla',
      'deleteCount': 'Elimina ({count})',
      'recording':'Registrazione video','startRecording':'Avvia registrazione · 50 fps','stopRecording':'Interrompi registrazione','shareRecording':'Condividi ultimo video','recordingBusy':'Preparazione video…','recordingNoVideo':'Nessun video completato.','recordingFailed':'Registrazione video non riuscita. Interrompi altre registrazioni dello schermo, controlla lo spazio disponibile e riprova.','recordingHelp':'Obiettivo 50 fps fino a 1920 × 1080 mantenendo le proporzioni. La risoluzione interna viene temporaneamente limitata a 2×. Il frame rate effettivo dipende comunque dal carico del dispositivo. Video: File → NeoStation → Recordings → Dolphin.',
      'hacks':'Hack di compatibilità','hacksHelp':'Queste opzioni possono migliorare la velocità o correggere la grafica, ma possono creare problemi in alcuni giochi. VBI Skip può causare blocchi; lascia disattivate le opzioni incerte.','viSkip':'Salto VBI','skipEfbAccess':'Ignora accesso EFB dalla CPU','ignoreFormatChanges':'Ignora cambi di formato EFB','efbCopyToTexture':'Salva copie EFB solo come texture','deferEfbCopies':'Ritarda copie EFB','fastDepth':'Calcolo rapido della profondità','disableBoundingBox':'Disattiva bounding box','vertexRounding':'Arrotondamento vertici',
      'achievements':'RetroAchievements','achievementsHelp':'L’account configurato in NeoStation viene usato automaticamente. La modalità standard mantiene disponibili savestate e hack di compatibilità.','raAccount':'Account','raStatus':'Stato del gioco','raMode':'Modalità','notConnected':'Non connesso','active':'Attivo per questo gioco','hardcore':'Hardcore','standard':'Standard'
    },
    'pt': {
      'deleteFailed': 'Falha ao eliminar: {error}',
      'deleteGames': 'Eliminar jogos',
      'selectedCount': '{count} jogo(s) selecionado(s)',
      'deselectAll': 'Desmarcar tudo',
      'selectAll': 'Selecionar tudo',
      'deleting': 'A eliminar {done} / {total}…',
      'cancel': 'Cancelar',
      'deleteCount': 'Eliminar ({count})',
      'recording':'Gravação de vídeo','startRecording':'Iniciar gravação · 50 fps','stopRecording':'Parar gravação','shareRecording':'Partilhar último vídeo','recordingBusy':'A preparar vídeo…','recordingNoVideo':'Ainda não existe um vídeo concluído.','recordingFailed':'A gravação de vídeo falhou. Pare outras gravações do ecrã, verifique o espaço disponível e tente novamente.','recordingHelp':'Objetivo de 50 fps até 1920 × 1080 mantendo a proporção da imagem. A resolução interna é temporariamente limitada a 2×. A taxa de fotogramas real continua a depender da carga do dispositivo. Vídeos: Ficheiros → NeoStation → Recordings → Dolphin.',
      'hacks':'Ajustes de compatibilidade','hacksHelp':'Estas opções podem melhorar a velocidade ou corrigir gráficos, mas podem causar problemas em jogos específicos. VBI Skip pode provocar bloqueios; deixe opções incertas desativadas.','viSkip':'Ignorar VBI','skipEfbAccess':'Ignorar acesso EFB da CPU','ignoreFormatChanges':'Ignorar alterações de formato EFB','efbCopyToTexture':'Guardar cópias EFB apenas como textura','deferEfbCopies':'Adiar cópias EFB','fastDepth':'Cálculo rápido de profundidade','disableBoundingBox':'Desativar bounding box','vertexRounding':'Arredondamento de vértices',
      'achievements':'RetroAchievements','achievementsHelp':'A conta configurada no NeoStation é usada automaticamente. O modo padrão mantém savestates e ajustes de compatibilidade disponíveis.','raAccount':'Conta','raStatus':'Estado do jogo','raMode':'Modo','notConnected':'Não ligado','active':'Ativo para este jogo','hardcore':'Hardcore','standard':'Padrão'
    },
    'ru': {
      'deleteFailed': 'Ошибка удаления: {error}',
      'deleteGames': 'Удалить игры',
      'selectedCount': 'Выбрано игр: {count}',
      'deselectAll': 'Снять выделение',
      'selectAll': 'Выбрать всё',
      'deleting': 'Удаление {done} / {total}…',
      'cancel': 'Отмена',
      'deleteCount': 'Удалить ({count})',
      'recording':'Запись видео','startRecording':'Начать запись · 50 кадр/с','stopRecording':'Остановить запись','shareRecording':'Поделиться последним видео','recordingBusy':'Подготовка видео…','recordingNoVideo':'Готового видео пока нет.','recordingFailed':'Не удалось записать видео. Остановите другие записи экрана, проверьте свободное место и повторите попытку.','recordingHelp':'Цель — 50 кадр/с до 1920 × 1080 с сохранением пропорций. Внутреннее разрешение временно ограничивается 2×. Фактическая частота кадров всё равно зависит от нагрузки устройства. Видео: Файлы → NeoStation → Recordings → Dolphin.',
      'hacks':'Хаки совместимости','hacksHelp':'Эти параметры могут повысить скорость или исправить графику, но способны нарушить работу отдельных игр. VBI Skip может вызывать зависания; сомнительные параметры лучше оставить выключенными.','viSkip':'Пропуск VBI','skipEfbAccess':'Пропуск доступа CPU к EFB','ignoreFormatChanges':'Игнорировать смену формата EFB','efbCopyToTexture':'Хранить копии EFB только как текстуры','deferEfbCopies':'Отложить копии EFB','fastDepth':'Быстрый расчёт глубины','disableBoundingBox':'Отключить bounding box','vertexRounding':'Округление вершин',
      'achievements':'RetroAchievements','achievementsHelp':'Учётная запись, настроенная в NeoStation, используется автоматически. Стандартный режим сохраняет доступ к savestate и хакам совместимости.','raAccount':'Учётная запись','raStatus':'Статус игры','raMode':'Режим','notConnected':'Не подключено','active':'Активно для этой игры','hardcore':'Hardcore','standard':'Стандартный'
    },
    'id': {
      'deleteFailed': 'Penghapusan gagal: {error}',
      'deleteGames': 'Hapus game',
      'selectedCount': '{count} game dipilih',
      'deselectAll': 'Batalkan semua pilihan',
      'selectAll': 'Pilih semua',
      'deleting': 'Menghapus {done} / {total}…',
      'cancel': 'Batal',
      'deleteCount': 'Hapus ({count})',
      'recording':'Perekaman video','startRecording':'Mulai merekam · 50 fps','stopRecording':'Hentikan perekaman','shareRecording':'Bagikan video terakhir','recordingBusy':'Menyiapkan video…','recordingNoVideo':'Belum ada video yang selesai.','recordingFailed':'Perekaman video gagal. Hentikan perekaman layar lain, periksa ruang penyimpanan, lalu coba lagi.','recordingHelp':'Menargetkan 50 fps hingga 1920 × 1080 sambil mempertahankan rasio gambar. Resolusi internal sementara dibatasi ke 2×. Frame rate aktual tetap bergantung pada beban perangkat. Video: Files → NeoStation → Recordings → Dolphin.',
      'hacks':'Hack kompatibilitas','hacksHelp':'Opsi ini dapat meningkatkan kecepatan atau memperbaiki grafis, tetapi dapat mengganggu game tertentu. VBI Skip dapat menyebabkan macet; biarkan opsi yang tidak pasti tetap mati.','viSkip':'Lewati VBI','skipEfbAccess':'Lewati akses EFB dari CPU','ignoreFormatChanges':'Abaikan perubahan format EFB','efbCopyToTexture':'Simpan salinan EFB hanya sebagai tekstur','deferEfbCopies':'Tunda salinan EFB','fastDepth':'Perhitungan kedalaman cepat','disableBoundingBox':'Nonaktifkan bounding box','vertexRounding':'Pembulatan vertex',
      'achievements':'RetroAchievements','achievementsHelp':'Akun yang dikonfigurasi di NeoStation digunakan otomatis. Mode standar tetap menyediakan savestate dan hack kompatibilitas.','raAccount':'Akun','raStatus':'Status game','raMode':'Mode','notConnected':'Tidak terhubung','active':'Aktif untuk game ini','hardcore':'Hardcore','standard':'Standar'
    },
    'ja': {
      'deleteFailed': '削除に失敗しました: {error}',
      'deleteGames': 'ゲームを削除',
      'selectedCount': '{count} 件のゲームを選択',
      'deselectAll': 'すべて選択解除',
      'selectAll': 'すべて選択',
      'deleting': '削除中 {done} / {total}…',
      'cancel': 'キャンセル',
      'deleteCount': '削除 ({count})',
      'recording':'動画録画','startRecording':'録画開始 · 50 fps','stopRecording':'録画停止','shareRecording':'最新の動画を共有','recordingBusy':'動画を準備中…','recordingNoVideo':'完成した動画はまだありません。','recordingFailed':'動画の録画に失敗しました。他の画面録画を停止し、空き容量を確認してから再試行してください。','recordingHelp':'アスペクト比を維持しながら最大 1920 × 1080、50 fps を目標にします。内部解像度は一時的に 2× に制限されます。実際のフレームレートは端末負荷に左右されます。動画: ファイル → NeoStation → Recordings → Dolphin。',
      'hacks':'互換性ハック','hacksHelp':'速度向上や描画修正に役立つ場合がありますが、ゲームによっては問題を起こすことがあります。VBI Skip はフリーズの原因になる場合があるため、不明な項目はオフのままにしてください。','viSkip':'VBI スキップ','skipEfbAccess':'CPU からの EFB アクセスを省略','ignoreFormatChanges':'EFB フォーマット変更を無視','efbCopyToTexture':'EFB コピーをテクスチャのみに保存','deferEfbCopies':'EFB コピーを遅延','fastDepth':'高速深度計算','disableBoundingBox':'バウンディングボックスを無効化','vertexRounding':'頂点丸め',
      'achievements':'RetroAchievements','achievementsHelp':'NeoStation で設定したアカウントが自動的に使用されます。標準モードでは Savestate と互換性ハックを利用できます。','raAccount':'アカウント','raStatus':'ゲーム状態','raMode':'モード','notConnected':'未接続','active':'このゲームで有効','hardcore':'Hardcore','standard':'標準'
    },
    'ko': {
      'deleteFailed': '삭제 실패: {error}',
      'deleteGames': '게임 삭제',
      'selectedCount': '게임 {count}개 선택됨',
      'deselectAll': '모두 선택 해제',
      'selectAll': '모두 선택',
      'deleting': '삭제 중 {done} / {total}…',
      'cancel': '취소',
      'deleteCount': '삭제 ({count})',
      'recording':'비디오 녹화','startRecording':'녹화 시작 · 50 fps','stopRecording':'녹화 중지','shareRecording':'최근 비디오 공유','recordingBusy':'비디오 준비 중…','recordingNoVideo':'완료된 비디오가 아직 없습니다.','recordingFailed':'비디오 녹화에 실패했습니다. 다른 화면 녹화를 중지하고 저장 공간을 확인한 뒤 다시 시도하세요.','recordingHelp':'화면 비율을 유지하면서 최대 1920 × 1080, 50 fps를 목표로 합니다. 내부 해상도는 일시적으로 2×로 제한됩니다. 실제 프레임 속도는 기기 부하에 따라 달라집니다. 비디오: 파일 → NeoStation → Recordings → Dolphin.',
      'hacks':'호환성 핵','hacksHelp':'속도를 높이거나 그래픽을 수정할 수 있지만 일부 게임에 문제를 일으킬 수 있습니다. VBI Skip은 멈춤을 유발할 수 있으므로 확실하지 않은 옵션은 꺼 두세요.','viSkip':'VBI 건너뛰기','skipEfbAccess':'CPU의 EFB 접근 건너뛰기','ignoreFormatChanges':'EFB 포맷 변경 무시','efbCopyToTexture':'EFB 복사를 텍스처로만 저장','deferEfbCopies':'EFB 복사 지연','fastDepth':'빠른 깊이 계산','disableBoundingBox':'바운딩 박스 비활성화','vertexRounding':'버텍스 반올림',
      'achievements':'RetroAchievements','achievementsHelp':'NeoStation에 설정된 계정을 자동으로 사용합니다. 표준 모드에서는 Savestate와 호환성 핵을 계속 사용할 수 있습니다.','raAccount':'계정','raStatus':'게임 상태','raMode':'모드','notConnected':'연결되지 않음','active':'이 게임에서 활성','hardcore':'Hardcore','standard':'표준'
    },
    'zh': {
      'deleteFailed': '删除失败：{error}',
      'deleteGames': '删除游戏',
      'selectedCount': '已选择 {count} 个游戏',
      'deselectAll': '取消全选',
      'selectAll': '全选',
      'deleting': '正在删除 {done} / {total}…',
      'cancel': '取消',
      'deleteCount': '删除 ({count})',
      'recording':'视频录制','startRecording':'开始录制 · 50 fps','stopRecording':'停止录制','shareRecording':'分享最近视频','recordingBusy':'正在准备视频…','recordingNoVideo':'还没有已完成的视频。','recordingFailed':'视频录制失败。请停止其他屏幕录制，检查可用存储空间后重试。','recordingHelp':'目标为最高 1920 × 1080、50 fps，并保持画面比例。内部分辨率会暂时限制为 2×。实际帧率仍取决于设备负载。视频：文件 → NeoStation → Recordings → Dolphin。',
      'hacks':'兼容性调整','hacksHelp':'这些选项可能提升速度或修复画面，但也可能影响个别游戏。VBI Skip 可能导致卡死；不确定的选项请保持关闭。','viSkip':'跳过 VBI','skipEfbAccess':'跳过 CPU 的 EFB 访问','ignoreFormatChanges':'忽略 EFB 格式变化','efbCopyToTexture':'仅将 EFB 副本存为纹理','deferEfbCopies':'延迟 EFB 复制','fastDepth':'快速深度计算','disableBoundingBox':'禁用包围盒','vertexRounding':'顶点取整',
      'achievements':'RetroAchievements','achievementsHelp':'自动使用 NeoStation 中配置的账户。标准模式仍可使用存档状态和兼容性调整。','raAccount':'账户','raStatus':'游戏状态','raMode':'模式','notConnected':'未连接','active':'对此游戏生效','hardcore':'Hardcore','standard':'标准'
    },
    'zh_Hant': {
      'deleteFailed': '刪除失敗：{error}',
      'deleteGames': '刪除遊戲',
      'selectedCount': '已選擇 {count} 個遊戲',
      'deselectAll': '取消全選',
      'selectAll': '全選',
      'deleting': '正在刪除 {done} / {total}…',
      'cancel': '取消',
      'deleteCount': '刪除 ({count})',
      'recording':'影片錄製','startRecording':'開始錄製 · 50 fps','stopRecording':'停止錄製','shareRecording':'分享最近影片','recordingBusy':'正在準備影片…','recordingNoVideo':'尚無已完成的影片。','recordingFailed':'影片錄製失敗。請停止其他螢幕錄製，檢查可用儲存空間後再試。','recordingHelp':'目標為最高 1920 × 1080、50 fps，並維持畫面比例。內部解析度會暫時限制為 2×。實際幀率仍取決於裝置負載。影片：檔案 → NeoStation → Recordings → Dolphin。',
      'hacks':'相容性調整','hacksHelp':'這些選項可能提升速度或修正畫面，但也可能影響個別遊戲。VBI Skip 可能造成卡死；不確定的選項請保持關閉。','viSkip':'略過 VBI','skipEfbAccess':'略過 CPU 的 EFB 存取','ignoreFormatChanges':'忽略 EFB 格式變更','efbCopyToTexture':'僅將 EFB 複本儲存為紋理','deferEfbCopies':'延後 EFB 複製','fastDepth':'快速深度計算','disableBoundingBox':'停用包圍盒','vertexRounding':'頂點取整',
      'achievements':'RetroAchievements','achievementsHelp':'自動使用 NeoStation 中設定的帳戶。標準模式仍可使用存檔狀態與相容性調整。','raAccount':'帳戶','raStatus':'遊戲狀態','raMode':'模式','notConnected':'未連線','active':'對此遊戲生效','hardcore':'Hardcore','standard':'標準'
    },
  };

  static const Map<String, String> _launchFailed = {
    'en':'Dolphin could not start this game.',
    'fr':'Dolphin n’a pas pu démarrer ce jeu.',
    'de':'Dolphin konnte dieses Spiel nicht starten.',
    'es':'Dolphin no pudo iniciar este juego.',
    'it':'Dolphin non ha potuto avviare questo gioco.',
    'pt':'O Dolphin não conseguiu iniciar este jogo.',
    'ru':'Dolphin не удалось запустить эту игру.',
    'id':'Dolphin tidak dapat menjalankan game ini.',
    'ja':'Dolphin でこのゲームを起動できませんでした。',
    'ko':'Dolphin에서 이 게임을 실행할 수 없습니다.',
    'zh':'Dolphin 无法启动此游戏。',
    'zh_Hant':'Dolphin 無法啟動此遊戲。',
  };

  static const Map<String, Map<String, String>> _delete = {
    'en': {'deleteFailed':'Deletion failed: {error}','deleteGames':'Delete games','selectedCount':'{count} game(s) selected','deselectAll':'Deselect all','selectAll':'Select all','deleting':'Deleting {done} / {total}…','deleteCount':'Delete ({count})'},
    'fr': {'deleteFailed':'La suppression a échoué : {error}','deleteGames':'Supprimer des jeux','selectedCount':'{count} jeu(x) sélectionné(s)','deselectAll':'Tout désélectionner','selectAll':'Tout sélectionner','deleting':'Suppression {done} / {total}…','deleteCount':'Supprimer ({count})'},
    'de': {'deleteFailed':'Löschen fehlgeschlagen: {error}','deleteGames':'Spiele löschen','selectedCount':'{count} Spiel(e) ausgewählt','deselectAll':'Auswahl aufheben','selectAll':'Alle auswählen','deleting':'Löschen {done} / {total}…','deleteCount':'Löschen ({count})'},
    'es': {'deleteFailed':'Error al eliminar: {error}','deleteGames':'Eliminar juegos','selectedCount':'{count} juego(s) seleccionado(s)','deselectAll':'Deseleccionar todo','selectAll':'Seleccionar todo','deleting':'Eliminando {done} / {total}…','deleteCount':'Eliminar ({count})'},
    'it': {'deleteFailed':'Eliminazione non riuscita: {error}','deleteGames':'Elimina giochi','selectedCount':'{count} gioco/i selezionato/i','deselectAll':'Deseleziona tutto','selectAll':'Seleziona tutto','deleting':'Eliminazione {done} / {total}…','deleteCount':'Elimina ({count})'},
    'pt': {'deleteFailed':'Falha ao eliminar: {error}','deleteGames':'Eliminar jogos','selectedCount':'{count} jogo(s) selecionado(s)','deselectAll':'Desmarcar tudo','selectAll':'Selecionar tudo','deleting':'A eliminar {done} / {total}…','deleteCount':'Eliminar ({count})'},
    'ru': {'deleteFailed':'Ошибка удаления: {error}','deleteGames':'Удалить игры','selectedCount':'Выбрано игр: {count}','deselectAll':'Снять выделение','selectAll':'Выбрать всё','deleting':'Удаление {done} / {total}…','deleteCount':'Удалить ({count})'},
    'id': {'deleteFailed':'Penghapusan gagal: {error}','deleteGames':'Hapus game','selectedCount':'{count} game dipilih','deselectAll':'Batalkan semua pilihan','selectAll':'Pilih semua','deleting':'Menghapus {done} / {total}…','deleteCount':'Hapus ({count})'},
    'ja': {'deleteFailed':'削除に失敗しました: {error}','deleteGames':'ゲームを削除','selectedCount':'{count} 件のゲームを選択','deselectAll':'すべて選択解除','selectAll':'すべて選択','deleting':'削除中 {done} / {total}…','deleteCount':'削除 ({count})'},
    'ko': {'deleteFailed':'삭제 실패: {error}','deleteGames':'게임 삭제','selectedCount':'게임 {count}개 선택됨','deselectAll':'모두 선택 해제','selectAll':'모두 선택','deleting':'삭제 중 {done} / {total}…','deleteCount':'삭제 ({count})'},
    'zh': {'deleteFailed':'删除失败：{error}','deleteGames':'删除游戏','selectedCount':'已选择 {count} 个游戏','deselectAll':'取消全选','selectAll':'全选','deleting':'正在删除 {done} / {total}…','deleteCount':'删除 ({count})'},
    'zh_Hant': {'deleteFailed':'刪除失敗：{error}','deleteGames':'刪除遊戲','selectedCount':'已選擇 {count} 個遊戲','deselectAll':'取消全選','selectAll':'全選','deleting':'正在刪除 {done} / {total}…','deleteCount':'刪除 ({count})'},
  };

  static Map<String, String> labels(String localeKey) => <String, String>{
    ...?_v[localeKey],
    ...?_delete[localeKey],
  };

  static String? value(String localeKey, String key) {
    if (key == 'launchFailed') return _launchFailed[localeKey];
    return _delete[localeKey]?[key] ?? _v[localeKey]?[key];
  }
}
