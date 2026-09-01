import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/services/logger_service.dart';

/// Service responsible for persisting game session state across application restarts.
///
/// Android stores the full active session so playtime can be recovered after a
/// process kill. iOS persists the same lightweight game identity as well so a
/// cold return from a memory-heavy external emulator can resume NeoSync without
/// rebuilding or rescanning the user's library.
class GameSessionPersistence {
  static const String _keyGameActive = 'game_session_active';
  static const String _keySystemFolderName = 'game_session_system_folder';
  static const String _keyFilename = 'game_session_filename';
  static const String _keyStartTimestamp = 'game_session_start_timestamp';
  static const String _keySkipStartupScan = 'game_session_skip_startup_scan';

  static final _log = LoggerService.instance;

  /// Persists the initiation of a new game session.
  ///
  /// The same record is used on Android for playtime recovery and on iOS to
  /// remember which game's save must be synchronized if NeoStation is reclaimed
  /// while an external emulator owns the foreground.
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
  /// Kept for callers that only need to suppress a cold-start ROM scan. Normal
  /// iOS game launches now use [saveGameSession] so NeoSync can also recover the
  /// identity of the game that just exited.
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

  /// Clears the active-game identity but deliberately leaves the startup-scan
  /// guard untouched.
  ///
  /// This is used after an iOS cold-return NeoSync recovery: AppScreen still
  /// needs the one-shot guard in order to skip the normal startup ROM scan, but
  /// the save must not be uploaded again on the next resume.
  static Future<void> clearActiveGameSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyGameActive);
      await prefs.remove(_keySystemFolderName);
      await prefs.remove(_keyFilename);
      await prefs.remove(_keyStartTimestamp);
    } catch (e) {
      _log.e('Error clearing active game session metadata: $e');
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
