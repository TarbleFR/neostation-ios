import 'dart:async';

import 'package:flutter/services.dart';

/// Flutter boundary for the optional, lazily loaded Dusklight runtime.
///
/// Keeping the native Core behind a method channel means NeoStation can show
/// and populate its Ports library without loading Dusklight at app startup.
class DusklightInternalBridge {
  DusklightInternalBridge._();

  static const MethodChannel _channel = MethodChannel(
    'neostation/dusklight_internal',
  );

  static final _sessionEvents = StreamController<Map<String, dynamic>>.broadcast();
  static bool _eventHandlerInstalled = false;
  static bool _didEndSession = false;
  static int _transaction = 0;
  static bool _sessionOwned = false;

  static void _ensureEventHandler() {
    if (_eventHandlerInstalled) return;
    _eventHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'sessionEnded') return;
      final arguments = call.arguments;
      if (arguments is! Map || arguments['transaction'] != _transaction) return;
      _didEndSession = true;
      _sessionOwned = false;
      _sessionEvents.add(Map<String, dynamic>.from(arguments));
    });
  }

  static Stream<Map<String, dynamic>> get sessionEvents {
    _ensureEventHandler();
    return _sessionEvents.stream;
  }

  /// Covers native closure while launch bookkeeping still awaits the database.
  static bool get didEndSession => _didEndSession;

  static Future<Map<String, dynamic>> diagnostics() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('diagnostics') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> launch({
    required String gamePath,
    required String supportPath,
    required String cachePath,
  }) async {
    _ensureEventHandler();
    if (_sessionOwned) {
      return const {
        'success': false,
        'errorCode': 'DUSKLIGHT_SESSION_ACTIVE',
        'stage': 'session',
        'message': 'A Dusklight session is already starting or running.',
      };
    }
    _sessionOwned = true;
    _didEndSession = false;
    final transaction = ++_transaction;
    try {
      final response = Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('launch', {
          'transaction': transaction,
          'gamePath': gamePath,
          'supportPath': supportPath,
          'cachePath': cachePath,
        }) ??
            const <String, dynamic>{},
      );
      if (response['success'] != true &&
          response['errorCode'] != 'DUSKLIGHT_FIRST_FRAME_TIMEOUT') {
        _sessionOwned = false;
      }
      // A timeout requests native stop; ownership lasts until sessionEnded.
      return response;
    } catch (_) {
      _sessionOwned = false;
      rethrow;
    }
  }

  static Future<bool> stop() async =>
      await _channel.invokeMethod<bool>('stop') ?? false;
}
