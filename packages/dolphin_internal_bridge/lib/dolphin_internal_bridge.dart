import 'package:flutter/services.dart';

/// Native channel owned by NeoStation's in-process Dolphin integration.
///
/// The embedded JIT helper targets NeoStation's own PID. `prepareHostJit` is
/// intentionally reusable by another in-process engine such as RPCS3; it does
/// not launch, inspect or modify an external emulator application.
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

  static Future<Map<String, dynamic>> prepareHostJit({
    required String pairingFilePath,
    String mode = 'legacy',
  }) async {
    return Map<String, dynamic>.from(
      await _channel.invokeMapMethod<String, dynamic>('prepareHostJit', {
            'pairingFilePath': pairingFilePath,
            'mode': mode,
          }) ??
          const <String, dynamic>{},
    );
  }

  static Future<void> pause() => _channel.invokeMethod<void>('pause');
  static Future<void> resume() => _channel.invokeMethod<void>('resume');
  static Future<void> stop() => _channel.invokeMethod<void>('stop');
}
