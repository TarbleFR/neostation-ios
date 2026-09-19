import 'package:flutter/services.dart';

class Armsx2InternalBridge {
  Armsx2InternalBridge._();

  static const MethodChannel _channel =
      MethodChannel('neostation/armsx2_internal');
  static const MethodChannel _jitChannel =
      MethodChannel('neostation/armsx2_jit');

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
  }) async => Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('launch', {
              'transaction': transaction,
              'gamePath': gamePath,
              'dataPath': dataPath,
              'biosDirectory': biosDirectory,
              if (biosFilename != null) 'biosFilename': biosFilename,
            }) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> stop() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('stop') ??
            const <String, dynamic>{},
      );
}
