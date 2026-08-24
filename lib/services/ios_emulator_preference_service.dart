import 'package:shared_preferences/shared_preferences.dart';

enum IosLibraryEmulator { retroArch, manicEmu }

class IosEmulatorPreferenceService {
  IosEmulatorPreferenceService._();

  static const primaryKey = 'ios_library_emulator_v1';
  static const upgradeOfferSeenKey = 'manic_emu_upgrade_offer_seen_v1';
  static const _gameChoicePrefix = 'ios_game_emulator_v1:';

  static Future<IosLibraryEmulator> primary() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(primaryKey) == 'manicemu'
        ? IosLibraryEmulator.manicEmu
        : IosLibraryEmulator.retroArch;
  }

  static Future<void> setPrimary(IosLibraryEmulator emulator) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(primaryKey, _encode(emulator));
  }

  static Future<bool> hasPrimaryChoice() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(primaryKey);
  }

  static Future<bool> shouldShowUpgradeOffer() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(upgradeOfferSeenKey) ?? false);
  }

  static Future<void> markUpgradeOfferSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(upgradeOfferSeenKey, true);
  }

  static Future<IosLibraryEmulator?> choiceForGame(String romPath) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('$_gameChoicePrefix$romPath');
    if (value == null) return null;
    return value == 'manicemu'
        ? IosLibraryEmulator.manicEmu
        : IosLibraryEmulator.retroArch;
  }

  static Future<void> setChoiceForGame(
    String romPath,
    IosLibraryEmulator emulator,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_gameChoicePrefix$romPath', _encode(emulator));
  }

  static String _encode(IosLibraryEmulator emulator) =>
      emulator == IosLibraryEmulator.manicEmu ? 'manicemu' : 'retroarch';
}
