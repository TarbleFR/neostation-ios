import 'package:flutter/widgets.dart';

class NeoPlayDiscoveryLocale {
  static String get(BuildContext context, String key) {
    final locale = Localizations.localeOf(context);
    final traditional = locale.languageCode == 'zh' &&
        (locale.scriptCode?.toLowerCase() == 'hant' ||
            const ['TW', 'HK', 'MO'].contains(locale.countryCode?.toUpperCase()));
    final language = traditional ? 'zh_Hant' : locale.languageCode;
    return (values[language] ?? values['en']!)[key]!;
  }

  static const values = <String, Map<String, String>>{
    'en': {
      'refresh': 'Search again',
      'networkHelp': 'In iOS Settings, allow Local Network access for NeoStation, then search again. Both devices must use the same Wi-Fi; guest networks may block discovery.',
    },
    'fr': {
      'refresh': 'Relancer la recherche',
      'networkHelp': 'Dans les Réglages iOS, autorisez Réseau local pour NeoStation, puis relancez la recherche. Les deux appareils doivent utiliser le même Wi-Fi ; les réseaux invités peuvent bloquer la détection.',
    },
    'de': {
      'refresh': 'Erneut suchen',
      'networkHelp': 'Erlaube NeoStation in den iOS-Einstellungen den Zugriff auf das lokale Netzwerk und suche erneut. Beide Geräte müssen dasselbe WLAN nutzen; Gastnetzwerke können die Suche blockieren.',
    },
    'es': {
      'refresh': 'Buscar de nuevo',
      'networkHelp': 'En los Ajustes de iOS, permite a NeoStation acceder a la red local y vuelve a buscar. Ambos dispositivos deben usar la misma red Wi-Fi; las redes de invitados pueden bloquear la detección.',
    },
    'it': {
      'refresh': 'Cerca di nuovo',
      'networkHelp': 'Nelle Impostazioni iOS, consenti a NeoStation l’accesso alla rete locale e ripeti la ricerca. Entrambi i dispositivi devono usare la stessa rete Wi-Fi; le reti ospiti possono bloccare il rilevamento.',
    },
    'pt': {
      'refresh': 'Procurar novamente',
      'networkHelp': 'Nas Definições do iOS, permita ao NeoStation aceder à rede local e procure novamente. Ambos os dispositivos devem usar a mesma rede Wi-Fi; as redes de convidados podem bloquear a deteção.',
    },
    'ru': {
      'refresh': 'Повторить поиск',
      'networkHelp': 'В настройках iOS разрешите NeoStation доступ к локальной сети и повторите поиск. Оба устройства должны использовать одну сеть Wi-Fi; гостевые сети могут блокировать обнаружение.',
    },
    'zh': {
      'refresh': '重新搜索',
      'networkHelp': '在 iOS 设置中允许 NeoStation 访问本地网络，然后重新搜索。两台设备必须使用同一 Wi-Fi；访客网络可能阻止发现设备。',
    },
    'zh_Hant': {
      'refresh': '重新搜尋',
      'networkHelp': '在 iOS 設定中允許 NeoStation 存取區域網路，然後重新搜尋。兩部裝置必須使用相同 Wi-Fi；訪客網路可能阻止偵測裝置。',
    },
    'id': {
      'refresh': 'Cari lagi',
      'networkHelp': 'Di Pengaturan iOS, izinkan NeoStation mengakses Jaringan Lokal, lalu cari lagi. Kedua perangkat harus memakai Wi-Fi yang sama; jaringan tamu dapat memblokir penemuan perangkat.',
    },
    'ja': {
      'refresh': 'もう一度検索',
      'networkHelp': 'iOS の設定で NeoStation のローカルネットワークへのアクセスを許可し、もう一度検索してください。両方の機器を同じ Wi-Fi に接続してください。ゲストネットワークでは機器を検出できない場合があります。',
    },
    'ko': {
      'refresh': '다시 검색',
      'networkHelp': 'iOS 설정에서 NeoStation의 로컬 네트워크 접근을 허용한 다음 다시 검색하세요. 두 기기는 같은 Wi-Fi를 사용해야 합니다. 게스트 네트워크에서는 기기 검색이 차단될 수 있습니다.',
    },
  };
}
