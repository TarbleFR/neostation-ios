import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Localized copy for the RPCS3 iOS library integration.
abstract final class Rpcs3LibraryLocale {
  static const Map<String, String> _needsLink = {
    'de': 'Verknüpfe den RPCS3-Ordner „Data“, um die installierte PS3-Bibliothek zu importieren.',
    'en': 'Link RPCS3’s Data folder to import its installed PS3 library.',
    'es': 'Vincula la carpeta Data de RPCS3 para importar su biblioteca de PS3 instalada.',
    'fr': 'Liez le dossier Data de RPCS3 pour importer sa bibliothèque PS3 installée.',
    'id': 'Tautkan folder Data RPCS3 untuk mengimpor pustaka PS3 yang terpasang.',
    'it': 'Collega la cartella Data di RPCS3 per importare la libreria PS3 installata.',
    'ja': 'RPCS3 の Data フォルダをリンクして、インストール済みの PS3 ライブラリを読み込みます。',
    'ko': 'RPCS3의 Data 폴더를 연결하여 설치된 PS3 라이브러리를 가져옵니다.',
    'pt': 'Vincule a pasta Data do RPCS3 para importar a biblioteca PS3 instalada.',
    'ru': 'Подключите папку Data RPCS3, чтобы импортировать установленную библиотеку PS3.',
    'zh': '连接 RPCS3 的 Data 文件夹以导入已安装的 PS3 游戏库。',
    'zh_Hant': '連結 RPCS3 的 Data 資料夾以匯入已安裝的 PS3 遊戲庫。',
  };

  static const Map<String, String> _needsSync = {
    'de': 'RPCS3 Data ist verknüpft. Synchronisiere, um installierte Spiele einzulesen.',
    'en': 'RPCS3 Data is linked. Sync to read the installed games.',
    'es': 'RPCS3 Data está vinculado. Sincroniza para leer los juegos instalados.',
    'fr': 'RPCS3 Data est lié. Synchronisez pour lire les jeux installés.',
    'id': 'RPCS3 Data sudah tertaut. Sinkronkan untuk membaca game yang terpasang.',
    'it': 'RPCS3 Data è collegato. Sincronizza per leggere i giochi installati.',
    'ja': 'RPCS3 Data はリンク済みです。同期してインストール済みゲームを読み込みます。',
    'ko': 'RPCS3 Data가 연결되었습니다. 설치된 게임을 읽으려면 동기화하세요.',
    'pt': 'RPCS3 Data está vinculado. Sincronize para ler os jogos instalados.',
    'ru': 'RPCS3 Data подключена. Выполните синхронизацию для чтения установленных игр.',
    'zh': 'RPCS3 Data 已连接。同步以读取已安装的游戏。',
    'zh_Hant': 'RPCS3 Data 已連結。同步以讀取已安裝的遊戲。',
  };

  static const Map<String, String> _sync = {
    'de': 'Synchronisieren',
    'en': 'Sync',
    'es': 'Sincronizar',
    'fr': 'Synchroniser',
    'id': 'Sinkronkan',
    'it': 'Sincronizza',
    'ja': '同期',
    'ko': '동기화',
    'pt': 'Sincronizar',
    'ru': 'Синхронизировать',
    'zh': '同步',
    'zh_Hant': '同步',
  };

  static const Map<String, String> _noGames = {
    'de': 'Keine RPCS3-Spiele gefunden. Wähle in Dateien „RPCS3 > Data“ und prüfe, dass die Spiele zuerst in RPCS3 erscheinen.',
    'en': 'No RPCS3 games were found. Select Files > RPCS3 > Data and make sure the games appear in RPCS3 first.',
    'es': 'No se encontraron juegos de RPCS3. Selecciona Archivos > RPCS3 > Data y comprueba que los juegos aparezcan primero en RPCS3.',
    'fr': 'Aucun jeu RPCS3 trouvé. Sélectionnez Fichiers > RPCS3 > Data et vérifiez d’abord que les jeux apparaissent dans RPCS3.',
    'id': 'Tidak ada game RPCS3 yang ditemukan. Pilih Files > RPCS3 > Data dan pastikan game sudah muncul di RPCS3.',
    'it': 'Nessun gioco RPCS3 trovato. Seleziona File > RPCS3 > Data e verifica prima che i giochi compaiano in RPCS3.',
    'ja': 'RPCS3 ゲームが見つかりません。ファイル > RPCS3 > Data を選び、先に RPCS3 側でゲームが表示されることを確認してください。',
    'ko': 'RPCS3 게임을 찾지 못했습니다. 파일 > RPCS3 > Data를 선택하고 먼저 RPCS3에서 게임이 보이는지 확인하세요.',
    'pt': 'Nenhum jogo RPCS3 foi encontrado. Selecione Arquivos > RPCS3 > Data e confirme primeiro que os jogos aparecem no RPCS3.',
    'ru': 'Игры RPCS3 не найдены. Выберите «Файлы > RPCS3 > Data» и сначала убедитесь, что игры отображаются в RPCS3.',
    'zh': '未找到 RPCS3 游戏。请选择“文件 > RPCS3 > Data”，并先确认游戏能在 RPCS3 中显示。',
    'zh_Hant': '未找到 RPCS3 遊戲。請選擇「檔案 > RPCS3 > Data」，並先確認遊戲能在 RPCS3 中顯示。',
  };

  static const Map<String, String> _invalidFolder = {
    'de': 'Wähle den Ordner „Data“ unter Dateien > RPCS3 > Data.',
    'en': 'Select the Data folder under Files > RPCS3 > Data.',
    'es': 'Selecciona la carpeta Data en Archivos > RPCS3 > Data.',
    'fr': 'Sélectionnez le dossier Data dans Fichiers > RPCS3 > Data.',
    'id': 'Pilih folder Data di Files > RPCS3 > Data.',
    'it': 'Seleziona la cartella Data in File > RPCS3 > Data.',
    'ja': 'ファイル > RPCS3 > Data の Data フォルダを選択してください。',
    'ko': '파일 > RPCS3 > Data에서 Data 폴더를 선택하세요.',
    'pt': 'Selecione a pasta Data em Arquivos > RPCS3 > Data.',
    'ru': 'Выберите папку Data в «Файлы > RPCS3 > Data».',
    'zh': '请选择“文件 > RPCS3 > Data”中的 Data 文件夹。',
    'zh_Hant': '請選擇「檔案 > RPCS3 > Data」中的 Data 資料夾。',
  };

  static const Map<String, String> _syncFailed = {
    'de': 'RPCS3-Synchronisierung fehlgeschlagen: {error}',
    'en': 'RPCS3 library sync failed: {error}',
    'es': 'Falló la sincronización de RPCS3: {error}',
    'fr': 'Échec de la synchronisation RPCS3 : {error}',
    'id': 'Sinkronisasi pustaka RPCS3 gagal: {error}',
    'it': 'Sincronizzazione RPCS3 non riuscita: {error}',
    'ja': 'RPCS3 ライブラリの同期に失敗しました：{error}',
    'ko': 'RPCS3 라이브러리 동기화 실패: {error}',
    'pt': 'Falha ao sincronizar a biblioteca RPCS3: {error}',
    'ru': 'Не удалось синхронизировать библиотеку RPCS3: {error}',
    'zh': 'RPCS3 游戏库同步失败：{error}',
    'zh_Hant': 'RPCS3 遊戲庫同步失敗：{error}',
  };

  static const Map<String, String> _launchUnavailable = {
    'de': 'RPCS3-Spiele können angezeigt werden, aber der direkte Spielstart ist noch nicht aktiviert.',
    'en': 'RPCS3 games can be displayed, but direct game launching is not enabled yet.',
    'es': 'Los juegos de RPCS3 pueden mostrarse, pero el inicio directo aún no está habilitado.',
    'fr': 'Les jeux RPCS3 peuvent être affichés, mais leur lancement direct n’est pas encore activé.',
    'id': 'Game RPCS3 dapat ditampilkan, tetapi peluncuran langsung belum diaktifkan.',
    'it': 'I giochi RPCS3 possono essere visualizzati, ma l’avvio diretto non è ancora attivo.',
    'ja': 'RPCS3 ゲームは表示できますが、ゲームの直接起動はまだ有効ではありません。',
    'ko': 'RPCS3 게임은 표시할 수 있지만 직접 실행은 아직 활성화되지 않았습니다.',
    'pt': 'Os jogos RPCS3 podem ser exibidos, mas a inicialização direta ainda não está ativada.',
    'ru': 'Игры RPCS3 можно отображать, но прямой запуск пока не включён.',
    'zh': '可以显示 RPCS3 游戏，但尚未启用直接启动。',
    'zh_Hant': '可以顯示 RPCS3 遊戲，但尚未啟用直接啟動。',
  };

  static const Map<String, String> _launchFailed = {
    'de': 'RPCS3 konnte nicht über StikDebug gestartet werden. Prüfe rpcs3_launch_debug.txt in NeoStation.',
    'en': 'RPCS3 could not be started through StikDebug. Check rpcs3_launch_debug.txt in NeoStation.',
    'es': 'No se pudo iniciar RPCS3 mediante StikDebug. Consulta rpcs3_launch_debug.txt en NeoStation.',
    'fr': 'RPCS3 n’a pas pu être lancé via StikDebug. Consultez rpcs3_launch_debug.txt dans NeoStation.',
    'id': 'RPCS3 tidak dapat dijalankan melalui StikDebug. Periksa rpcs3_launch_debug.txt di NeoStation.',
    'it': 'Impossibile avviare RPCS3 tramite StikDebug. Controlla rpcs3_launch_debug.txt in NeoStation.',
    'ja': 'StikDebug 経由で RPCS3 を起動できませんでした。NeoStation の rpcs3_launch_debug.txt を確認してください。',
    'ko': 'StikDebug를 통해 RPCS3를 실행하지 못했습니다. NeoStation의 rpcs3_launch_debug.txt를 확인하세요.',
    'pt': 'Não foi possível iniciar o RPCS3 pelo StikDebug. Verifique rpcs3_launch_debug.txt no NeoStation.',
    'ru': 'Не удалось запустить RPCS3 через StikDebug. Проверьте rpcs3_launch_debug.txt в NeoStation.',
    'zh': '无法通过 StikDebug 启动 RPCS3。请查看 NeoStation 中的 rpcs3_launch_debug.txt。',
    'zh_Hant': '無法透過 StikDebug 啟動 RPCS3。請查看 NeoStation 中的 rpcs3_launch_debug.txt。',
  };

  static String statusNeedsLink(BuildContext context) =>
      _lookup(_needsLink, context);
  static String statusNeedsSync(BuildContext context) =>
      _lookup(_needsSync, context);
  static String sync(BuildContext context) => _lookup(_sync, context);
  static String statusSynced(BuildContext context, int count) =>
      statusSyncedForLocale(_localeKey(Localizations.localeOf(context)), count);

  @visibleForTesting
  static String statusSyncedForLocale(String localeKey, int count) {
    return switch (localeKey) {
      'de' => count == 1
          ? 'RPCS3 synchronisiert — 1 PS3-Spiel.'
          : 'RPCS3 synchronisiert — $count PS3-Spiele.',
      'es' => count == 1
          ? 'RPCS3 sincronizado — 1 juego de PS3.'
          : 'RPCS3 sincronizado — $count juegos de PS3.',
      'fr' => count == 1
          ? 'RPCS3 synchronisé — 1 jeu PS3.'
          : 'RPCS3 synchronisé — $count jeux PS3.',
      'id' => 'RPCS3 tersinkron — $count game PS3.',
      'it' => count == 1
          ? 'RPCS3 sincronizzato — 1 gioco PS3.'
          : 'RPCS3 sincronizzato — $count giochi PS3.',
      'ja' => 'RPCS3 同期済み — PS3 ゲーム $count 本。',
      'ko' => 'RPCS3 동기화됨 — PS3 게임 $count개.',
      'pt' => count == 1
          ? 'RPCS3 sincronizado — 1 jogo de PS3.'
          : 'RPCS3 sincronizado — $count jogos PS3.',
      'ru' => 'RPCS3 синхронизирован. Игр PS3: $count.',
      'zh' => 'RPCS3 已同步 — $count 个 PS3 游戏。',
      'zh_Hant' => 'RPCS3 已同步 — $count 個 PS3 遊戲。',
      _ => count == 1
          ? 'RPCS3 synced — 1 PS3 game.'
          : 'RPCS3 synced — $count PS3 games.',
    };
  }

  static String syncComplete(BuildContext context, int count) =>
      syncCompleteForLocale(_localeKey(Localizations.localeOf(context)), count);

  @visibleForTesting
  static String syncCompleteForLocale(String localeKey, int count) {
    return switch (localeKey) {
      'de' => count == 1
          ? 'RPCS3-Bibliothek synchronisiert: 1 Spiel.'
          : 'RPCS3-Bibliothek synchronisiert: $count Spiele.',
      'es' => count == 1
          ? 'Biblioteca RPCS3 sincronizada: 1 juego.'
          : 'Biblioteca RPCS3 sincronizada: $count juegos.',
      'fr' => count == 1
          ? 'Bibliothèque RPCS3 synchronisée : 1 jeu.'
          : 'Bibliothèque RPCS3 synchronisée : $count jeux.',
      'id' => 'Pustaka RPCS3 disinkronkan: $count game.',
      'it' => count == 1
          ? 'Libreria RPCS3 sincronizzata: 1 gioco.'
          : 'Libreria RPCS3 sincronizzata: $count giochi.',
      'ja' => 'RPCS3 ライブラリを同期しました：$count 本。',
      'ko' => 'RPCS3 라이브러리 동기화 완료: 게임 $count개.',
      'pt' => count == 1
          ? 'Biblioteca RPCS3 sincronizada: 1 jogo.'
          : 'Biblioteca RPCS3 sincronizada: $count jogos.',
      'ru' => 'Библиотека RPCS3 синхронизирована. Игр: $count.',
      'zh' => 'RPCS3 游戏库同步完成：$count 个游戏。',
      'zh_Hant' => 'RPCS3 遊戲庫同步完成：$count 個遊戲。',
      _ => count == 1
          ? 'RPCS3 library synced: 1 game.'
          : 'RPCS3 library synced: $count games.',
    };
  }

  static String noGames(BuildContext context) => _lookup(_noGames, context);
  static String invalidFolder(BuildContext context) =>
      _lookup(_invalidFolder, context);
  static String syncFailed(BuildContext context, Object error) =>
      _lookup(_syncFailed, context).replaceFirst('{error}', '$error');
  static String launchUnavailable(BuildContext context) =>
      _lookup(_launchUnavailable, context);
  static String launchFailed(BuildContext context) =>
      _lookup(_launchFailed, context);

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
