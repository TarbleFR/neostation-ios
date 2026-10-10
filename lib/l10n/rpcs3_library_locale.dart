import 'package:flutter/widgets.dart';

/// Localized copy for the RPCS3 iOS library integration.
abstract final class Rpcs3LibraryLocale {
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

  static String sync(BuildContext context) => _lookup(_sync, context);

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
