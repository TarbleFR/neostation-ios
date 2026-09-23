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

  static Future<Map<String, dynamic>> diagnostics() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('diagnostics') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> launch({
    required String gamePath,
    required String supportPath,
    required String cachePath,
  }) async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>('launch', {
          'gamePath': gamePath,
          'supportPath': supportPath,
          'cachePath': cachePath,
        }) ??
        const <String, dynamic>{},
  );

  static Future<bool> stop() async =>
      await _channel.invokeMethod<bool>('stop') ?? false;
}
