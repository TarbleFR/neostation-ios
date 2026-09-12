#!/usr/bin/env python3
"""Add Build 256's ten-slot, stretch and localized RPCS3 in-game UI."""

from __future__ import annotations

import sys
from pathlib import Path


MARKER = "NEOSTATION_RPCS3_BUILD256_HOST_V1"


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{description}: expected one source anchor, found {count}")
    return text.replace(old, new, 1)


def patch_abi(root: Path) -> None:
    path = root / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h"
    text = path.read_text()
    if "save_state_slot" in text:
        return
    text = replace_once(
        text,
        "  rpcs3_ios_status (*save_state)(void);\n",
        "  rpcs3_ios_status (*save_state)(void);\n"
        "  rpcs3_ios_status (*save_state_slot)(uint32_t slot);\n",
        "slot ABI",
    )
    path.write_text(text)


def patch_localization(root: Path) -> None:
    path = root / "packages/rpcs3_internal_bridge/ios/Classes/RPCS3InGameLocalization.mm"
    text = path.read_text()
    if MARKER in text:
        return
    anchor = """  return values;
}
}

NSString* RPCS3CanonicalLocale(NSString* identifier) {
"""
    translations = f'''  return values;
}}

NSDictionary<NSString*, NSDictionary<NSString*, NSString*>*>* Build256Translations() {{
  // {MARKER}: every new in-game string is available in NeoStation's 12 locales.
  static NSDictionary<NSString*, NSDictionary<NSString*, NSString*>*>* values;
  static dispatch_once_t once;
  dispatch_once(&once, ^{{
    values = @{{
      @"en": @{{
        @"state": @"Save state", @"states": @"Save states",
        @"slot": @"Slot", @"emptySlot": @"Empty",
        @"overwrite": @"Overwrite", @"overwriteTitle": @"Overwrite save state?",
        @"overwriteMessage": @"Slot %ld already contains a save state. The previous file will be replaced atomically.",
        @"stretch": @"Screen format", @"stretchTitle": @"Screen format",
        @"stretchMessage": @"The game will restart to apply this setting only to the current Game ID.",
        @"normal": @"Original aspect ratio", @"stretched": @"Stretch to fill screen",
        @"stateSafePoint": @"SPU threads could not reach a safe point. Retry outside active cutscenes.",
        @"stateVideoActive": @"A video cutscene is active and cannot be captured safely. Finish or skip it, then retry.",
        @"stateInvalid": @"This save state is invalid or is not compatible with this RPCS3 core.",
        @"stateMissing": @"The selected save state could not be found.",
        @"stateWriteFailed": @"RPCS3 could not write the save state. The previous slot was preserved.",
        @"stateBusy": @"Another save-state operation is already in progress.",
        @"stateUnknown": @"RPCS3 could not complete the save-state operation.",
        @"stateFreshRestart": @"The save state could not be loaded; the game was restarted normally.",
      }},
      @"fr": @{{
        @"state": @"État de sauvegarde", @"states": @"États de sauvegarde",
        @"slot": @"Emplacement", @"emptySlot": @"Vide",
        @"overwrite": @"Écraser", @"overwriteTitle": @"Écraser l’état de sauvegarde ?",
        @"overwriteMessage": @"L’emplacement %ld contient déjà un état. L’ancien fichier sera remplacé de façon atomique.",
        @"stretch": @"Format de l’écran", @"stretchTitle": @"Format de l’écran",
        @"stretchMessage": @"Le jeu redémarrera pour appliquer ce réglage uniquement au Game ID actuel.",
        @"normal": @"Format d’origine", @"stretched": @"Étirer pour remplir l’écran",
        @"stateSafePoint": @"Les threads SPU n’ont pas atteint un point sûr. Réessayez hors d’une cinématique active.",
        @"stateVideoActive": @"Une cinématique vidéo active ne peut pas être capturée sans risque. Terminez-la ou passez-la, puis réessayez.",
        @"stateInvalid": @"Cet état de sauvegarde est invalide ou incompatible avec ce cœur RPCS3.",
        @"stateMissing": @"L’état de sauvegarde sélectionné est introuvable.",
        @"stateWriteFailed": @"RPCS3 n’a pas pu écrire l’état. L’ancien emplacement a été conservé.",
        @"stateBusy": @"Une autre opération d’état de sauvegarde est déjà en cours.",
        @"stateUnknown": @"RPCS3 n’a pas pu terminer l’opération d’état de sauvegarde.",
        @"stateFreshRestart": @"L’état n’a pas pu être chargé ; le jeu a redémarré normalement.",
      }},
      @"de": @{{
        @"state": @"Speicherstand", @"states": @"Speicherstände",
        @"slot": @"Platz", @"emptySlot": @"Leer", @"overwrite": @"Überschreiben",
        @"overwriteTitle": @"Speicherstand überschreiben?",
        @"overwriteMessage": @"Platz %ld enthält bereits einen Speicherstand. Die vorherige Datei wird atomar ersetzt.",
        @"stretch": @"Bildformat", @"stretchTitle": @"Bildformat",
        @"stretchMessage": @"Das Spiel wird neu gestartet; die Einstellung gilt nur für die aktuelle Game-ID.",
        @"normal": @"Originales Seitenverhältnis", @"stretched": @"Auf Bildschirmgröße strecken",
        @"stateSafePoint": @"Die SPU-Threads erreichten keinen sicheren Punkt. Außerhalb aktiver Zwischensequenzen erneut versuchen.",
        @"stateVideoActive": @"Eine aktive Videosequenz kann nicht sicher gespeichert werden. Erst beenden oder überspringen.",
        @"stateInvalid": @"Dieser Speicherstand ist ungültig oder mit diesem RPCS3-Core nicht kompatibel.",
        @"stateMissing": @"Der gewählte Speicherstand wurde nicht gefunden.",
        @"stateWriteFailed": @"RPCS3 konnte nicht speichern. Der vorherige Platz blieb erhalten.",
        @"stateBusy": @"Ein anderer Speichervorgang läuft bereits.", @"stateUnknown": @"RPCS3 konnte den Speichervorgang nicht abschließen.",
        @"stateFreshRestart": @"Der Speicherstand konnte nicht geladen werden; das Spiel wurde normal neu gestartet.",
      }},
      @"es": @{{
        @"state": @"Estado de guardado", @"states": @"Estados de guardado",
        @"slot": @"Ranura", @"emptySlot": @"Vacía", @"overwrite": @"Sobrescribir",
        @"overwriteTitle": @"¿Sobrescribir el estado?",
        @"overwriteMessage": @"La ranura %ld ya contiene un estado. El archivo anterior se sustituirá de forma atómica.",
        @"stretch": @"Formato de pantalla", @"stretchTitle": @"Formato de pantalla",
        @"stretchMessage": @"El juego se reiniciará y el ajuste solo se aplicará al Game ID actual.",
        @"normal": @"Relación de aspecto original", @"stretched": @"Estirar para llenar la pantalla",
        @"stateSafePoint": @"Los hilos SPU no alcanzaron un punto seguro. Inténtalo fuera de una cinemática activa.",
        @"stateVideoActive": @"No se puede capturar una cinemática activa de forma segura. Termínala u omítela.",
        @"stateInvalid": @"Este estado no es válido o no es compatible con este núcleo RPCS3.",
        @"stateMissing": @"No se encontró el estado seleccionado.", @"stateWriteFailed": @"RPCS3 no pudo escribir el estado. Se conservó la ranura anterior.",
        @"stateBusy": @"Ya hay otra operación de estado en curso.", @"stateUnknown": @"RPCS3 no pudo completar la operación del estado.",
        @"stateFreshRestart": @"No se pudo cargar el estado; el juego se reinició normalmente.",
      }},
      @"it": @{{
        @"state": @"Stato di salvataggio", @"states": @"Stati di salvataggio",
        @"slot": @"Slot", @"emptySlot": @"Vuoto", @"overwrite": @"Sovrascrivi",
        @"overwriteTitle": @"Sovrascrivere lo stato?",
        @"overwriteMessage": @"Lo slot %ld contiene già uno stato. Il file precedente verrà sostituito in modo atomico.",
        @"stretch": @"Formato schermo", @"stretchTitle": @"Formato schermo",
        @"stretchMessage": @"Il gioco verrà riavviato e l’impostazione si applicherà solo al Game ID corrente.",
        @"normal": @"Proporzioni originali", @"stretched": @"Estendi a schermo intero",
        @"stateSafePoint": @"I thread SPU non hanno raggiunto un punto sicuro. Riprova fuori dalle scene filmate.",
        @"stateVideoActive": @"Una scena video attiva non può essere acquisita in sicurezza. Terminala o saltala.",
        @"stateInvalid": @"Questo stato non è valido o compatibile con questo core RPCS3.",
        @"stateMissing": @"Lo stato selezionato non è stato trovato.", @"stateWriteFailed": @"RPCS3 non ha potuto scrivere lo stato. Lo slot precedente è stato conservato.",
        @"stateBusy": @"È già in corso un’altra operazione di salvataggio.", @"stateUnknown": @"RPCS3 non ha potuto completare l’operazione.",
        @"stateFreshRestart": @"Impossibile caricare lo stato; il gioco è stato riavviato normalmente.",
      }},
      @"pt": @{{
        @"state": @"Estado de gravação", @"states": @"Estados de gravação",
        @"slot": @"Espaço", @"emptySlot": @"Vazio", @"overwrite": @"Substituir",
        @"overwriteTitle": @"Substituir o estado?", @"overwriteMessage": @"O espaço %ld já contém um estado. O ficheiro anterior será substituído de forma atómica.",
        @"stretch": @"Formato do ecrã", @"stretchTitle": @"Formato do ecrã",
        @"stretchMessage": @"O jogo será reiniciado e a definição só será aplicada ao Game ID atual.",
        @"normal": @"Proporção original", @"stretched": @"Esticar para preencher o ecrã",
        @"stateSafePoint": @"Os threads SPU não atingiram um ponto seguro. Tente fora de uma cena ativa.",
        @"stateVideoActive": @"Uma cena de vídeo ativa não pode ser capturada em segurança. Termine-a ou ignore-a.",
        @"stateInvalid": @"Este estado é inválido ou incompatível com este núcleo RPCS3.", @"stateMissing": @"O estado selecionado não foi encontrado.",
        @"stateWriteFailed": @"O RPCS3 não conseguiu gravar o estado. O espaço anterior foi preservado.",
        @"stateBusy": @"Já existe outra operação de estado em curso.", @"stateUnknown": @"O RPCS3 não conseguiu concluir a operação.",
        @"stateFreshRestart": @"Não foi possível carregar o estado; o jogo foi reiniciado normalmente.",
      }},
      @"id": @{{
        @"state": @"Status simpan", @"states": @"Status simpan",
        @"slot": @"Slot", @"emptySlot": @"Kosong", @"overwrite": @"Timpa",
        @"overwriteTitle": @"Timpa status simpan?", @"overwriteMessage": @"Slot %ld sudah berisi status. Berkas sebelumnya akan diganti secara atomik.",
        @"stretch": @"Format layar", @"stretchTitle": @"Format layar",
        @"stretchMessage": @"Game akan dimulai ulang dan setelan hanya berlaku untuk Game ID saat ini.",
        @"normal": @"Rasio aspek asli", @"stretched": @"Regangkan memenuhi layar",
        @"stateSafePoint": @"Thread SPU tidak mencapai titik aman. Coba lagi di luar adegan sinematik aktif.",
        @"stateVideoActive": @"Adegan video aktif tidak dapat disimpan dengan aman. Selesaikan atau lewati dahulu.",
        @"stateInvalid": @"Status ini tidak valid atau tidak kompatibel dengan inti RPCS3 ini.", @"stateMissing": @"Status yang dipilih tidak ditemukan.",
        @"stateWriteFailed": @"RPCS3 tidak dapat menulis status. Slot sebelumnya dipertahankan.",
        @"stateBusy": @"Operasi status lain sedang berjalan.", @"stateUnknown": @"RPCS3 tidak dapat menyelesaikan operasi status.",
        @"stateFreshRestart": @"Status tidak dapat dimuat; game dimulai ulang secara normal.",
      }},
      @"ru": @{{
        @"state": @"Сохранение состояния", @"states": @"Сохранения состояния",
        @"slot": @"Ячейка", @"emptySlot": @"Пусто", @"overwrite": @"Перезаписать",
        @"overwriteTitle": @"Перезаписать состояние?", @"overwriteMessage": @"Ячейка %ld уже содержит состояние. Предыдущий файл будет заменён атомарно.",
        @"stretch": @"Формат экрана", @"stretchTitle": @"Формат экрана",
        @"stretchMessage": @"Игра перезапустится; настройка применяется только к текущему Game ID.",
        @"normal": @"Исходное соотношение сторон", @"stretched": @"Растянуть на весь экран",
        @"stateSafePoint": @"Потоки SPU не достигли безопасной точки. Повторите вне активной заставки.",
        @"stateVideoActive": @"Активную видеозаставку нельзя безопасно сохранить. Завершите или пропустите её.",
        @"stateInvalid": @"Это состояние повреждено или несовместимо с данным ядром RPCS3.", @"stateMissing": @"Выбранное состояние не найдено.",
        @"stateWriteFailed": @"RPCS3 не удалось записать состояние. Предыдущая ячейка сохранена.",
        @"stateBusy": @"Другая операция сохранения уже выполняется.", @"stateUnknown": @"RPCS3 не удалось завершить операцию.",
        @"stateFreshRestart": @"Состояние не загрузилось; игра была запущена заново.",
      }},
      @"ja": @{{
        @"state": @"セーブステート", @"states": @"セーブステート",
        @"slot": @"スロット", @"emptySlot": @"空", @"overwrite": @"上書き",
        @"overwriteTitle": @"セーブステートを上書きしますか？", @"overwriteMessage": @"スロット%ldには既存のステートがあります。以前のファイルを安全に置き換えます。",
        @"stretch": @"画面形式", @"stretchTitle": @"画面形式",
        @"stretchMessage": @"現在のゲームIDのみに適用するため、ゲームを再起動します。",
        @"normal": @"元のアスペクト比", @"stretched": @"画面全体に引き伸ばす",
        @"stateSafePoint": @"SPUスレッドが安全な地点に到達しませんでした。ムービー中を避けて再試行してください。",
        @"stateVideoActive": @"再生中のムービーは安全に保存できません。終了またはスキップして再試行してください。",
        @"stateInvalid": @"このステートは無効か、このRPCS3コアと互換性がありません。", @"stateMissing": @"選択したステートが見つかりません。",
        @"stateWriteFailed": @"RPCS3はステートを書き込めませんでした。以前のスロットは保持されています。",
        @"stateBusy": @"別のステート操作が実行中です。", @"stateUnknown": @"RPCS3はステート操作を完了できませんでした。",
        @"stateFreshRestart": @"ステートを読み込めなかったため、ゲームを通常起動しました。",
      }},
      @"ko": @{{
        @"state": @"저장 상태", @"states": @"저장 상태",
        @"slot": @"슬롯", @"emptySlot": @"비어 있음", @"overwrite": @"덮어쓰기",
        @"overwriteTitle": @"저장 상태를 덮어쓸까요?", @"overwriteMessage": @"슬롯 %ld에 상태가 있습니다. 이전 파일을 원자적으로 교체합니다.",
        @"stretch": @"화면 형식", @"stretchTitle": @"화면 형식",
        @"stretchMessage": @"현재 게임 ID에만 적용하기 위해 게임을 다시 시작합니다.",
        @"normal": @"원래 화면 비율", @"stretched": @"화면에 맞게 늘리기",
        @"stateSafePoint": @"SPU 스레드가 안전 지점에 도달하지 못했습니다. 영상 장면 밖에서 다시 시도하세요.",
        @"stateVideoActive": @"재생 중인 영상은 안전하게 저장할 수 없습니다. 끝내거나 건너뛴 뒤 다시 시도하세요.",
        @"stateInvalid": @"이 상태는 잘못되었거나 현재 RPCS3 코어와 호환되지 않습니다.", @"stateMissing": @"선택한 상태를 찾을 수 없습니다.",
        @"stateWriteFailed": @"RPCS3가 상태를 쓰지 못했습니다. 이전 슬롯은 보존되었습니다.",
        @"stateBusy": @"다른 상태 작업이 이미 진행 중입니다.", @"stateUnknown": @"RPCS3가 상태 작업을 완료하지 못했습니다.",
        @"stateFreshRestart": @"상태를 불러오지 못해 게임을 정상적으로 다시 시작했습니다.",
      }},
      @"zh": @{{
        @"state": @"即时存档", @"states": @"即时存档",
        @"slot": @"槽位", @"emptySlot": @"空", @"overwrite": @"覆盖",
        @"overwriteTitle": @"覆盖即时存档？", @"overwriteMessage": @"槽位 %ld 已有存档。旧文件将以原子方式替换。",
        @"stretch": @"屏幕格式", @"stretchTitle": @"屏幕格式",
        @"stretchMessage": @"游戏将重启，此设置仅应用于当前游戏 ID。",
        @"normal": @"原始宽高比", @"stretched": @"拉伸至全屏",
        @"stateSafePoint": @"SPU 线程未到达安全点。请在非过场动画期间重试。",
        @"stateVideoActive": @"无法安全保存正在播放的视频过场。请结束或跳过后重试。",
        @"stateInvalid": @"此存档无效或与当前 RPCS3 核心不兼容。", @"stateMissing": @"找不到所选存档。",
        @"stateWriteFailed": @"RPCS3 无法写入存档。原槽位已保留。", @"stateBusy": @"已有其他存档操作正在进行。",
        @"stateUnknown": @"RPCS3 无法完成存档操作。", @"stateFreshRestart": @"无法加载存档；游戏已正常重启。",
      }},
      @"zh_Hant": @{{
        @"state": @"即時存檔", @"states": @"即時存檔",
        @"slot": @"欄位", @"emptySlot": @"空白", @"overwrite": @"覆寫",
        @"overwriteTitle": @"覆寫即時存檔？", @"overwriteMessage": @"欄位 %ld 已有存檔。舊檔案將以不可分割方式取代。",
        @"stretch": @"螢幕格式", @"stretchTitle": @"螢幕格式",
        @"stretchMessage": @"遊戲將重新啟動，此設定只套用於目前的遊戲 ID。",
        @"normal": @"原始長寬比", @"stretched": @"拉伸至全螢幕",
        @"stateSafePoint": @"SPU 執行緒未到達安全點。請在非過場動畫期間重試。",
        @"stateVideoActive": @"無法安全儲存正在播放的影片過場。請結束或略過後再試。",
        @"stateInvalid": @"此存檔無效或與目前的 RPCS3 核心不相容。", @"stateMissing": @"找不到所選存檔。",
        @"stateWriteFailed": @"RPCS3 無法寫入存檔。原欄位已保留。", @"stateBusy": @"已有其他存檔操作正在進行。",
        @"stateUnknown": @"RPCS3 無法完成存檔操作。", @"stateFreshRestart": @"無法載入存檔；遊戲已正常重新啟動。",
      }},
    }};
  }});
  return values;
}}
}}

NSString* RPCS3CanonicalLocale(NSString* identifier) {{
'''
    text = replace_once(text, anchor, translations, "Build 256 translations")
    old_lookup = """  NSDictionary* all = Translations();
  NSString* locale = RPCS3CanonicalLocale(localeIdentifier);
  return all[locale][key] ?: all[@"en"][key] ?: key;
"""
    new_lookup = """  NSDictionary* all = Translations();
  NSDictionary* build256 = Build256Translations();
  NSString* locale = RPCS3CanonicalLocale(localeIdentifier);
  return build256[locale][key] ?: build256[@"en"][key] ?: all[locale][key] ?: all[@"en"][key] ?: key;
"""
    text = replace_once(text, old_lookup, new_lookup, "Build 256 lookup")
    path.write_text(text)


def patch_plugin(root: Path) -> None:
    path = root / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm"
    text = path.read_text()
    if MARKER in text:
        return

    text = replace_once(
        text,
        '  LOAD("neostation_rpcs3_ios_save_state", save_state);\n',
        '  LOAD("neostation_rpcs3_ios_save_state", save_state);\n'
        '  LOAD("neostation_rpcs3_ios_save_state_slot", save_state_slot);\n',
        "slot symbol loader",
    )

    localized_anchor = """- (NSString*)localized:(NSString*)key {
  return RPCS3LocalizedString(key, self.activeUiLocale);
}
"""
    localized_patch = f"""- (NSString*)localized:(NSString*)key {{
  return RPCS3LocalizedString(key, self.activeUiLocale);
}}

// {MARKER}: do not leak Core-owned English strings into localized alerts.
- (NSString*)localizedSavestateError:(NSString*)message {{
  NSString* lower = (message ?: @"").lowercaseString;
  if ([lower containsString:@"safe point"] || [lower containsString:@"spu threads"]) return [self localized:@"stateSafePoint"];
  if ([lower containsString:@"video decoder"] || [lower containsString:@"vdec"] || [lower containsString:@"cutscene"]) return [self localized:@"stateVideoActive"];
  if ([lower containsString:@"not found"] || [lower containsString:@"missing"]) return [self localized:@"stateMissing"];
  if ([lower containsString:@"in progress"] || [lower containsString:@"already running"]) return [self localized:@"stateBusy"];
  if ([lower containsString:@"write"] || [lower containsString:@"storage"] || [lower containsString:@"temporary file"]) return [self localized:@"stateWriteFailed"];
  if ([lower containsString:@"invalid"] || [lower containsString:@"unsupported"] || [lower containsString:@"compatible"]) return [self localized:@"stateInvalid"];
  return [self localized:@"stateUnknown"];
}}
"""
    text = replace_once(text, localized_anchor, localized_patch, "localized errors")

    resolution_end = """  [controller presentViewController:alert animated:YES completion:nil];
}

// NEOSTATION_SAVESTATE_PROGRESS_V1
"""
    stretch_methods = """  [controller presentViewController:alert animated:YES completion:nil];
}

- (void)applyStretchMode:(BOOL)stretched {
  NSString* titleId = [self.activeTitleId copy];
  if (!titleId.length) return;
  dispatch_async(_runtimeQueue, ^{
    rpcs3_ios_status status = self->_api.stop_emulation();
    if (status == 0) status = self->_api.set_game_setting(
        titleId.UTF8String, "gpu.stretch_to_display", stretched ? "true" : "false");
    if (status == 0) status = self->_api.boot_game(titleId.UTF8String, NULL);
    if (status != 0) [self showMessage:@"RPCS3" message:[self lastError]];
    else RPCS3Diagnostic(@"game_stretch", [NSString stringWithFormat:@"%@ = %d", titleId, stretched]);
  });
}

- (void)showStretchMenu {
  RPCS3GameViewController* controller = self.gameController;
  if (!controller || !self.activeTitleId.length || controller.presentedViewController) return;
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self localized:@"stretchTitle"]
      message:[self localized:@"stretchMessage"] preferredStyle:UIAlertControllerStyleAlert];
  __weak Rpcs3InternalBridgePlugin* weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"normal"] style:UIAlertActionStyleDefault
      handler:^(__unused UIAlertAction* action) { [weakSelf applyStretchMode:NO]; }]];
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"stretched"] style:UIAlertActionStyleDefault
      handler:^(__unused UIAlertAction* action) { [weakSelf applyStretchMode:YES]; }]];
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
  [controller presentViewController:alert animated:YES completion:nil];
}

// NEOSTATION_SAVESTATE_PROGRESS_V1
"""
    text = replace_once(text, resolution_end, stretch_methods, "stretch menu")

    text = replace_once(
        text,
        '        [NSString stringWithFormat:@"%@\\n%@", [self localized:@"stateFailed"], message ?: @""];\n',
        '        [NSString stringWithFormat:@"%@\\n%@", [self localized:@"stateFailed"], [self localizedSavestateError:message]];\n',
        "localized save failure",
    )

    save_start = text.index("- (void)saveCurrentState {")
    menu_start = text.index("- (void)showGameMenu {", save_start)
    replacement = r'''- (NSInteger)slotForSavestateIdentifier:(NSString*)identifier titleId:(NSString*)titleId {
  NSString* prefix = [NSString stringWithFormat:@"%@_1_", titleId ?: @""];
  if (!identifier.length || !titleId.length || ![identifier hasPrefix:prefix]) return NSNotFound;
  NSRange suffix = [identifier rangeOfString:@".SAVESTAT"];
  if (suffix.location == NSNotFound || suffix.location <= prefix.length) return NSNotFound;
  NSString* number = [identifier substringWithRange:NSMakeRange(prefix.length, suffix.location - prefix.length)];
  NSScanner* scanner = [NSScanner scannerWithString:number];
  NSInteger zeroBased = -1;
  if (![scanner scanInteger:&zeroBased] || !scanner.isAtEnd || zeroBased < 0 || zeroBased > 9) return NSNotFound;
  return zeroBased + 1;
}

- (NSDictionary<NSNumber*, NSDictionary*>*)statesBySlot:(NSArray<NSDictionary*>*)states titleId:(NSString*)titleId {
  NSMutableDictionary<NSNumber*, NSDictionary*>* result = [NSMutableDictionary dictionary];
  for (NSDictionary* entry in states) {
    NSInteger slot = [self slotForSavestateIdentifier:entry[@"id"] titleId:titleId];
    if (slot != NSNotFound) result[@(slot)] = entry;
  }
  return result;
}

- (void)saveCurrentStateAtSlot:(NSUInteger)slot {
  if (slot < 1 || slot > 10) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    RPCS3GameViewController* controller = self.gameController;
    if (!controller) return;
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self localized:@"state"]
        message:[self localized:@"stateStarted"] preferredStyle:UIAlertControllerStyleAlert];
    alert.modalInPresentation = YES;
    void (^start)(void) = ^{
      [controller presentViewController:alert animated:YES completion:^{
        dispatch_async(self->_runtimeQueue, ^{
          rpcs3_ios_status status = self->_api.save_state_slot ? self->_api.save_state_slot((uint32_t)slot) : -1;
          if (status == 0) {
            RPCS3Diagnostic(@"savestate_save", [NSString stringWithFormat:@"slot=%lu requested; waiting for native completion", (unsigned long)slot]);
            [self pollSavestateAlert:alert];
          } else {
            [self finishSavestateAlert:alert success:NO message:[self lastError]];
          }
        });
      }];
    };
    if (controller.presentedViewController) [controller dismissViewControllerAnimated:NO completion:start];
    else start();
  });
}

- (void)confirmOverwriteSlot:(NSUInteger)slot {
  RPCS3GameViewController* controller = self.gameController;
  if (!controller || controller.presentedViewController) return;
  NSString* message = [NSString stringWithFormat:[self localized:@"overwriteMessage"], (long)slot];
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self localized:@"overwriteTitle"]
      message:message preferredStyle:UIAlertControllerStyleAlert];
  __weak Rpcs3InternalBridgePlugin* weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"overwrite"] style:UIAlertActionStyleDestructive
      handler:^(__unused UIAlertAction* action) { [weakSelf saveCurrentStateAtSlot:slot]; }]];
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
  [controller presentViewController:alert animated:YES completion:nil];
}

- (void)showSaveSavestateMenu {
  NSString* titleId = [self.activeTitleId copy];
  if (!titleId.length) return;
  dispatch_async(_runtimeQueue, ^{
    NSMutableArray<NSDictionary*>* states = [NSMutableArray array];
    rpcs3_ios_status status = self->_api.enumerate_savestates_live
        ? self->_api.enumerate_savestates_live(titleId.UTF8String, RPCS3CollectSavestate, (__bridge void*)states) : -1;
    if (status != 0) { [self showMessage:[self localized:@"states"] message:[self localizedSavestateError:[self lastError]]]; return; }
    NSDictionary<NSNumber*, NSDictionary*>* bySlot = [self statesBySlot:states titleId:titleId];
    dispatch_async(dispatch_get_main_queue(), ^{
      RPCS3GameViewController* controller = self.gameController;
      if (!controller || controller.presentedViewController) return;
      UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self localized:@"createState"]
          message:nil preferredStyle:UIAlertControllerStyleAlert];
      NSDateFormatter* formatter = [NSDateFormatter new];
      formatter.dateStyle = NSDateFormatterShortStyle;
      formatter.timeStyle = NSDateFormatterShortStyle;
      formatter.locale = [NSLocale localeWithLocaleIdentifier:self.activeUiLocale ?: @"en"];
      __weak Rpcs3InternalBridgePlugin* weakSelf = self;
      for (NSUInteger slot = 1; slot <= 10; ++slot) {
        NSDictionary* existing = bySlot[@(slot)];
        int64_t modified = [existing[@"modified"] longLongValue];
        NSString* detail = existing
            ? [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)modified]]
            : [self localized:@"emptySlot"];
        NSString* label = [NSString stringWithFormat:@"%@ %lu · %@", [self localized:@"slot"], (unsigned long)slot, detail];
        [alert addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (existing) [weakSelf confirmOverwriteSlot:slot];
            else [weakSelf saveCurrentStateAtSlot:slot];
          });
        }]];
      }
      [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
      [controller presentViewController:alert animated:YES completion:nil];
    });
  });
}

- (void)loadSavestateIdentifier:(NSString*)identifier {
  if (!identifier.length) return;
  dispatch_async(_runtimeQueue, ^{
    NSString* titleId = [self.activeTitleId copy];
    if (!titleId.length) return;
    rpcs3_ios_status status = self->_api.stop_emulation();
    if (status == 0) status = self->_api.boot_game(titleId.UTF8String, identifier.UTF8String);
    if (status != 0) {
      NSString* originalError = [self lastError];
      // A rejected/corrupt state must not strand the user on a black surface.
      // Restore the normal title after preserving the original diagnostic.
      if (self->_api.stop_emulation) self->_api.stop_emulation();
      rpcs3_ios_status recovery = self->_api.boot_game(titleId.UTF8String, NULL);
      NSString* message = [self localizedSavestateError:originalError];
      if (recovery == 0) message = [NSString stringWithFormat:@"%@\n%@", message, [self localized:@"stateFreshRestart"]];
      [self showMessage:[self localized:@"state"] message:message];
      RPCS3Diagnostic(@"savestate_load_failed", [NSString stringWithFormat:@"%@ recovery=%d original=%@", identifier, recovery, originalError]);
    } else RPCS3Diagnostic(@"savestate_load", identifier);
  });
}

- (void)showLoadSavestateMenu {
  NSString* titleId = [self.activeTitleId copy];
  if (!titleId.length) return;
  dispatch_async(_runtimeQueue, ^{
    NSMutableArray<NSDictionary*>* states = [NSMutableArray array];
    rpcs3_ios_status status = self->_api.enumerate_savestates_live
        ? self->_api.enumerate_savestates_live(titleId.UTF8String, RPCS3CollectSavestate, (__bridge void*)states) : -1;
    if (status != 0) { [self showMessage:[self localized:@"states"] message:[self localizedSavestateError:[self lastError]]]; return; }
    NSDictionary<NSNumber*, NSDictionary*>* bySlot = [self statesBySlot:states titleId:titleId];
    dispatch_async(dispatch_get_main_queue(), ^{
      RPCS3GameViewController* controller = self.gameController;
      if (!controller || controller.presentedViewController) return;
      if (!bySlot.count) { [self showMessage:[self localized:@"states"] message:[self localized:@"noStates"]]; return; }
      UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self localized:@"loadState"]
          message:nil preferredStyle:UIAlertControllerStyleAlert];
      NSDateFormatter* formatter = [NSDateFormatter new];
      formatter.dateStyle = NSDateFormatterShortStyle;
      formatter.timeStyle = NSDateFormatterMediumStyle;
      formatter.locale = [NSLocale localeWithLocaleIdentifier:self.activeUiLocale ?: @"en"];
      __weak Rpcs3InternalBridgePlugin* weakSelf = self;
      for (NSUInteger slot = 1; slot <= 10; ++slot) {
        NSDictionary* entry = bySlot[@(slot)];
        if (!entry) continue;
        NSString* identifier = entry[@"id"];
        BOOL compatible = [entry[@"compatible"] boolValue];
        int64_t modified = [entry[@"modified"] longLongValue];
        NSDate* date = modified > 0 ? [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)modified] : nil;
        NSString* dateText = date ? [formatter stringFromDate:date] : [self localized:@"unknownDate"];
        NSString* label = [NSString stringWithFormat:@"%@ %lu · %@%@", [self localized:@"slot"], (unsigned long)slot,
            dateText, compatible ? @"" : [@" · " stringByAppendingString:[self localized:@"incompatible"]]];
        UIAlertAction* action = [UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* selected) {
          if (compatible) [weakSelf loadSavestateIdentifier:identifier];
          else [weakSelf showMessage:[weakSelf localized:@"state"] message:[weakSelf localized:@"incompatibleState"]];
        }];
        [alert addAction:action];
      }
      [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
      [controller presentViewController:alert animated:YES completion:nil];
    });
  });
}

'''
    text = text[:save_start] + replacement + text[menu_start:]

    text = replace_once(
        text,
        """  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"createState"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
    afterMenuDismiss(^{ [weakSelf saveCurrentState]; });
  }]];
""",
        """  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"stretch"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
    afterMenuDismiss(^{ [weakSelf showStretchMenu]; });
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"createState"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
    afterMenuDismiss(^{ [weakSelf showSaveSavestateMenu]; });
  }]];
""",
        "main menu actions",
    )
    path.write_text(text)


def main() -> None:
    if len(sys.argv) > 2:
        raise SystemExit("usage: patch_rpcs3_build256_host.py [repository-root]")
    root = Path(sys.argv[1] if len(sys.argv) == 2 else ".").resolve()
    patch_abi(root)
    patch_localization(root)
    patch_plugin(root)
    print("NeoStation Build 256 RPCS3 host patch: OK")


if __name__ == "__main__":
    main()
