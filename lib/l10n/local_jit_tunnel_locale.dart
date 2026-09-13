import 'package:flutter/widgets.dart';

/// Complete localized copy for NeoStation's system-managed local JIT VPN.
abstract final class LocalJitTunnelLocale {
  static const title = 'title';
  static const checking = 'checking';
  static const notAuthorized = 'notAuthorized';
  static const authorized = 'authorized';
  static const active = 'active';
  static const inactive = 'inactive';
  static const connecting = 'connecting';
  static const disconnecting = 'disconnecting';
  static const reasserting = 'reasserting';
  static const unsupported = 'unsupported';
  static const errorStatus = 'errorStatus';
  static const authorizeAction = 'authorizeAction';
  static const enableAction = 'enableAction';
  static const disableAction = 'disableAction';
  static const notAuthorizedDescription = 'notAuthorizedDescription';
  static const authorizedDescription = 'authorizedDescription';
  static const activeDescription = 'activeDescription';
  static const unsupportedDescription = 'unsupportedDescription';
  static const authorizedAndEnabled = 'authorizedAndEnabled';
  static const enabledMessage = 'enabledMessage';
  static const disabledMessage = 'disabledMessage';
  static const permissionDenied = 'permissionDenied';
  static const signingMissing = 'signingMissing';
  static const configurationFailed = 'configurationFailed';
  static const extensionMissing = 'extensionMissing';
  static const vpnConflict = 'vpnConflict';
  static const startFailed = 'startFailed';
  static const stopFailed = 'stopFailed';
  static const timeout = 'timeout';
  static const statusFailed = 'statusFailed';
  static const notConnected = 'notConnected';
  static const genericError = 'genericError';

  static const supportedLocaleKeys = <String>{
    'en',
    'de',
    'es',
    'fr',
    'id',
    'it',
    'ja',
    'ko',
    'pt',
    'ru',
    'zh',
    'zh_Hant',
  };

  static const allKeys = <String>{
    title,
    checking,
    notAuthorized,
    authorized,
    active,
    inactive,
    connecting,
    disconnecting,
    reasserting,
    unsupported,
    errorStatus,
    authorizeAction,
    enableAction,
    disableAction,
    notAuthorizedDescription,
    authorizedDescription,
    activeDescription,
    unsupportedDescription,
    authorizedAndEnabled,
    enabledMessage,
    disabledMessage,
    permissionDenied,
    signingMissing,
    configurationFailed,
    extensionMissing,
    vpnConflict,
    startFailed,
    stopFailed,
    timeout,
    statusFailed,
    notConnected,
    genericError,
  };

  static String get(BuildContext context, String key) =>
      getForLocale(_localeKey(Localizations.localeOf(context)), key);

  static String getForLocale(String localeKey, String key) =>
      _values[localeKey]?[key] ?? _values['en']![key] ?? key;

  static Set<String> missingKeysForLocale(String localeKey) =>
      allKeys.difference(_values[localeKey]?.keys.toSet() ?? const <String>{});

  static String error(BuildContext context, String? code) {
    final value = code ?? '';
    final key = switch (value) {
      'unsupportedPlatform' || 'local_tunnel_unsupported_ios' => unsupported,
      'statusFailed' => statusFailed,
      'notConnected' => notConnected,
      'local_tunnel_permission_denied' => permissionDenied,
      'local_tunnel_signing_missing' => signingMissing,
      'local_tunnel_configuration_failed' => configurationFailed,
      'local_tunnel_extension_missing' => extensionMissing,
      'local_tunnel_vpn_conflict' => vpnConflict,
      'local_tunnel_start_failed' => startFailed,
      'local_tunnel_stop_failed' => stopFailed,
      'local_tunnel_connection_timeout' => timeout,
      _ => genericError,
    };
    return get(context, key);
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
    return supportedLocaleKeys.contains(locale.languageCode)
        ? locale.languageCode
        : 'en';
  }

  static const Map<String, Map<String, String>> _values = {
    'en': {
      title: 'Local JIT VPN',
      checking: 'Checking VPN…',
      notAuthorized: 'VPN not authorized',
      authorized: 'VPN authorized',
      active: 'VPN active',
      inactive: 'VPN disabled',
      connecting: 'Activation in progress…',
      disconnecting: 'Deactivation in progress…',
      reasserting: 'VPN reconnecting…',
      unsupported: 'VPN unavailable',
      errorStatus: 'VPN error',
      authorizeAction: 'Authorize VPN',
      enableAction: 'Enable VPN',
      disableAction: 'Disable VPN',
      notAuthorizedDescription:
          "Authorize NeoStation's on-device JIT tunnel in the native iOS dialog.",
      authorizedDescription:
          'iOS has saved the VPN configuration. Enable it when JIT needs the local device route.',
      activeDescription:
          'On-device only; no Internet traffic is sent through this tunnel.',
      unsupportedDescription:
          'Requires iOS 17.4 or later and a correctly signed Network Extension.',
      authorizedAndEnabled: 'VPN authorized and enabled.',
      enabledMessage: 'VPN enabled.',
      disabledMessage: 'VPN disabled. Its authorization has been retained.',
      permissionDenied:
          'iOS did not authorize the VPN configuration. You can try again.',
      signingMissing:
          "This NeoStation installation was signed without Apple's Network Extension permission. Use an authorized developer profile or LocalDevVPN from the App Store.",
      configurationFailed:
          'iOS could not save or read the VPN configuration.',
      extensionMissing:
          'The local tunnel extension is missing. Reinstall the complete signed IPA.',
      vpnConflict:
          'Another VPN is active. Disable it, then try the NeoStation VPN again.',
      startFailed: 'The VPN could not be activated.',
      stopFailed: 'The VPN could not be disabled cleanly.',
      timeout: 'VPN activation timed out. Check iOS VPN settings and try again.',
      statusFailed: 'The current VPN state could not be refreshed.',
      notConnected: 'The VPN configuration exists but is not connected.',
      genericError: 'An unexpected VPN error occurred.',
    },
    'de': {
      title: 'Lokales JIT-VPN',
      checking: 'VPN wird geprüft…',
      notAuthorized: 'VPN nicht autorisiert',
      authorized: 'VPN autorisiert',
      active: 'VPN aktiv',
      inactive: 'VPN deaktiviert',
      connecting: 'Aktivierung läuft…',
      disconnecting: 'Deaktivierung läuft…',
      reasserting: 'VPN wird erneut verbunden…',
      unsupported: 'VPN nicht verfügbar',
      errorStatus: 'VPN-Fehler',
      authorizeAction: 'VPN autorisieren',
      enableAction: 'VPN aktivieren',
      disableAction: 'VPN deaktivieren',
      notAuthorizedDescription:
          'Autorisiere den lokalen JIT-Tunnel von NeoStation im nativen iOS-Dialog.',
      authorizedDescription:
          'iOS hat die VPN-Konfiguration gespeichert. Aktiviere sie, wenn JIT die lokale Geräteroute benötigt.',
      activeDescription:
          'Nur auf diesem Gerät; über diesen Tunnel wird kein Internetverkehr gesendet.',
      unsupportedDescription:
          'Erfordert iOS 17.4 oder neuer und eine korrekt signierte Network Extension.',
      authorizedAndEnabled: 'VPN wurde autorisiert und aktiviert.',
      enabledMessage: 'VPN wurde aktiviert.',
      disabledMessage: 'VPN wurde deaktiviert. Die Autorisierung bleibt erhalten.',
      permissionDenied:
          'iOS hat die VPN-Konfiguration nicht autorisiert. Du kannst es erneut versuchen.',
      signingMissing:
          'Diese NeoStation-Installation wurde ohne Apples Network-Extension-Berechtigung signiert. Verwende ein autorisiertes Entwicklerprofil oder LocalDevVPN aus dem App Store.',
      configurationFailed:
          'iOS konnte die VPN-Konfiguration nicht speichern oder lesen.',
      extensionMissing:
          'Die lokale Tunnel-Erweiterung fehlt. Installiere die vollständig signierte IPA erneut.',
      vpnConflict:
          'Ein anderes VPN ist aktiv. Deaktiviere es und versuche das NeoStation-VPN erneut.',
      startFailed: 'Das VPN konnte nicht aktiviert werden.',
      stopFailed: 'Das VPN konnte nicht ordnungsgemäß deaktiviert werden.',
      timeout: 'Zeitüberschreitung bei der VPN-Aktivierung. Prüfe die iOS-VPN-Einstellungen.',
      statusFailed: 'Der aktuelle VPN-Status konnte nicht aktualisiert werden.',
      notConnected: 'Die VPN-Konfiguration besteht, ist aber nicht verbunden.',
      genericError: 'Ein unerwarteter VPN-Fehler ist aufgetreten.',
    },
    'es': {
      title: 'VPN JIT local',
      checking: 'Comprobando la VPN…',
      notAuthorized: 'VPN no autorizada',
      authorized: 'VPN autorizada',
      active: 'VPN activa',
      inactive: 'VPN desactivada',
      connecting: 'Activación en curso…',
      disconnecting: 'Desactivación en curso…',
      reasserting: 'Reconectando la VPN…',
      unsupported: 'VPN no disponible',
      errorStatus: 'Error de VPN',
      authorizeAction: 'Autorizar VPN',
      enableAction: 'Activar VPN',
      disableAction: 'Desactivar VPN',
      notAuthorizedDescription:
          'Autoriza el túnel JIT local de NeoStation en el diálogo nativo de iOS.',
      authorizedDescription:
          'iOS ha guardado la configuración VPN. Actívala cuando JIT necesite la ruta local del dispositivo.',
      activeDescription:
          'Solo funciona en este dispositivo; no envía tráfico de Internet por el túnel.',
      unsupportedDescription:
          'Requiere iOS 17.4 o posterior y una extensión de red firmada correctamente.',
      authorizedAndEnabled: 'VPN autorizada y activada.',
      enabledMessage: 'VPN activada.',
      disabledMessage: 'VPN desactivada. Se ha conservado su autorización.',
      permissionDenied:
          'iOS no autorizó la configuración VPN. Puedes intentarlo de nuevo.',
      signingMissing:
          'Esta instalación de NeoStation se firmó sin el permiso Network Extension de Apple. Usa un perfil de desarrollador autorizado o LocalDevVPN de la App Store.',
      configurationFailed:
          'iOS no pudo guardar o leer la configuración VPN.',
      extensionMissing:
          'Falta la extensión del túnel local. Reinstala la IPA completa y firmada.',
      vpnConflict:
          'Hay otra VPN activa. Desactívala y vuelve a probar la VPN de NeoStation.',
      startFailed: 'No se pudo activar la VPN.',
      stopFailed: 'No se pudo desactivar la VPN correctamente.',
      timeout: 'La activación de la VPN agotó el tiempo. Revisa los ajustes de VPN de iOS.',
      statusFailed: 'No se pudo actualizar el estado actual de la VPN.',
      notConnected: 'La configuración VPN existe, pero no está conectada.',
      genericError: 'Se produjo un error de VPN inesperado.',
    },
    'fr': {
      title: 'VPN JIT local',
      checking: 'Vérification du VPN…',
      notAuthorized: 'VPN non autorisé',
      authorized: 'VPN autorisé',
      active: 'VPN activé',
      inactive: 'VPN désactivé',
      connecting: 'Activation en cours…',
      disconnecting: 'Désactivation en cours…',
      reasserting: 'Reconnexion du VPN…',
      unsupported: 'VPN indisponible',
      errorStatus: 'Erreur VPN',
      authorizeAction: 'Autoriser le VPN',
      enableAction: 'Activer le VPN',
      disableAction: 'Désactiver le VPN',
      notAuthorizedDescription:
          'Autorisez le tunnel JIT local de NeoStation dans la fenêtre native iOS.',
      authorizedDescription:
          'iOS a enregistré la configuration VPN. Activez-la lorsque le JIT a besoin de la route locale.',
      activeDescription:
          'Uniquement sur cet iPhone ; aucun trafic Internet ne passe par ce tunnel.',
      unsupportedDescription:
          'Nécessite iOS 17.4 ou ultérieur et une extension réseau correctement signée.',
      authorizedAndEnabled: 'VPN autorisé et activé.',
      enabledMessage: 'VPN activé.',
      disabledMessage: 'VPN désactivé. Son autorisation a été conservée.',
      permissionDenied:
          'iOS n’a pas autorisé la configuration VPN. Vous pouvez réessayer.',
      signingMissing:
          'Cette installation de NeoStation a été signée sans l’autorisation Network Extension d’Apple. Utilisez un profil développeur autorisé ou LocalDevVPN depuis l’App Store.',
      configurationFailed:
          'iOS n’a pas pu enregistrer ou lire la configuration VPN.',
      extensionMissing:
          'L’extension du tunnel local est absente. Réinstallez l’IPA complète et signée.',
      vpnConflict:
          'Un autre VPN est actif. Désactivez-le, puis réessayez le VPN NeoStation.',
      startFailed: 'Le VPN n’a pas pu être activé.',
      stopFailed: 'Le VPN n’a pas pu être désactivé proprement.',
      timeout: 'L’activation du VPN a expiré. Vérifiez les réglages VPN d’iOS.',
      statusFailed: 'L’état actuel du VPN n’a pas pu être actualisé.',
      notConnected: 'La configuration VPN existe, mais elle n’est pas connectée.',
      genericError: 'Une erreur VPN inattendue est survenue.',
    },
    'id': {
      title: 'VPN JIT Lokal',
      checking: 'Memeriksa VPN…',
      notAuthorized: 'VPN belum diizinkan',
      authorized: 'VPN diizinkan',
      active: 'VPN aktif',
      inactive: 'VPN dinonaktifkan',
      connecting: 'Sedang mengaktifkan…',
      disconnecting: 'Sedang menonaktifkan…',
      reasserting: 'VPN sedang menyambung ulang…',
      unsupported: 'VPN tidak tersedia',
      errorStatus: 'Kesalahan VPN',
      authorizeAction: 'Izinkan VPN',
      enableAction: 'Aktifkan VPN',
      disableAction: 'Nonaktifkan VPN',
      notAuthorizedDescription:
          'Izinkan terowongan JIT lokal NeoStation melalui dialog asli iOS.',
      authorizedDescription:
          'iOS telah menyimpan konfigurasi VPN. Aktifkan saat JIT memerlukan rute lokal perangkat.',
      activeDescription:
          'Hanya di perangkat ini; lalu lintas Internet tidak dikirim melalui terowongan.',
      unsupportedDescription:
          'Memerlukan iOS 17.4 atau lebih baru dan Network Extension yang ditandatangani dengan benar.',
      authorizedAndEnabled: 'VPN diizinkan dan diaktifkan.',
      enabledMessage: 'VPN diaktifkan.',
      disabledMessage: 'VPN dinonaktifkan. Izinnya tetap disimpan.',
      permissionDenied:
          'iOS tidak mengizinkan konfigurasi VPN. Anda dapat mencoba lagi.',
      signingMissing:
          'Instalasi NeoStation ini ditandatangani tanpa izin Network Extension Apple. Gunakan profil pengembang yang diizinkan atau LocalDevVPN dari App Store.',
      configurationFailed:
          'iOS tidak dapat menyimpan atau membaca konfigurasi VPN.',
      extensionMissing:
          'Ekstensi terowongan lokal tidak ada. Instal ulang IPA lengkap yang ditandatangani.',
      vpnConflict:
          'VPN lain sedang aktif. Nonaktifkan lalu coba VPN NeoStation lagi.',
      startFailed: 'VPN tidak dapat diaktifkan.',
      stopFailed: 'VPN tidak dapat dinonaktifkan dengan benar.',
      timeout: 'Aktivasi VPN kehabisan waktu. Periksa pengaturan VPN iOS.',
      statusFailed: 'Status VPN saat ini tidak dapat diperbarui.',
      notConnected: 'Konfigurasi VPN tersedia, tetapi belum tersambung.',
      genericError: 'Terjadi kesalahan VPN yang tidak terduga.',
    },
    'it': {
      title: 'VPN JIT locale',
      checking: 'Verifica della VPN…',
      notAuthorized: 'VPN non autorizzata',
      authorized: 'VPN autorizzata',
      active: 'VPN attiva',
      inactive: 'VPN disattivata',
      connecting: 'Attivazione in corso…',
      disconnecting: 'Disattivazione in corso…',
      reasserting: 'Riconnessione VPN…',
      unsupported: 'VPN non disponibile',
      errorStatus: 'Errore VPN',
      authorizeAction: 'Autorizza VPN',
      enableAction: 'Attiva VPN',
      disableAction: 'Disattiva VPN',
      notAuthorizedDescription:
          'Autorizza il tunnel JIT locale di NeoStation nella finestra nativa di iOS.',
      authorizedDescription:
          'iOS ha salvato la configurazione VPN. Attivala quando JIT richiede il percorso locale del dispositivo.',
      activeDescription:
          'Solo sul dispositivo; nessun traffico Internet passa attraverso il tunnel.',
      unsupportedDescription:
          'Richiede iOS 17.4 o successivo e una Network Extension firmata correttamente.',
      authorizedAndEnabled: 'VPN autorizzata e attivata.',
      enabledMessage: 'VPN attivata.',
      disabledMessage: 'VPN disattivata. L’autorizzazione è stata conservata.',
      permissionDenied:
          'iOS non ha autorizzato la configurazione VPN. Puoi riprovare.',
      signingMissing:
          'Questa installazione di NeoStation è stata firmata senza il permesso Network Extension di Apple. Usa un profilo sviluppatore autorizzato o LocalDevVPN dall’App Store.',
      configurationFailed:
          'iOS non ha potuto salvare o leggere la configurazione VPN.',
      extensionMissing:
          'Manca l’estensione del tunnel locale. Reinstalla l’IPA completa e firmata.',
      vpnConflict:
          'È attiva un’altra VPN. Disattivala e riprova la VPN di NeoStation.',
      startFailed: 'Impossibile attivare la VPN.',
      stopFailed: 'Impossibile disattivare correttamente la VPN.',
      timeout: 'Tempo scaduto per l’attivazione VPN. Controlla le impostazioni VPN di iOS.',
      statusFailed: 'Impossibile aggiornare lo stato corrente della VPN.',
      notConnected: 'La configurazione VPN esiste, ma non è connessa.',
      genericError: 'Si è verificato un errore VPN imprevisto.',
    },
    'ja': {
      title: 'ローカル JIT VPN',
      checking: 'VPN を確認中…',
      notAuthorized: 'VPN 未許可',
      authorized: 'VPN 許可済み',
      active: 'VPN 有効',
      inactive: 'VPN 無効',
      connecting: '有効化中…',
      disconnecting: '無効化中…',
      reasserting: 'VPN を再接続中…',
      unsupported: 'VPN を利用できません',
      errorStatus: 'VPN エラー',
      authorizeAction: 'VPN を許可',
      enableAction: 'VPN を有効化',
      disableAction: 'VPN を無効化',
      notAuthorizedDescription:
          'iOS の標準ダイアログで NeoStation のローカル JIT トンネルを許可します。',
      authorizedDescription:
          'iOS に VPN 設定が保存されています。JIT が端末内ルートを必要とするときに有効化してください。',
      activeDescription:
          'この端末内だけで動作し、インターネット通信はトンネルを通りません。',
      unsupportedDescription:
          'iOS 17.4 以降と、正しく署名された Network Extension が必要です。',
      authorizedAndEnabled: 'VPN を許可して有効化しました。',
      enabledMessage: 'VPN を有効化しました。',
      disabledMessage: 'VPN を無効化しました。許可設定は保持されます。',
      permissionDenied: 'iOS が VPN 設定を許可しませんでした。再試行できます。',
      signingMissing:
          'この NeoStation は Apple の Network Extension 権限なしで署名されています。対応する開発者プロファイルまたは App Store の LocalDevVPN を使用してください。',
      configurationFailed: 'iOS が VPN 設定を保存または読み込めませんでした。',
      extensionMissing:
          'ローカルトンネル拡張がありません。署名済みの完全な IPA を再インストールしてください。',
      vpnConflict:
          '別の VPN が有効です。無効にしてから NeoStation VPN を再試行してください。',
      startFailed: 'VPN を有効化できませんでした。',
      stopFailed: 'VPN を正常に無効化できませんでした。',
      timeout: 'VPN の有効化がタイムアウトしました。iOS の VPN 設定を確認してください。',
      statusFailed: '現在の VPN 状態を更新できませんでした。',
      notConnected: 'VPN 設定は存在しますが、接続されていません。',
      genericError: '予期しない VPN エラーが発生しました。',
    },
    'ko': {
      title: '로컬 JIT VPN',
      checking: 'VPN 확인 중…',
      notAuthorized: 'VPN 허용 안 됨',
      authorized: 'VPN 허용됨',
      active: 'VPN 활성',
      inactive: 'VPN 비활성',
      connecting: '활성화 중…',
      disconnecting: '비활성화 중…',
      reasserting: 'VPN 다시 연결 중…',
      unsupported: 'VPN 사용 불가',
      errorStatus: 'VPN 오류',
      authorizeAction: 'VPN 허용',
      enableAction: 'VPN 활성화',
      disableAction: 'VPN 비활성화',
      notAuthorizedDescription:
          'iOS 기본 대화상자에서 NeoStation의 로컬 JIT 터널을 허용하세요.',
      authorizedDescription:
          'iOS에 VPN 구성이 저장되었습니다. JIT에 기기 로컬 경로가 필요할 때 활성화하세요.',
      activeDescription:
          '이 기기 안에서만 동작하며 인터넷 트래픽은 터널을 통과하지 않습니다.',
      unsupportedDescription:
          'iOS 17.4 이상과 올바르게 서명된 Network Extension이 필요합니다.',
      authorizedAndEnabled: 'VPN을 허용하고 활성화했습니다.',
      enabledMessage: 'VPN을 활성화했습니다.',
      disabledMessage: 'VPN을 비활성화했습니다. 허용 설정은 유지됩니다.',
      permissionDenied: 'iOS가 VPN 구성을 허용하지 않았습니다. 다시 시도할 수 있습니다.',
      signingMissing:
          '이 NeoStation 설치본은 Apple Network Extension 권한 없이 서명되었습니다. 승인된 개발자 프로필이나 App Store의 LocalDevVPN을 사용하세요.',
      configurationFailed: 'iOS가 VPN 구성을 저장하거나 읽지 못했습니다.',
      extensionMissing:
          '로컬 터널 확장이 없습니다. 완전히 서명된 IPA를 다시 설치하세요.',
      vpnConflict:
          '다른 VPN이 활성 상태입니다. 비활성화한 뒤 NeoStation VPN을 다시 시도하세요.',
      startFailed: 'VPN을 활성화하지 못했습니다.',
      stopFailed: 'VPN을 정상적으로 비활성화하지 못했습니다.',
      timeout: 'VPN 활성화 시간이 초과되었습니다. iOS VPN 설정을 확인하세요.',
      statusFailed: '현재 VPN 상태를 새로 고치지 못했습니다.',
      notConnected: 'VPN 구성은 있지만 연결되지 않았습니다.',
      genericError: '예기치 않은 VPN 오류가 발생했습니다.',
    },
    'pt': {
      title: 'VPN JIT local',
      checking: 'Verificando a VPN…',
      notAuthorized: 'VPN não autorizada',
      authorized: 'VPN autorizada',
      active: 'VPN ativa',
      inactive: 'VPN desativada',
      connecting: 'Ativação em andamento…',
      disconnecting: 'Desativação em andamento…',
      reasserting: 'Reconectando a VPN…',
      unsupported: 'VPN indisponível',
      errorStatus: 'Erro de VPN',
      authorizeAction: 'Autorizar VPN',
      enableAction: 'Ativar VPN',
      disableAction: 'Desativar VPN',
      notAuthorizedDescription:
          'Autorize o túnel JIT local do NeoStation na janela nativa do iOS.',
      authorizedDescription:
          'O iOS salvou a configuração VPN. Ative-a quando o JIT precisar da rota local do aparelho.',
      activeDescription:
          'Somente neste aparelho; nenhum tráfego da Internet passa pelo túnel.',
      unsupportedDescription:
          'Requer iOS 17.4 ou posterior e uma Network Extension assinada corretamente.',
      authorizedAndEnabled: 'VPN autorizada e ativada.',
      enabledMessage: 'VPN ativada.',
      disabledMessage: 'VPN desativada. A autorização foi mantida.',
      permissionDenied:
          'O iOS não autorizou a configuração VPN. Você pode tentar novamente.',
      signingMissing:
          'Esta instalação do NeoStation foi assinada sem a permissão Network Extension da Apple. Use um perfil de desenvolvedor autorizado ou o LocalDevVPN da App Store.',
      configurationFailed:
          'O iOS não conseguiu salvar ou ler a configuração VPN.',
      extensionMissing:
          'A extensão do túnel local está ausente. Reinstale a IPA completa e assinada.',
      vpnConflict:
          'Outra VPN está ativa. Desative-a e tente novamente a VPN do NeoStation.',
      startFailed: 'Não foi possível ativar a VPN.',
      stopFailed: 'Não foi possível desativar a VPN corretamente.',
      timeout: 'A ativação da VPN expirou. Verifique os ajustes de VPN do iOS.',
      statusFailed: 'Não foi possível atualizar o estado atual da VPN.',
      notConnected: 'A configuração VPN existe, mas não está conectada.',
      genericError: 'Ocorreu um erro de VPN inesperado.',
    },
    'ru': {
      title: 'Локальный JIT VPN',
      checking: 'Проверка VPN…',
      notAuthorized: 'VPN не разрешён',
      authorized: 'VPN разрешён',
      active: 'VPN активен',
      inactive: 'VPN отключён',
      connecting: 'Выполняется включение…',
      disconnecting: 'Выполняется отключение…',
      reasserting: 'Повторное подключение VPN…',
      unsupported: 'VPN недоступен',
      errorStatus: 'Ошибка VPN',
      authorizeAction: 'Разрешить VPN',
      enableAction: 'Включить VPN',
      disableAction: 'Отключить VPN',
      notAuthorizedDescription:
          'Разрешите локальный JIT-туннель NeoStation в системном окне iOS.',
      authorizedDescription:
          'iOS сохранила конфигурацию VPN. Включите её, когда JIT требуется локальный маршрут устройства.',
      activeDescription:
          'Работает только на устройстве; интернет-трафик через туннель не передаётся.',
      unsupportedDescription:
          'Требуется iOS 17.4 или новее и правильно подписанное расширение Network Extension.',
      authorizedAndEnabled: 'VPN разрешён и включён.',
      enabledMessage: 'VPN включён.',
      disabledMessage: 'VPN отключён. Разрешение сохранено.',
      permissionDenied:
          'iOS не разрешила конфигурацию VPN. Можно повторить попытку.',
      signingMissing:
          'Эта установка NeoStation подписана без разрешения Apple Network Extension. Используйте разрешённый профиль разработчика или LocalDevVPN из App Store.',
      configurationFailed:
          'iOS не удалось сохранить или прочитать конфигурацию VPN.',
      extensionMissing:
          'Расширение локального туннеля отсутствует. Переустановите полностью подписанный IPA.',
      vpnConflict:
          'Активен другой VPN. Отключите его и повторите попытку с VPN NeoStation.',
      startFailed: 'Не удалось включить VPN.',
      stopFailed: 'Не удалось корректно отключить VPN.',
      timeout: 'Время включения VPN истекло. Проверьте настройки VPN в iOS.',
      statusFailed: 'Не удалось обновить текущее состояние VPN.',
      notConnected: 'Конфигурация VPN существует, но соединение не установлено.',
      genericError: 'Произошла непредвиденная ошибка VPN.',
    },
    'zh': {
      title: '本地 JIT VPN',
      checking: '正在检查 VPN…',
      notAuthorized: 'VPN 未授权',
      authorized: 'VPN 已授权',
      active: 'VPN 已启用',
      inactive: 'VPN 已停用',
      connecting: '正在启用…',
      disconnecting: '正在停用…',
      reasserting: 'VPN 正在重新连接…',
      unsupported: 'VPN 不可用',
      errorStatus: 'VPN 错误',
      authorizeAction: '授权 VPN',
      enableAction: '启用 VPN',
      disableAction: '停用 VPN',
      notAuthorizedDescription:
          '请在 iOS 系统对话框中授权 NeoStation 的本地 JIT 隧道。',
      authorizedDescription:
          'iOS 已保存 VPN 配置。JIT 需要设备本地路径时可将其启用。',
      activeDescription: '仅在本机运行；互联网流量不会经过此隧道。',
      unsupportedDescription:
          '需要 iOS 17.4 或更高版本，以及正确签名的 Network Extension。',
      authorizedAndEnabled: 'VPN 已授权并启用。',
      enabledMessage: 'VPN 已启用。',
      disabledMessage: 'VPN 已停用，授权仍保留。',
      permissionDenied: 'iOS 未授权 VPN 配置。你可以重试。',
      signingMissing:
          '此 NeoStation 安装包的签名不含 Apple Network Extension 权限。请使用获授权的开发者描述文件，或从 App Store 安装 LocalDevVPN。',
      configurationFailed: 'iOS 无法保存或读取 VPN 配置。',
      extensionMissing: '缺少本地隧道扩展。请重新安装完整签名的 IPA。',
      vpnConflict: '另一个 VPN 正在运行。请先停用它，再重试 NeoStation VPN。',
      startFailed: '无法启用 VPN。',
      stopFailed: '无法正常停用 VPN。',
      timeout: 'VPN 启用超时。请检查 iOS VPN 设置后重试。',
      statusFailed: '无法刷新当前 VPN 状态。',
      notConnected: 'VPN 配置已存在，但尚未连接。',
      genericError: '发生了意外的 VPN 错误。',
    },
    'zh_Hant': {
      title: '本機 JIT VPN',
      checking: '正在檢查 VPN…',
      notAuthorized: 'VPN 未授權',
      authorized: 'VPN 已授權',
      active: 'VPN 已啟用',
      inactive: 'VPN 已停用',
      connecting: '正在啟用…',
      disconnecting: '正在停用…',
      reasserting: 'VPN 正在重新連線…',
      unsupported: 'VPN 無法使用',
      errorStatus: 'VPN 錯誤',
      authorizeAction: '授權 VPN',
      enableAction: '啟用 VPN',
      disableAction: '停用 VPN',
      notAuthorizedDescription:
          '請在 iOS 系統對話框中授權 NeoStation 的本機 JIT 通道。',
      authorizedDescription:
          'iOS 已儲存 VPN 設定。JIT 需要裝置本機路徑時可將其啟用。',
      activeDescription: '僅在本機運作；網際網路流量不會通過此通道。',
      unsupportedDescription:
          '需要 iOS 17.4 或以上版本，以及正確簽署的 Network Extension。',
      authorizedAndEnabled: 'VPN 已授權並啟用。',
      enabledMessage: 'VPN 已啟用。',
      disabledMessage: 'VPN 已停用，授權仍會保留。',
      permissionDenied: 'iOS 未授權 VPN 設定。你可以重試。',
      signingMissing:
          '此 NeoStation 安裝版本的簽章不含 Apple Network Extension 權限。請使用獲授權的開發者描述檔，或從 App Store 安裝 LocalDevVPN。',
      configurationFailed: 'iOS 無法儲存或讀取 VPN 設定。',
      extensionMissing: '缺少本機通道擴充功能。請重新安裝完整簽署的 IPA。',
      vpnConflict: '另一個 VPN 正在運作。請先停用，再重試 NeoStation VPN。',
      startFailed: '無法啟用 VPN。',
      stopFailed: '無法正常停用 VPN。',
      timeout: 'VPN 啟用逾時。請檢查 iOS VPN 設定後重試。',
      statusFailed: '無法重新整理目前的 VPN 狀態。',
      notConnected: 'VPN 設定已存在，但尚未連線。',
      genericError: '發生未預期的 VPN 錯誤。',
    },
  };
}
