// SPDX-License-Identifier: GPL-3.0-or-later
#import "RPCS3InGameLocalization.h"

namespace {
NSDictionary<NSString*, NSDictionary<NSString*, NSString*>*>* Translations() {
  static NSDictionary<NSString*, NSDictionary<NSString*, NSString*>*>* values;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    values = @{
      @"en": @{
        @"menu": @"RPCS3 Menu", @"performance": @"RPCS3 Performance",
        @"enabled": @"Enabled", @"disabled": @"Disabled", @"ok": @"OK",
        @"cancel": @"Cancel", @"language": @"Language",
        @"languageTitle": @"PS3 Language",
        @"languageRestart": @"The game will restart to apply the language.",
        @"createState": @"Create save state", @"loadState": @"Load save state",
        @"quitGame": @"Quit game", @"state": @"Save state", @"states": @"Save states",
        @"stateStarted": @"Save-state creation started. RPCS3 will resume the game automatically after writing it.",
        @"noStates": @"No save state is available for this game.",
        @"unknownDate": @"unknown date", @"incompatible": @"incompatible",
        @"incompatibleState": @"This save state is not compatible with this RPCS3 core.",
        @"memory": @"Memory", @"frameTime": @"Frame time (ms)",
      },
      @"fr": @{
        @"menu": @"Menu RPCS3", @"performance": @"Performances RPCS3",
        @"enabled": @"Activé", @"disabled": @"Désactivé", @"ok": @"OK",
        @"cancel": @"Annuler", @"language": @"Langue",
        @"languageTitle": @"Langue PS3",
        @"languageRestart": @"Le jeu redémarre pour appliquer la langue.",
        @"createState": @"Créer une savestate", @"loadState": @"Charger une savestate",
        @"quitGame": @"Quitter le jeu", @"state": @"Savestate", @"states": @"Savestates",
        @"stateStarted": @"Création de la savestate lancée. RPCS3 reprend automatiquement la partie après l’écriture.",
        @"noStates": @"Aucune savestate disponible pour ce jeu.",
        @"unknownDate": @"date inconnue", @"incompatible": @"incompatible",
        @"incompatibleState": @"Cette savestate n’est pas compatible avec ce cœur RPCS3.",
        @"memory": @"Mémoire", @"frameTime": @"Temps par image (ms)",
      },
      @"de": @{
        @"menu": @"RPCS3-Menü", @"performance": @"RPCS3-Leistung",
        @"enabled": @"Aktiviert", @"disabled": @"Deaktiviert", @"ok": @"OK",
        @"cancel": @"Abbrechen", @"language": @"Sprache",
        @"languageTitle": @"PS3-Sprache",
        @"languageRestart": @"Das Spiel wird neu gestartet, um die Sprache anzuwenden.",
        @"createState": @"Spielstand erstellen", @"loadState": @"Spielstand laden",
        @"quitGame": @"Spiel beenden", @"state": @"Spielstand", @"states": @"Spielstände",
        @"stateStarted": @"Der Spielstand wird erstellt. RPCS3 setzt das Spiel danach automatisch fort.",
        @"noStates": @"Für dieses Spiel ist kein Spielstand verfügbar.",
        @"unknownDate": @"unbekanntes Datum", @"incompatible": @"inkompatibel",
        @"incompatibleState": @"Dieser Spielstand ist mit diesem RPCS3-Core nicht kompatibel.",
        @"memory": @"Speicher", @"frameTime": @"Bildzeit (ms)",
      },
      @"es": @{
        @"menu": @"Menú de RPCS3", @"performance": @"Rendimiento de RPCS3",
        @"enabled": @"Activado", @"disabled": @"Desactivado", @"ok": @"Aceptar",
        @"cancel": @"Cancelar", @"language": @"Idioma",
        @"languageTitle": @"Idioma de PS3",
        @"languageRestart": @"El juego se reiniciará para aplicar el idioma.",
        @"createState": @"Crear estado de guardado", @"loadState": @"Cargar estado de guardado",
        @"quitGame": @"Salir del juego", @"state": @"Estado de guardado", @"states": @"Estados de guardado",
        @"stateStarted": @"Se inició la creación del estado. RPCS3 reanudará el juego automáticamente al terminar.",
        @"noStates": @"No hay estados de guardado disponibles para este juego.",
        @"unknownDate": @"fecha desconocida", @"incompatible": @"incompatible",
        @"incompatibleState": @"Este estado no es compatible con este núcleo de RPCS3.",
        @"memory": @"Memoria", @"frameTime": @"Tiempo de fotograma (ms)",
      },
      @"it": @{
        @"menu": @"Menu RPCS3", @"performance": @"Prestazioni RPCS3",
        @"enabled": @"Attivato", @"disabled": @"Disattivato", @"ok": @"OK",
        @"cancel": @"Annulla", @"language": @"Lingua",
        @"languageTitle": @"Lingua PS3",
        @"languageRestart": @"Il gioco verrà riavviato per applicare la lingua.",
        @"createState": @"Crea stato di salvataggio", @"loadState": @"Carica stato di salvataggio",
        @"quitGame": @"Esci dal gioco", @"state": @"Stato di salvataggio", @"states": @"Stati di salvataggio",
        @"stateStarted": @"Creazione dello stato avviata. RPCS3 riprenderà automaticamente il gioco al termine.",
        @"noStates": @"Nessuno stato di salvataggio disponibile per questo gioco.",
        @"unknownDate": @"data sconosciuta", @"incompatible": @"incompatibile",
        @"incompatibleState": @"Questo stato non è compatibile con questo core RPCS3.",
        @"memory": @"Memoria", @"frameTime": @"Tempo fotogramma (ms)",
      },
      @"pt": @{
        @"menu": @"Menu do RPCS3", @"performance": @"Desempenho do RPCS3",
        @"enabled": @"Ativado", @"disabled": @"Desativado", @"ok": @"OK",
        @"cancel": @"Cancelar", @"language": @"Idioma",
        @"languageTitle": @"Idioma da PS3",
        @"languageRestart": @"O jogo será reiniciado para aplicar o idioma.",
        @"createState": @"Criar estado de gravação", @"loadState": @"Carregar estado de gravação",
        @"quitGame": @"Sair do jogo", @"state": @"Estado de gravação", @"states": @"Estados de gravação",
        @"stateStarted": @"A criação do estado foi iniciada. O RPCS3 retomará o jogo automaticamente ao terminar.",
        @"noStates": @"Não há estados de gravação disponíveis para este jogo.",
        @"unknownDate": @"data desconhecida", @"incompatible": @"incompatível",
        @"incompatibleState": @"Este estado não é compatível com este núcleo do RPCS3.",
        @"memory": @"Memória", @"frameTime": @"Tempo de fotograma (ms)",
      },
      @"id": @{
        @"menu": @"Menu RPCS3", @"performance": @"Performa RPCS3",
        @"enabled": @"Aktif", @"disabled": @"Nonaktif", @"ok": @"OK",
        @"cancel": @"Batal", @"language": @"Bahasa",
        @"languageTitle": @"Bahasa PS3",
        @"languageRestart": @"Game akan dimulai ulang untuk menerapkan bahasa.",
        @"createState": @"Buat status simpan", @"loadState": @"Muat status simpan",
        @"quitGame": @"Keluar dari game", @"state": @"Status simpan", @"states": @"Status simpan",
        @"stateStarted": @"Pembuatan status simpan dimulai. RPCS3 akan melanjutkan game secara otomatis setelah selesai.",
        @"noStates": @"Tidak ada status simpan untuk game ini.",
        @"unknownDate": @"tanggal tidak diketahui", @"incompatible": @"tidak kompatibel",
        @"incompatibleState": @"Status simpan ini tidak kompatibel dengan inti RPCS3 ini.",
        @"memory": @"Memori", @"frameTime": @"Waktu frame (ms)",
      },
      @"ru": @{
        @"menu": @"Меню RPCS3", @"performance": @"Производительность RPCS3",
        @"enabled": @"Включено", @"disabled": @"Выключено", @"ok": @"ОК",
        @"cancel": @"Отмена", @"language": @"Язык",
        @"languageTitle": @"Язык PS3",
        @"languageRestart": @"Игра будет перезапущена для применения языка.",
        @"createState": @"Создать сохранение состояния", @"loadState": @"Загрузить сохранение состояния",
        @"quitGame": @"Выйти из игры", @"state": @"Сохранение состояния", @"states": @"Сохранения состояния",
        @"stateStarted": @"Создание сохранения начато. RPCS3 автоматически продолжит игру после записи.",
        @"noStates": @"Для этой игры нет сохранений состояния.",
        @"unknownDate": @"дата неизвестна", @"incompatible": @"несовместимо",
        @"incompatibleState": @"Это сохранение несовместимо с данным ядром RPCS3.",
        @"memory": @"Память", @"frameTime": @"Время кадра (мс)",
      },
      @"ja": @{
        @"menu": @"RPCS3メニュー", @"performance": @"RPCS3パフォーマンス",
        @"enabled": @"オン", @"disabled": @"オフ", @"ok": @"OK",
        @"cancel": @"キャンセル", @"language": @"言語",
        @"languageTitle": @"PS3の言語",
        @"languageRestart": @"言語を適用するためゲームを再起動します。",
        @"createState": @"ステートを保存", @"loadState": @"ステートを読み込む",
        @"quitGame": @"ゲームを終了", @"state": @"セーブステート", @"states": @"セーブステート",
        @"stateStarted": @"セーブステートの作成を開始しました。完了後、RPCS3が自動的にゲームを再開します。",
        @"noStates": @"このゲームで利用できるセーブステートはありません。",
        @"unknownDate": @"日付不明", @"incompatible": @"非互換",
        @"incompatibleState": @"このセーブステートは現在のRPCS3コアと互換性がありません。",
        @"memory": @"メモリ", @"frameTime": @"フレーム時間 (ms)",
      },
      @"ko": @{
        @"menu": @"RPCS3 메뉴", @"performance": @"RPCS3 성능",
        @"enabled": @"켜짐", @"disabled": @"꺼짐", @"ok": @"확인",
        @"cancel": @"취소", @"language": @"언어",
        @"languageTitle": @"PS3 언어",
        @"languageRestart": @"언어를 적용하기 위해 게임을 다시 시작합니다.",
        @"createState": @"상태 저장", @"loadState": @"상태 불러오기",
        @"quitGame": @"게임 종료", @"state": @"저장 상태", @"states": @"저장 상태",
        @"stateStarted": @"상태 저장을 시작했습니다. 완료되면 RPCS3가 자동으로 게임을 재개합니다.",
        @"noStates": @"이 게임에 사용할 수 있는 저장 상태가 없습니다.",
        @"unknownDate": @"날짜 알 수 없음", @"incompatible": @"호환되지 않음",
        @"incompatibleState": @"이 저장 상태는 현재 RPCS3 코어와 호환되지 않습니다.",
        @"memory": @"메모리", @"frameTime": @"프레임 시간 (ms)",
      },
      @"zh": @{
        @"menu": @"RPCS3 菜单", @"performance": @"RPCS3 性能",
        @"enabled": @"已开启", @"disabled": @"已关闭", @"ok": @"确定",
        @"cancel": @"取消", @"language": @"语言",
        @"languageTitle": @"PS3 语言",
        @"languageRestart": @"游戏将重新启动以应用语言。",
        @"createState": @"创建即时存档", @"loadState": @"加载即时存档",
        @"quitGame": @"退出游戏", @"state": @"即时存档", @"states": @"即时存档",
        @"stateStarted": @"已开始创建即时存档。写入完成后 RPCS3 将自动继续游戏。",
        @"noStates": @"此游戏没有可用的即时存档。",
        @"unknownDate": @"未知日期", @"incompatible": @"不兼容",
        @"incompatibleState": @"此即时存档与当前 RPCS3 核心不兼容。",
        @"memory": @"内存", @"frameTime": @"帧时间 (ms)",
      },
      @"zh_Hant": @{
        @"menu": @"RPCS3 選單", @"performance": @"RPCS3 效能",
        @"enabled": @"已開啟", @"disabled": @"已關閉", @"ok": @"確定",
        @"cancel": @"取消", @"language": @"語言",
        @"languageTitle": @"PS3 語言",
        @"languageRestart": @"遊戲將重新啟動以套用語言。",
        @"createState": @"建立即時存檔", @"loadState": @"載入即時存檔",
        @"quitGame": @"離開遊戲", @"state": @"即時存檔", @"states": @"即時存檔",
        @"stateStarted": @"已開始建立即時存檔。寫入完成後 RPCS3 將自動繼續遊戲。",
        @"noStates": @"此遊戲沒有可用的即時存檔。",
        @"unknownDate": @"未知日期", @"incompatible": @"不相容",
        @"incompatibleState": @"此即時存檔與目前的 RPCS3 核心不相容。",
        @"memory": @"記憶體", @"frameTime": @"影格時間 (ms)",
      },
    };
  });
  return values;
}
}

NSString* RPCS3CanonicalLocale(NSString* identifier) {
  NSString* normalized = [[identifier ?: @"en"
      stringByReplacingOccurrencesOfString:@"-" withString:@"_"] lowercaseString];
  if ([normalized hasPrefix:@"zh_hant"] || [normalized hasPrefix:@"zh_tw"] ||
      [normalized hasPrefix:@"zh_hk"] || [normalized hasPrefix:@"zh_mo"]) {
    return @"zh_Hant";
  }
  NSString* language = [normalized componentsSeparatedByString:@"_"].firstObject ?: @"en";
  static NSSet<NSString*>* supported;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    supported = [NSSet setWithArray:@[@"de", @"en", @"es", @"fr", @"id", @"it",
                                      @"ja", @"ko", @"pt", @"ru", @"zh"]];
  });
  return [supported containsObject:language] ? language : @"en";
}

NSString* RPCS3LocalizedString(NSString* key, NSString* localeIdentifier) {
  NSDictionary* all = Translations();
  NSString* locale = RPCS3CanonicalLocale(localeIdentifier);
  return all[locale][key] ?: all[@"en"][key] ?: key;
}
