import 'package:flutter/widgets.dart';
import 'package:neostation/services/rpcs3_game_profile_database.dart';

/// Compact labels for the automatic RPCS3 profile shown on PS3 game cards.
abstract final class Rpcs3ProfileLocale {
  static const Map<String, String> _automatic = {
    'en': 'Automatic configuration',
    'fr': 'Configuration automatique',
    'de': 'Automatische Konfiguration',
    'es': 'Configuración automática',
    'it': 'Configurazione automatica',
    'pt': 'Configuração automática',
    'ru': 'Автонастройка',
    'id': 'Konfigurasi otomatis',
    'ja': '自動構成',
    'ko': '자동 구성',
    'zh': '自动配置',
    'zh_Hant': '自動設定',
  };

  static const Map<String, Map<String, String>> _families = {
    'balanced': {
      'en': 'iOS Performance', 'fr': 'Performance iOS', 'de': 'iOS-Leistung',
      'es': 'Rendimiento iOS', 'it': 'Prestazioni iOS', 'pt': 'Desempenho iOS',
      'ru': 'Производительность iOS', 'id': 'Performa iOS', 'ja': 'iOS パフォーマンス',
      'ko': 'iOS 성능', 'zh': 'iOS 性能', 'zh_Hant': 'iOS 效能',
    },
    'compatibility': {
      'en': 'Compatibility', 'fr': 'Compatibilité', 'de': 'Kompatibilität',
      'es': 'Compatibilidad', 'it': 'Compatibilità', 'pt': 'Compatibilidade',
      'ru': 'Совместимость', 'id': 'Kompatibilitas', 'ja': '互換性',
      'ko': '호환성', 'zh': '兼容性', 'zh_Hant': '相容性',
    },
    'gpu': {
      'en': 'GPU / RSX', 'fr': 'GPU / RSX', 'de': 'GPU / RSX',
      'es': 'GPU / RSX', 'it': 'GPU / RSX', 'pt': 'GPU / RSX',
      'ru': 'GPU / RSX', 'id': 'GPU / RSX', 'ja': 'GPU / RSX',
      'ko': 'GPU / RSX', 'zh': 'GPU / RSX', 'zh_Hant': 'GPU / RSX',
    },
    'shader': {
      'en': 'Shaders', 'fr': 'Shaders', 'de': 'Shader', 'es': 'Shaders',
      'it': 'Shader', 'pt': 'Shaders', 'ru': 'Шейдеры', 'id': 'Shader',
      'ja': 'シェーダー', 'ko': '셰이더', 'zh': '着色器', 'zh_Hant': '著色器',
    },
    'spu': {
      'en': 'SPU intensive', 'fr': 'SPU intensif', 'de': 'SPU-intensiv',
      'es': 'SPU intensivo', 'it': 'SPU intensivo', 'pt': 'SPU intensivo',
      'ru': 'Нагрузка SPU', 'id': 'SPU intensif', 'ja': 'SPU 高負荷',
      'ko': 'SPU 집중', 'zh': 'SPU 密集', 'zh_Hant': 'SPU 密集',
    },
    'individual': {
      'en': 'Game-specific', 'fr': 'Spécifique au jeu', 'de': 'Spielspezifisch',
      'es': 'Específico del juego', 'it': 'Specifico per il gioco',
      'pt': 'Específico do jogo', 'ru': 'Для этой игры', 'id': 'Khusus game',
      'ja': 'ゲーム専用', 'ko': '게임 전용', 'zh': '游戏专用', 'zh_Hant': '遊戲專用',
    },
  };

  static String label(
    BuildContext context,
    Rpcs3ProfileFamily family, {
    required bool individual,
    required bool gameDatabase,
  }) {
    final locale = _localeKey(Localizations.maybeLocaleOf(context));
    final familyKey = individual
        ? 'individual'
        : switch (family) {
            Rpcs3ProfileFamily.compatibility => 'compatibility',
            Rpcs3ProfileFamily.gpuBound => 'gpu',
            Rpcs3ProfileFamily.shaderHeavy => 'shader',
            Rpcs3ProfileFamily.spuHeavy => 'spu',
            Rpcs3ProfileFamily.balanced => 'balanced',
          };
    final origin = gameDatabase || individual
        ? 'NeoStation GameDB'
        : (_families['balanced']![locale] ?? _families['balanced']!['en']!);
    final prefix = _automatic[locale] ?? _automatic['en']!;
    final name = _families[familyKey]![locale] ?? _families[familyKey]!['en']!;
    return '$prefix: $origin · $name';
  }

  static String _localeKey(Locale? locale) {
    if (locale == null) return 'en';
    if (locale.languageCode == 'zh') {
      final country = locale.countryCode?.toUpperCase();
      if (locale.scriptCode?.toLowerCase() == 'hant' ||
          country == 'TW' || country == 'HK' || country == 'MO') {
        return 'zh_Hant';
      }
    }
    return _automatic.containsKey(locale.languageCode)
        ? locale.languageCode
        : 'en';
  }
}
