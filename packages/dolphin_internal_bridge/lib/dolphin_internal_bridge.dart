import 'package:flutter/services.dart';

/// Native channel owned exclusively by NeoStation's GameCube/Wii integration.
///
/// Application code normally uses `DolphinEmbeddedService`; this minimal API is
/// kept public so diagnostics and lifecycle tests can query the native runtime
/// without touching the launch contracts of other emulators.
class DolphinInternalBridge {
  DolphinInternalBridge._();

  static const MethodChannel _channel = MethodChannel(
    'neostation/dolphin_internal',
  );

  static Future<Map<String, dynamic>> status() async {
    return Map<String, dynamic>.from(
      await _channel.invokeMapMethod<String, dynamic>('status') ??
          const <String, dynamic>{},
    );
  }

  static Future<void> pause() => _channel.invokeMethod<void>('pause');
  static Future<void> resume() => _channel.invokeMethod<void>('resume');
  static Future<void> stop() => _channel.invokeMethod<void>('stop');
}
