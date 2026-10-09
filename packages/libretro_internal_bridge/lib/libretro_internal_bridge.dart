import 'dart:async';

import 'package:flutter/services.dart';

/// Dart side of the embedded libretro host (`neostation/libretro_internal`).
class LibretroInternalBridge {
  LibretroInternalBridge._();

  static const MethodChannel _channel = MethodChannel(
    'neostation/libretro_internal',
  );

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

  /// Emits once a launched game has been closed and its view dismissed.
  static Stream<Map<String, dynamic>> get sessionEvents {
    _ensureEventHandler();
    return _sessionEvents.stream;
  }

  static Future<List<String>> availableCores() async {
    final cores = await _channel.invokeListMethod<String>('availableCores');
    return cores ?? const <String>[];
  }

  static Future<Map<String, dynamic>> diagnostics() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('diagnostics') ??
            const <String, dynamic>{},
      );

  static Future<bool> isSessionActive() async =>
      await _channel.invokeMethod<bool>('isSessionActive') ?? false;

  static Future<Map<String, dynamic>> launch(Map<String, Object?> request) async {
    _ensureEventHandler();
    return Map<String, dynamic>.from(
      await _channel.invokeMapMethod<String, dynamic>('launch', request) ??
          const <String, dynamic>{},
    );
  }

  static Future<Map<String, dynamic>> stop() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('stop') ??
            const <String, dynamic>{},
      );
}
