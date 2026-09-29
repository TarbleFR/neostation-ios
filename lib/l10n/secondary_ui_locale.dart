import 'package:flutter/widgets.dart';

abstract final class SecondaryUiLocale {
  static const Map<String, Map<String, String>> _v = {
    'en': {'session':'Session','never':'Never','yesterday':'Yesterday','daysAgo':'{count} days ago','hoursAgo':'{count}h ago','minutesAgo':'{count}m ago','justNow':'Just now','openSettings':'Open settings','thisSession':'+{count} this session'},
    'fr': {'session':'Session','never':'Jamais','yesterday':'Hier','daysAgo':'Il y a {count} jours','hoursAgo':'Il y a {count} h','minutesAgo':'Il y a {count} min','justNow':'À l’instant','openSettings':'Ouvrir les réglages','thisSession':'+{count} cette session'},
    'de': {'session':'Sitzung','never':'Nie','yesterday':'Gestern','daysAgo':'vor {count} Tagen','hoursAgo':'vor {count} Std.','minutesAgo':'vor {count} Min.','justNow':'Gerade eben','openSettings':'Einstellungen öffnen','thisSession':'+{count} in dieser Sitzung'},
    'es': {'session':'Sesión','never':'Nunca','yesterday':'Ayer','daysAgo':'Hace {count} días','hoursAgo':'Hace {count} h','minutesAgo':'Hace {count} min','justNow':'Ahora mismo','openSettings':'Abrir ajustes','thisSession':'+{count} en esta sesión'},
    'it': {'session':'Sessione','never':'Mai','yesterday':'Ieri','daysAgo':'{count} giorni fa','hoursAgo':'{count} h fa','minutesAgo':'{count} min fa','justNow':'Adesso','openSettings':'Apri impostazioni','thisSession':'+{count} in questa sessione'},
    'pt': {'session':'Sessão','never':'Nunca','yesterday':'Ontem','daysAgo':'Há {count} dias','hoursAgo':'Há {count} h','minutesAgo':'Há {count} min','justNow':'Agora mesmo','openSettings':'Abrir definições','thisSession':'+{count} nesta sessão'},
    'ru': {'session':'Сеанс','never':'Никогда','yesterday':'Вчера','daysAgo':'{count} дн. назад','hoursAgo':'{count} ч назад','minutesAgo':'{count} мин назад','justNow':'Только что','openSettings':'Открыть настройки','thisSession':'+{count} за этот сеанс'},
    'id': {'session':'Sesi','never':'Belum pernah','yesterday':'Kemarin','daysAgo':'{count} hari lalu','hoursAgo':'{count} jam lalu','minutesAgo':'{count} mnt lalu','justNow':'Baru saja','openSettings':'Buka pengaturan','thisSession':'+{count} sesi ini'},
    'ja': {'session':'セッション','never':'未プレイ','yesterday':'昨日','daysAgo':'{count}日前','hoursAgo':'{count}時間前','minutesAgo':'{count}分前','justNow':'たった今','openSettings':'設定を開く','thisSession':'このセッションで +{count}'},
    'ko': {'session':'세션','never':'없음','yesterday':'어제','daysAgo':'{count}일 전','hoursAgo':'{count}시간 전','minutesAgo':'{count}분 전','justNow':'방금','openSettings':'설정 열기','thisSession':'이번 세션 +{count}'},
    'zh': {'session':'会话','never':'从未','yesterday':'昨天','daysAgo':'{count} 天前','hoursAgo':'{count} 小时前','minutesAgo':'{count} 分钟前','justNow':'刚刚','openSettings':'打开设置','thisSession':'本次会话 +{count}'},
    'zh_Hant': {'session':'工作階段','never':'從未','yesterday':'昨天','daysAgo':'{count} 天前','hoursAgo':'{count} 小時前','minutesAgo':'{count} 分鐘前','justNow':'剛剛','openSettings':'開啟設定','thisSession':'本次工作階段 +{count}'},
  };

  static String _key(Locale locale) {
    if (locale.languageCode == 'zh') {
      final script = locale.scriptCode?.toLowerCase();
      final country = locale.countryCode?.toUpperCase();
      if (script == 'hant' || country == 'TW' || country == 'HK' || country == 'MO') return 'zh_Hant';
    }
    return locale.languageCode;
  }

  static String text(BuildContext context, String key) =>
      _v[_key(Localizations.localeOf(context))]?[key] ?? _v['en']![key] ?? key;

  static String format(BuildContext context, String key, Map<String, Object?> values) {
    var value = text(context, key);
    for (final item in values.entries) {
      value = value.replaceAll('{'+item.key+'}', item.value?.toString() ?? '');
    }
    return value;
  }
}
