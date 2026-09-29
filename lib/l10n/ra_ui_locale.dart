import 'package:flutter/widgets.dart';

abstract final class RaUiLocale {
  static const Map<String, String> _gamesPlayed = {
    'en':'{count} games played','fr':'{count} jeux joués','de':'{count} Spiele gespielt','es':'{count} juegos jugados',
    'it':'{count} giochi giocati','pt':'{count} jogos jogados','ru':'Сыграно игр: {count}','id':'{count} game dimainkan',
    'ja':'プレイしたゲーム {count} 本','ko':'플레이한 게임 {count}개','zh':'已玩 {count} 个游戏','zh_Hant':'已玩 {count} 個遊戲',
  };

  static String gamesPlayed(BuildContext context, int count) {
    final locale = Localizations.localeOf(context);
    var key = locale.languageCode;
    if (key == 'zh') {
      final script = locale.scriptCode?.toLowerCase();
      final country = locale.countryCode?.toUpperCase();
      if (script == 'hant' || country == 'TW' || country == 'HK' || country == 'MO') key = 'zh_Hant';
    }
    return (_gamesPlayed[key] ?? _gamesPlayed['en']!).replaceAll('{count}', '$count');
  }
}
