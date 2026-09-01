import 'package:shared_preferences/shared_preferences.dart';

/// Stores iOS JIT preferences shared by the integrated launchers.
///
/// The default remains the built-in StikJIT path. When the global fallback is
/// enabled, the central launcher skips every integrated bridge and runs the
/// emulator's existing Apple Shortcut, which in turn uses StikDebug.
class JitBackendPreferenceService {
  JitBackendPreferenceService._();

  static const String preferenceKey = 'ios_stikdebug_fallback_v1';
  static const String armsx2AutoLoadLastGamePreferenceKey =
      'ios_armsx2_autoload_last_game_v1';

  static Future<bool> useStikDebugFallback() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(preferenceKey) ?? false;
  }

  static Future<void> setUseStikDebugFallback(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setBool(preferenceKey, value);
    if (!saved) {
      throw StateError('The global JIT backend preference was not saved.');
    }
  }

  /// Uses ARMSX2's own "Automatic Load Last Game" flow after StikJIT is ready.
  ///
  /// When disabled, NeoStation keeps the existing compatibility flow: ARMSX2 is
  /// JIT-enabled, NeoStation is brought back to the foreground, and the selected
  /// armsx2:// URL is delivered again. When enabled, the post-JIT round trip is
  /// skipped and ARMSX2 is allowed to continue directly into its own last game.
  static Future<bool> useArmsx2AutoLoadLastGame() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(armsx2AutoLoadLastGamePreferenceKey) ?? false;
  }

  static Future<void> setUseArmsx2AutoLoadLastGame(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setBool(
      armsx2AutoLoadLastGamePreferenceKey,
      value,
    );
    if (!saved) {
      throw StateError('The ARMSX2 launch mode preference was not saved.');
    }
  }
}
