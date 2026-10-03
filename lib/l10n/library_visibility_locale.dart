import 'package:flutter/widgets.dart';

/// User-facing copy in all 12 NeoStation locales.
abstract final class LibraryVisibilityLocale {
  static String localeKey(Locale locale) {
    final tag = locale.languageCode.replaceAll('-', '_').toLowerCase();
    if (tag == 'zh_hant' ||
        tag.startsWith('zh_hant_') ||
        tag == 'zh_tw' ||
        tag == 'zh_hk' ||
        tag == 'zh_mo') {
      return 'zh_Hant';
    }
    final language = tag.split('_').first;
    if (language == 'zh') {
      final country = locale.countryCode?.toUpperCase();
      if (locale.scriptCode?.toLowerCase() == 'hant' ||
          country == 'TW' ||
          country == 'HK' ||
          country == 'MO') {
        return 'zh_Hant';
      }
      return 'zh';
    }
    return values.containsKey(language) ? language : 'en';
  }

  static String text(BuildContext context, String key) =>
      textForLocale(Localizations.localeOf(context), key);

  static String textForLocale(Locale locale, String key) =>
      values[localeKey(locale)]?[key] ?? values['en']?[key] ?? key;

  static String format(
    BuildContext context,
    String key,
    Map<String, Object?> args,
  ) {
    var value = text(context, key);
    for (final item in args.entries) {
      value = value.replaceAll('{${item.key}}', item.value?.toString() ?? '');
    }
    return value;
  }

  static const values = <String, Map<String, String>>{
    "en": {
      "title": "Choose your libraries",
      "description":
          "Show only the consoles you use. You can change this later in Settings.",
      "manage": "Manage console libraries",
      "keepData": "Hiding a library keeps its games, BIOS and saves.",
      "empty": "No console libraries are enabled.",
      "saveFailed": "Could not save your library selection. Try again.",
      "ports": "Ports",
      "continue": "Continue",
      "coreLabel": "Emulator",
      "coreUnavailable":
          "No compatible embedded emulator is included for this console.",
      "coreLoading": "Loading emulator choices…",
      "coreLoadFailed": "Could not load emulator choices. Try again.",
      "externalEngine": "RetroArch — external app",
      "embeddedEngine": "RetroArch — built in",
      "chooseInRetroArch": "Choose the emulator in RetroArch",
    },
    "fr": {
      "title": "Choisissez vos bibliothèques",
      "description":
          "Affichez uniquement les consoles que vous utilisez. Vous pourrez modifier ce choix dans les réglages.",
      "manage": "Gérer les bibliothèques de consoles",
      "keepData":
          "Masquer une bibliothèque conserve ses jeux, BIOS et sauvegardes.",
      "empty": "Aucune bibliothèque de console n’est activée.",
      "saveFailed":
          "Impossible d’enregistrer votre sélection de bibliothèques. Réessayez.",
      "ports": "Ports",
      "continue": "Continuer",
      "coreLabel": "Émulateur",
      "coreUnavailable":
          "Aucun émulateur intégré compatible n’est inclus pour cette console.",
      "coreLoading": "Chargement des émulateurs disponibles…",
      "coreLoadFailed":
          "Impossible de charger les émulateurs disponibles. Réessayez.",
      "externalEngine": "RetroArch — application externe",
      "embeddedEngine": "RetroArch — intégré",
      "chooseInRetroArch": "Choisissez l’émulateur dans RetroArch",
    },
    "es": {
      "title": "Elige tus bibliotecas",
      "description":
          "Muestra solo las consolas que utilizas. Puedes cambiarlo más tarde en Ajustes.",
      "manage": "Gestionar bibliotecas de consolas",
      "keepData":
          "Ocultar una biblioteca conserva sus juegos, BIOS y partidas guardadas.",
      "empty": "No hay bibliotecas de consolas activadas.",
      "saveFailed":
          "No se ha podido guardar tu selección de bibliotecas. Inténtalo de nuevo.",
      "ports": "Ports",
      "continue": "Continuar",
      "coreLabel": "Emulador",
      "coreUnavailable":
          "No se incluye ningún emulador integrado compatible con esta consola.",
      "coreLoading": "Cargando emuladores disponibles…",
      "coreLoadFailed":
          "No se han podido cargar los emuladores disponibles. Inténtalo de nuevo.",
      "externalEngine": "RetroArch — app externa",
      "embeddedEngine": "RetroArch — integrado",
      "chooseInRetroArch": "Elige el emulador en RetroArch",
    },
    "de": {
      "title": "Wähle deine Bibliotheken",
      "description":
          "Zeige nur die Konsolen an, die du nutzt. Du kannst dies später in den Einstellungen ändern.",
      "manage": "Konsolenbibliotheken verwalten",
      "keepData":
          "Beim Ausblenden einer Bibliothek bleiben ihre Spiele, BIOS-Dateien und Spielstände erhalten.",
      "empty": "Keine Konsolenbibliotheken sind aktiviert.",
      "saveFailed":
          "Deine Bibliotheksauswahl konnte nicht gespeichert werden. Versuche es erneut.",
      "ports": "Portierungen",
      "continue": "Weiter",
      "coreLabel": "Emulator",
      "coreUnavailable":
          "Für diese Konsole ist kein kompatibler integrierter Emulator enthalten.",
      "coreLoading": "Emulatorauswahl wird geladen…",
      "coreLoadFailed":
          "Die Emulatorauswahl konnte nicht geladen werden. Versuche es erneut.",
      "externalEngine": "RetroArch — externe App",
      "embeddedEngine": "RetroArch — integriert",
      "chooseInRetroArch": "Wähle den Emulator in RetroArch",
    },
    "it": {
      "title": "Scegli le tue librerie",
      "description":
          "Mostra solo le console che usi. Puoi modificare la scelta in seguito nelle impostazioni.",
      "manage": "Gestisci librerie delle console",
      "keepData":
          "Nascondere una libreria conserva i suoi giochi, BIOS e salvataggi.",
      "empty": "Nessuna libreria di console è attiva.",
      "saveFailed": "Impossibile salvare la selezione delle librerie. Riprova.",
      "ports": "Port",
      "continue": "Continua",
      "coreLabel": "Emulatore",
      "coreUnavailable":
          "Non è incluso alcun emulatore integrato compatibile con questa console.",
      "coreLoading": "Caricamento degli emulatori disponibili…",
      "coreLoadFailed":
          "Impossibile caricare gli emulatori disponibili. Riprova.",
      "externalEngine": "RetroArch — app esterna",
      "embeddedEngine": "RetroArch — integrato",
      "chooseInRetroArch": "Scegli l’emulatore in RetroArch",
    },
    "pt": {
      "title": "Escolha as suas bibliotecas",
      "description":
          "Mostre apenas as consolas que utiliza. Pode alterar esta escolha mais tarde nas definições.",
      "manage": "Gerir bibliotecas de consolas",
      "keepData":
          "Ocultar uma biblioteca mantém os seus jogos, BIOS e ficheiros de gravação.",
      "empty": "Nenhuma biblioteca de consola está ativada.",
      "saveFailed":
          "Não foi possível guardar a seleção de bibliotecas. Tente novamente.",
      "ports": "Ports",
      "continue": "Continuar",
      "coreLabel": "Emulador",
      "coreUnavailable":
          "Não está incluído nenhum emulador integrado compatível com esta consola.",
      "coreLoading": "A carregar os emuladores disponíveis…",
      "coreLoadFailed":
          "Não foi possível carregar os emuladores disponíveis. Tente novamente.",
      "externalEngine": "RetroArch — aplicação externa",
      "embeddedEngine": "RetroArch — integrado",
      "chooseInRetroArch": "Escolha o emulador no RetroArch",
    },
    "ru": {
      "title": "Выберите библиотеки",
      "description":
          "Показывайте только используемые консоли. Позже это можно изменить в настройках.",
      "manage": "Управление библиотеками консолей",
      "keepData": "При скрытии библиотеки её игры, BIOS и сохранения остаются.",
      "empty": "Ни одна библиотека консоли не включена.",
      "saveFailed": "Не удалось сохранить выбор библиотек. Повторите попытку.",
      "ports": "Порты",
      "continue": "Продолжить",
      "coreLabel": "Эмулятор",
      "coreUnavailable":
          "Для этой консоли нет совместимого встроенного эмулятора.",
      "coreLoading": "Загрузка доступных эмуляторов…",
      "coreLoadFailed":
          "Не удалось загрузить доступные эмуляторы. Повторите попытку.",
      "externalEngine": "RetroArch — внешнее приложение",
      "embeddedEngine": "RetroArch — встроенный",
      "chooseInRetroArch": "Выберите эмулятор в RetroArch",
    },
    "id": {
      "title": "Pilih pustaka Anda",
      "description":
          "Tampilkan hanya konsol yang Anda gunakan. Anda dapat mengubahnya nanti di Pengaturan.",
      "manage": "Kelola pustaka konsol",
      "keepData":
          "Menyembunyikan pustaka tetap menyimpan gim, BIOS, dan simpanannya.",
      "empty": "Tidak ada pustaka konsol yang diaktifkan.",
      "saveFailed": "Tidak dapat menyimpan pilihan pustaka. Coba lagi.",
      "ports": "Port",
      "continue": "Lanjutkan",
      "coreLabel": "Emulator",
      "coreUnavailable":
          "Tidak ada emulator terintegrasi yang kompatibel untuk konsol ini.",
      "coreLoading": "Memuat pilihan emulator…",
      "coreLoadFailed": "Tidak dapat memuat pilihan emulator. Coba lagi.",
      "externalEngine": "RetroArch — aplikasi eksternal",
      "embeddedEngine": "RetroArch — terintegrasi",
      "chooseInRetroArch": "Pilih emulator di RetroArch",
    },
    "ja": {
      "title": "ライブラリを選択",
      "description": "使用するコンソールのみ表示します。後から設定で変更できます。",
      "manage": "コンソールのライブラリを管理",
      "keepData": "ライブラリを非表示にしてもゲーム、BIOS、セーブデータは保持されます。",
      "empty": "有効なコンソールのライブラリがありません。",
      "saveFailed": "ライブラリの選択を保存できませんでした。再試行してください。",
      "ports": "移植作品",
      "continue": "続行",
      "coreLabel": "エミュレーター",
      "coreUnavailable": "このコンソールに対応する内蔵エミュレーターは含まれていません。",
      "coreLoading": "エミュレーターの選択肢を読み込み中…",
      "coreLoadFailed": "エミュレーターの選択肢を読み込めませんでした。再試行してください。",
      "externalEngine": "RetroArch — 外部アプリ",
      "embeddedEngine": "RetroArch — 内蔵",
      "chooseInRetroArch": "RetroArch でエミュレーターを選択",
    },
    "ko": {
      "title": "라이브러리 선택",
      "description": "사용하는 콘솔만 표시하세요. 나중에 설정에서 변경할 수 있습니다.",
      "manage": "콘솔 라이브러리 관리",
      "keepData": "라이브러리를 숨겨도 게임, BIOS, 저장 데이터는 유지됩니다.",
      "empty": "활성화된 콘솔 라이브러리가 없습니다.",
      "saveFailed": "라이브러리 선택을 저장하지 못했습니다. 다시 시도하세요.",
      "ports": "이식작",
      "continue": "계속",
      "coreLabel": "에뮬레이터",
      "coreUnavailable": "이 콘솔과 호환되는 내장 에뮬레이터가 포함되어 있지 않습니다.",
      "coreLoading": "에뮬레이터 목록 불러오는 중…",
      "coreLoadFailed": "에뮬레이터 목록을 불러오지 못했습니다. 다시 시도하세요.",
      "externalEngine": "RetroArch — 외부 앱",
      "embeddedEngine": "RetroArch — 내장",
      "chooseInRetroArch": "RetroArch에서 에뮬레이터를 선택하세요",
    },
    "zh": {
      "title": "选择游戏库",
      "description": "只显示您使用的主机。稍后可在设置中更改。",
      "manage": "管理主机游戏库",
      "keepData": "隐藏游戏库会保留其中的游戏、BIOS 和存档。",
      "empty": "未启用任何主机游戏库。",
      "saveFailed": "无法保存游戏库选择。请重试。",
      "ports": "移植游戏",
      "continue": "继续",
      "coreLabel": "模拟器",
      "coreUnavailable": "未包含与此主机兼容的内置模拟器。",
      "coreLoading": "正在载入模拟器选项…",
      "coreLoadFailed": "无法载入模拟器选项。请重试。",
      "externalEngine": "RetroArch — 外部应用",
      "embeddedEngine": "RetroArch — 内置",
      "chooseInRetroArch": "请在 RetroArch 中选择模拟器",
    },
    "zh_Hant": {
      "title": "選擇遊戲庫",
      "description": "只顯示您使用的主機。稍後可在設定中變更。",
      "manage": "管理主機遊戲庫",
      "keepData": "隱藏遊戲庫會保留其中的遊戲、BIOS 和存檔。",
      "empty": "未啟用任何主機遊戲庫。",
      "saveFailed": "無法儲存遊戲庫選擇。請重試。",
      "ports": "移植遊戲",
      "continue": "繼續",
      "coreLabel": "模擬器",
      "coreUnavailable": "未包含與此主機相容的內建模擬器。",
      "coreLoading": "正在載入模擬器選項…",
      "coreLoadFailed": "無法載入模擬器選項。請重試。",
      "externalEngine": "RetroArch — 外部應用程式",
      "embeddedEngine": "RetroArch — 內建",
      "chooseInRetroArch": "請在 RetroArch 中選擇模擬器",
    },
  };
}
