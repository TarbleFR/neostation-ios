import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/services/logger_service.dart';

/// Persists ARMSX2-specific return work across an iOS process kill.
///
/// The two flags are intentionally independent:
/// - NeoSync upload can retry until ARMSX2 saves are reachable and authenticated.
/// - Library restoration is consumed as soon as NeoStation successfully returns
///   the user to the PS2 game list.
class Armsx2ReturnStateService {
  Armsx2ReturnStateService._();

  static const String _syncPendingKey = 'ios_armsx2_neosync_pending_v1';
  static const String _libraryReturnPendingKey =
      'ios_armsx2_library_return_pending_v1';
  static const String _armedAtKey = 'ios_armsx2_return_armed_at_v1';

  static final _log = LoggerService.instance;

  static Future<void> arm() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_syncPendingKey, true);
      await prefs.setBool(_libraryReturnPendingKey, true);
      await prefs.setInt(
        _armedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      _log.e('ARMSX2 return state: failed to arm pending return: $e');
    }
  }

  static Future<bool> hasPendingSync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_syncPendingKey) ?? false;
    } catch (e) {
      _log.e('ARMSX2 return state: failed to read sync marker: $e');
      return false;
    }
  }

  static Future<bool> hasPendingLibraryReturn() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_libraryReturnPendingKey) ?? false;
    } catch (e) {
      _log.e('ARMSX2 return state: failed to read library marker: $e');
      return false;
    }
  }

  static Future<int?> armedAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_armedAtKey);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearPendingSync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_syncPendingKey);
      await _clearTimestampIfIdle(prefs);
    } catch (e) {
      _log.e('ARMSX2 return state: failed to clear sync marker: $e');
    }
  }

  static Future<void> clearPendingLibraryReturn() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_libraryReturnPendingKey);
      await _clearTimestampIfIdle(prefs);
    } catch (e) {
      _log.e('ARMSX2 return state: failed to clear library marker: $e');
    }
  }

  static Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_syncPendingKey);
      await prefs.remove(_libraryReturnPendingKey);
      await prefs.remove(_armedAtKey);
    } catch (e) {
      _log.e('ARMSX2 return state: failed to clear pending state: $e');
    }
  }

  static Future<void> _clearTimestampIfIdle(SharedPreferences prefs) async {
    final syncPending = prefs.getBool(_syncPendingKey) ?? false;
    final returnPending = prefs.getBool(_libraryReturnPendingKey) ?? false;
    if (!syncPending && !returnPending) {
      await prefs.remove(_armedAtKey);
    }
  }
}
