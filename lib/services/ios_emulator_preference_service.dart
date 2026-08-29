import 'package:path/path.dart' as path;
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

  /// Chooses the iOS library app for one game from actual library availability.
  ///
  /// The primary emulator is a preference only when both libraries contain the
  /// game. It must never route a RetroArch-only game to Manic EMU, or vice versa.
  static IosLibraryEmulator? resolveLaunchEmulator({
    required IosLibraryEmulator primary,
    required bool retroArchHasGame,
    required bool manicEmuHasGame,
  }) {
    if (retroArchHasGame && manicEmuHasGame) return primary;
    if (retroArchHasGame) return IosLibraryEmulator.retroArch;
    if (manicEmuHasGame) return IosLibraryEmulator.manicEmu;
    return null;
  }

  /// Resolves the iOS library applications associated with a system's games.
  ///
  /// A per-game choice is authoritative. Otherwise the ROM's persisted path
  /// identifies the linked Manic EMU or RetroArch library. The primary choice
  /// is only a fallback for games that cannot be attributed to one folder.
  /// Returning a set lets the settings UI represent mixed libraries without
  /// pretending that every iOS system belongs to RetroArch.
  static Future<Set<IosLibraryEmulator>> associationsForSystem({
    required Iterable<String> romPaths,
    String? manicEmuFolder,
    String? retroArchFolder,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final primary = _decode(prefs.getString(primaryKey));
    final choices = <String, IosLibraryEmulator>{};
    final persistedRomPaths = romPaths.toList(growable: false);

    for (final romPath in persistedRomPaths) {
      final value = prefs.getString('$_gameChoicePrefix$romPath');
      if (value != null) choices[romPath] = _decode(value);
    }

    return resolveSystemAssociations(
      romPaths: persistedRomPaths,
      gameChoices: choices,
      manicEmuFolder: manicEmuFolder,
      retroArchFolder: retroArchFolder,
      primary: primary,
    );
  }

  /// Pure resolver kept public so the precedence rules can be regression
  /// tested without a platform channel or a real SharedPreferences store.
  static Set<IosLibraryEmulator> resolveSystemAssociations({
    required Iterable<String> romPaths,
    required Map<String, IosLibraryEmulator> gameChoices,
    required String? manicEmuFolder,
    required String? retroArchFolder,
    required IosLibraryEmulator primary,
  }) {
    final associations = <IosLibraryEmulator>{};

    for (final romPath in romPaths) {
      final explicitChoice = gameChoices[romPath];
      if (explicitChoice != null) {
        associations.add(explicitChoice);
        continue;
      }

      final belongsToManic = _isInsideFolder(romPath, manicEmuFolder);
      final belongsToRetroArch = _isInsideFolder(romPath, retroArchFolder);

      if (belongsToManic != belongsToRetroArch) {
        associations.add(
          belongsToManic
              ? IosLibraryEmulator.manicEmu
              : IosLibraryEmulator.retroArch,
        );
      } else {
        // The file belongs to neither linked folder (or both folders resolve
        // to the same location), so the persisted primary choice is the only
        // unambiguous fallback.
        associations.add(primary);
      }
    }

    if (associations.isEmpty) associations.add(primary);
    return associations;
  }

  /// Filters the two library-level iOS applications while leaving unrelated
  /// standalone emulators (ARMSX2, MeloNX, etc.) untouched.
  static bool shouldShowIosApplication({
    required String? urlScheme,
    required Set<IosLibraryEmulator> associations,
  }) {
    switch (urlScheme?.trim().toLowerCase()) {
      case 'retroarch':
        return associations.contains(IosLibraryEmulator.retroArch);
      case 'manicemu':
        return associations.contains(IosLibraryEmulator.manicEmu);
      default:
        return true;
    }
  }

  static bool _isInsideFolder(String filePath, String? folderPath) {
    final folder = folderPath?.trim();
    if (filePath.trim().isEmpty || folder == null || folder.isEmpty) {
      return false;
    }
    return path.equals(filePath, folder) || path.isWithin(folder, filePath);
  }

  static String _encode(IosLibraryEmulator emulator) =>
      emulator == IosLibraryEmulator.manicEmu ? 'manicemu' : 'retroarch';

  static IosLibraryEmulator _decode(String? value) => value == 'manicemu'
      ? IosLibraryEmulator.manicEmu
      : IosLibraryEmulator.retroArch;
}
