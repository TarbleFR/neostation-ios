import 'package:shared_preferences/shared_preferences.dart';

/// Stores the single global emergency switch used by every integrated iOS JIT
/// target.
///
/// The default remains the built-in StikJIT path. When the fallback is enabled,
/// the central launcher skips every integrated bridge and runs the emulator's
/// existing Apple Shortcut, which in turn uses StikDebug.
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
}
