import 'dart:async';

import 'package:flutter/services.dart';

class Armsx2InternalBridge {
  Armsx2InternalBridge._();

  static const MethodChannel _channel =
      MethodChannel('neostation/armsx2_internal');
  static const MethodChannel _jitChannel =
      MethodChannel('neostation/armsx2_jit');

  static final StreamController<Map<String, dynamic>> _sessionEvents =
      StreamController<Map<String, dynamic>>.broadcast();
  static bool _eventHandlerInstalled = false;

  static void _ensureEventHandler() {
    if (_eventHandlerInstalled) return;
    _eventHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'sessionEnded') return;
      final arguments = call.arguments;
      _sessionEvents.add(
        arguments is Map
            ? Map<String, dynamic>.from(arguments)
            : const <String, dynamic>{'reason': 'unknown'},
      );
    });
  }

  static Stream<Map<String, dynamic>> get sessionEvents {
    _ensureEventHandler();
    return _sessionEvents.stream;
  }

  static Future<Map<String, dynamic>> prepareJit({
    required String pairingFilePath,
  }) async => Map<String, dynamic>.from(
        await _jitChannel.invokeMapMethod<String, dynamic>('prepareJit', {
              'pairingFilePath': pairingFilePath,
            }) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> diagnostics() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('diagnostics') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> launch({
    required int transaction,
    required String gamePath,
    required String dataPath,
    required String biosDirectory,
    String? biosFilename,
    bool bootBios = false,
    String uiLocale = 'en',
  }) async {
    _ensureEventHandler();
    return Map<String, dynamic>.from(
      await _channel.invokeMapMethod<String, dynamic>('launch', {
            'transaction': transaction,
            'gamePath': gamePath,
            'bootBios': bootBios,
            'dataPath': dataPath,
            'biosDirectory': biosDirectory,
            'uiLocale': uiLocale,
            if (biosFilename != null) 'biosFilename': biosFilename,
          }) ??
          const <String, dynamic>{},
    );
  }

  static Future<Map<String, dynamic>> stop() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('stop') ??
            const <String, dynamic>{},
      );
}
