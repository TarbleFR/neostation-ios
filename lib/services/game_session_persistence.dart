import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/services/logger_service.dart';

/// Service responsible for persisting game session state across application restarts.
///
/// Android stores the full active session so playtime can be recovered after a
/// process kill. iOS also uses the lightweight startup-scan guard: memory-heavy
/// external emulators such as ARMSX2 can cause iOS to reclaim NeoStation while
/// the game is in front, and the next foreground should restore the existing
/// library instead of performing a full ROM scan again.
class GameSessionPersistence {
  static const String _keyGameActive = 'game_session_active';
  static const String _keySystemFolderName = 'game_session_system_folder';
  static const String _keyFilename = 'game_session_filename';
  static const String _keyStartTimestamp = 'game_session_start_timestamp';
  static const String _keySkipStartupScan = 'game_session_skip_startup_scan';

  static final _log = LoggerService.instance;

  /// Persists the initiation of a new game session.
  static Future<void> saveGameSession({
    required String systemFolderName,
    required String filename,
    required int startTimestamp,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyGameActive, true);
      await prefs.setString(_keySystemFolderName, systemFolderName);
      await prefs.setString(_keyFilename, filename);
      await prefs.setInt(_keyStartTimestamp, startTimestamp);
      await prefs.setBool(_keySkipStartupScan, true);
    } catch (e) {
      _log.e('Error saving game session: $e');
    }
  }

  /// Arms only the one-shot startup-scan guard.
  ///
  /// iOS does not need Android's full process/session recovery metadata, but it
  /// does need to remember that a cold relaunch happened while an external game
  /// was active. The flag is consumed by SqliteConfigProvider.scanSystems().
  static Future<void> markSkipStartupScan() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keySkipStartupScan, true);
    } catch (e) {
      _log.e('Error marking startup scan to be skipped: $e');
    }
  }

  /// Clears only the one-shot startup-scan guard after a normal emulator return.
  static Future<void> clearSkipStartupScan() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keySkipStartupScan);
    } catch (e) {
      _log.e('Error clearing startup scan skip flag: $e');
    }
  }

  /// Peeks at the startup-scan guard without consuming it.
  ///
  /// This lets the early provider initialization use a lightweight warm-return
  /// path while leaving the flag available for the later ROM scan gate.
  static Future<bool> shouldSkipStartupScan() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keySkipStartupScan) ?? false;
    } catch (e) {
      _log.e('Error reading startup scan skip flag: $e');
      return false;
    }
  }

  /// Retrieves the active game session metadata if a session was previously flagged as active.
  ///
  /// Returns null if no active session is found or if the persisted data is incomplete.
  static Future<Map<String, dynamic>?> getActiveGameSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isActive = prefs.getBool(_keyGameActive) ?? false;

      if (!isActive) return null;

      final systemFolderName = prefs.getString(_keySystemFolderName);
      final filename = prefs.getString(_keyFilename);
      final startTimestamp = prefs.getInt(_keyStartTimestamp);

      if (systemFolderName == null ||
          filename == null ||
          startTimestamp == null) {
        return null;
      }

      return {
        'systemFolderName': systemFolderName,
        'filename': filename,
        'startTimestamp': startTimestamp,
      };
    } catch (e) {
      _log.e('Error reading game session: $e');
      return null;
    }
  }

  /// Purges all persisted game session metadata from shared preferences.
  ///
  /// Also clears the startup-scan skip flag so that a recovered session does
  /// not permanently suppress the next startup scan.
  static Future<void> clearGameSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyGameActive);
      await prefs.remove(_keySystemFolderName);
      await prefs.remove(_keyFilename);
      await prefs.remove(_keyStartTimestamp);
      await prefs.remove(_keySkipStartupScan);
    } catch (e) {
      _log.e('Error clearing game session: $e');
    }
  }

  /// Checks and consumes the skip-startup-scan flag.
  /// Returns true if the flag was set (scan should be skipped).
  static Future<bool> consumeSkipStartupScan() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final shouldSkip = prefs.getBool(_keySkipStartupScan) ?? false;
      if (shouldSkip) {
        await prefs.remove(_keySkipStartupScan);
      }
      return shouldSkip;
    } catch (e) {
      _log.e('Error consuming skip startup scan flag: $e');
      return false;
    }
  }

  /// Checks if an active session flag exists without reading the full metadata.
  static Future<bool> hasActiveSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyGameActive) ?? false;
    } catch (e) {
      return false;
    }
  }
}
