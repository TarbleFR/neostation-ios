import 'retro_achievements_hash_strategy.dart';
import 'nes_hash_strategy.dart';
import 'ds_hash_strategy.dart';
import 'console_lookup_hash_strategy.dart';
import 'default_md5_hash_strategy.dart';

class RetroAchievementsStrategyFactory {
  /// Returns the appropriate hash strategy for the given RA System ID (passed as a string)
  static RetroAchievementsHashStrategy getStrategy(String? systemId) {
    if (systemId == null) return DefaultMd5HashStrategy();

    // Map new string IDs and old integer-as-string IDs
    switch (systemId.toLowerCase()) {
      case 'nes':
      case 'fc':
        return NesHashStrategy();

      case 'ds':
        return DsHashStrategy();

      // Dreamcast
      case 'dc':
        return ConsoleLookupHashStrategy('Dreamcast');

      // GameCube
      case 'gc':
        return ConsoleLookupHashStrategy('GameCube');

      // Saturn
      case 'sat':
        return ConsoleLookupHashStrategy('Saturn');

      // PlayStation / PSX
      case 'ps1':
        return ConsoleLookupHashStrategy('PlayStation');

      // PlayStation 2 / PS2
      case 'ps2':
        return ConsoleLookupHashStrategy('PlayStation 2');

      // Default strategy for all other systems
      default:
        return DefaultMd5HashStrategy();
    }
  }
}
