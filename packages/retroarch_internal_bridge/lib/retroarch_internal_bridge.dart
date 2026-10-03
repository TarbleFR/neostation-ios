import 'dart:async';

import 'package:flutter/services.dart';

/// A session owns the native renderer until its matching sessionEnded event.
/// First-frame timeouts deliberately retain ownership until the backend stops.
class RetroArchInternalBridge {
  RetroArchInternalBridge._();

  static const MethodChannel _channel = MethodChannel(
    'neostation/retroarch_internal',
  );
  static final _events = StreamController<Map<String, dynamic>>.broadcast();
  static bool _handlerInstalled = false;
  static bool _sessionOwned = false;
  static int _transaction = 0;
  static int get transaction => _transaction;
  static bool get hasSession => _sessionOwned;

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'sessionEvent' && call.method != 'sessionEnded') {
        return;
      }
      final value = call.arguments;
      if (value is! Map || value['transaction'] != _transaction) return;
      final event = Map<String, dynamic>.from(value);
      if (call.method == 'sessionEnded') _sessionOwned = false;
      event['type'] = call.method;
      _events.add(event);
    });
  }

  static Stream<Map<String, dynamic>> get sessionEvents {
    _ensureHandler();
    return _events.stream;
  }

  static Future<Map<String, dynamic>> _map(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>(method, arguments) ??
        const <String, dynamic>{},
  );

  /// Creates user-editable directories in Documents/RetroArch. It does not
  /// modify imported BIOS, saves, games or user configuration.
  static Future<Map<String, dynamic>> folders() => _map('folders');
  static Future<Map<String, dynamic>> diagnostics() => _map('diagnostics');

  static Future<Map<String, dynamic>> launch({
    required String coreId,
    required String gamePath,
    required String gameTitle,
    required String locale,
    required Map<String, String> uiText,
  }) async {
    _ensureHandler();
    if (_sessionOwned) {
      return const {
        'success': false,
        'errorCode': 'RETROARCH_SESSION_ACTIVE',
        'stage': 'session',
      };
    }
    _sessionOwned = true;
    final transaction = ++_transaction;
    try {
      final response = await _map('launch', {
        'transaction': transaction,
        'coreId': coreId,
        'gamePath': gamePath,
        'gameTitle': gameTitle,
        'locale': locale,
        'uiText': uiText,
      });
      if (response['success'] != true &&
          response['sessionOwned'] == false &&
          transaction == _transaction) {
        _sessionOwned = false;
      }
      return response;
    } catch (_) {
      // A channel failure after native creation must not silently permit a
      // second launch. Reconcile against native ownership before releasing.
      try {
        final state = await diagnostics();
        final nativeTransaction = state['transaction'];
        final ownership = state['sessionOwned'];
        if (transaction == _transaction &&
            ownership is bool &&
            (nativeTransaction == null || nativeTransaction == transaction)) {
          _sessionOwned = ownership;
        }
      } catch (_) {
        // Keep ownership until stop/sessionEnded can safely reconcile it.
      }
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> stop() async {
    final transaction = _transaction;
    final response = await _map('stop', {'transaction': transaction});
    if (transaction == _transaction && response['sessionOwned'] == false) {
      _sessionOwned = false;
    }
    return response;
  }

  static Future<Map<String, dynamic>> showMenu() =>
      _map('showMenu', {'transaction': _transaction});
  static Future<Map<String, dynamic>> command(Map<String, dynamic> request) =>
      _map('command', {'transaction': _transaction, 'request': request});
}
