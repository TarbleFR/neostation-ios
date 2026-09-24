import 'dart:async';

import 'package:flutter/services.dart';

class KartPadInternalBridge {
  KartPadInternalBridge._();

  static const MethodChannel _channel =
      MethodChannel('neostation/kartpad_internal');
  static final _sessionEvents =
      StreamController<Map<String, dynamic>>.broadcast();

  static bool _handlerInstalled = false;
  static bool _didEndSession = false;
  static bool _didReleaseRuntime = false;
  static bool _sessionOwned = false;
  static int _transaction = 0;

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'sessionEnded') return;
      final arguments = call.arguments;
      if (arguments is! Map || arguments['transaction'] != _transaction) return;
      _didEndSession = true;
      _didReleaseRuntime = arguments['runtimeReleased'] == true;
      _sessionOwned = false;
      _sessionEvents.add(Map<String, dynamic>.from(arguments));
    });
  }

  static Stream<Map<String, dynamic>> get sessionEvents {
    _ensureHandler();
    return _sessionEvents.stream;
  }

  static bool get didEndSession => _didEndSession;
  static bool get didReleaseRuntime => _didReleaseRuntime;

  static Future<Map<String, dynamic>> diagnostics() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('diagnostics') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> launch({
    required String gamePath,
    required String supportPath,
    required String cachePath,
    Map<String, String> uiText = const {},
  }) async {
    _ensureHandler();
    if (_sessionOwned) {
      return const {
        'success': false,
        'errorCode': 'KARTPAD_SESSION_ACTIVE',
        'stage': 'session',
        'message': 'A KartPad session is already starting or running.',
      };
    }
    _sessionOwned = true;
    _didEndSession = false;
    _didReleaseRuntime = false;
    final transaction = ++_transaction;
    try {
      final response = Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('launch', {
              'transaction': transaction,
              'gamePath': gamePath,
              'supportPath': supportPath,
              'cachePath': cachePath,
              'uiText': uiText,
            }) ??
            const <String, dynamic>{},
      );
      if (response['success'] != true &&
          response['errorCode'] != 'KARTPAD_FIRST_FRAME_TIMEOUT') {
        _sessionOwned = false;
      }
      return response;
    } catch (_) {
      _sessionOwned = false;
      rethrow;
    }
  }

  static Future<bool> stop() async =>
      await _channel.invokeMethod<bool>('stop') ?? false;
}
