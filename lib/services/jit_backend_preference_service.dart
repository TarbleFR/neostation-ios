import 'package:shared_preferences/shared_preferences.dart';

/// Stores the global iOS JIT backend preference.
///
/// ARMSX2 launch mode is intentionally NOT a NeoStation preference anymore.
/// The integrated ARMSX2 bridge reads "Automatic Load Last Game" directly from
/// ARMSX2 and chooses the matching launch path automatically.
class JitBackendPreferenceService {
  JitBackendPreferenceService._();

  static const String preferenceKey = 'ios_stikdebug_fallback_v1';

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

  /// Compatibility shim for the already-validated ARMSX2 bridge API.
  ///
  /// There is deliberately no saved NeoStation ARMSX2 mode anymore. Returning
  /// false means that if ARMSX2's own preference cannot be read, the bridge
  /// falls back conservatively to the legacy URL handoff instead of guessing a
  /// direct Automatic Load launch. When ARMSX2's preference is readable, its
  /// detected value always overrides this value in the native bridge.
  static Future<bool> useArmsx2AutoLoadLastGame() async => false;

  /// Kept temporarily for source compatibility with the validated #71 service.
  /// The value is intentionally not persisted: ARMSX2 itself is the sole source
  /// of truth for Automatic Load Last Game.
  static Future<void> setUseArmsx2AutoLoadLastGame(bool value) async {}
}
