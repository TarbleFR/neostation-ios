import 'package:shared_preferences/shared_preferences.dart';

/// Stores iOS JIT preferences shared by the integrated launchers.
///
/// ARMSX2 exposes two deliberately separate NeoStation launch modes:
/// - Standard (default): the historical post-JIT armsx2:// handoff. This sends
///   the selected game and keeps the normal return/NeoSync lifecycle.
/// - Direct: resume the same JIT-enabled ARMSX2 PID and let ARMSX2's own
///   Automatic Load Last Game feature continue without a second URL handoff.
///
/// A new v2 key is used on purpose so experimental values saved by earlier
/// builds can never silently opt existing users into Direct mode.
class JitBackendPreferenceService {
  JitBackendPreferenceService._();

  static const String preferenceKey = 'ios_stikdebug_fallback_v1';
  static const String armsx2DirectLaunchPreferenceKey =
      'ios_armsx2_direct_load_last_game_v2';

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

  /// Whether NeoStation should use the optional ARMSX2 direct/last-game path.
  ///
  /// False is intentionally the default for every install/update. Standard mode
  /// is the compatibility path that delivers the selected game URL and is the
  /// mode intended for automatic NeoSync after the game closes.
  static Future<bool> useArmsx2DirectLaunch() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(armsx2DirectLaunchPreferenceKey) ?? false;
  }

  static Future<void> setUseArmsx2DirectLaunch(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setBool(
      armsx2DirectLaunchPreferenceKey,
      value,
    );
    if (!saved) {
      throw StateError('The ARMSX2 direct launch preference was not saved.');
    }
  }

  // Compatibility aliases for code outside the settings screen while the
  // ARMSX2 bridge still names its wire argument `autoLoadLastGame`.
  static Future<bool> useArmsx2AutoLoadLastGame() => useArmsx2DirectLaunch();

  static Future<void> setUseArmsx2AutoLoadLastGame(bool value) =>
      setUseArmsx2DirectLaunch(value);
}
