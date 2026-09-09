import 'package:flutter/services.dart';

class Rpcs3InternalBridge {
  Rpcs3InternalBridge._();

  static const MethodChannel _channel = MethodChannel('neostation/rpcs3_internal');

  static Future<Map<String, dynamic>> diagnostics() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('diagnostics') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> initialize({
    required String supportPath,
    required String cachePath,
    bool expandedJitRegion = true,
  }) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('initialize', {
              'supportPath': supportPath,
              'cachePath': cachePath,
              'expandedJitRegion': expandedJitRegion,
            }) ??
            const <String, dynamic>{},
      );

  static Future<String> firmwareVersion() async =>
      (await _channel.invokeMethod<String>('firmwareVersion')) ?? '';

  static Future<Map<String, dynamic>> installFirmware(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>(
              'installFirmware',
              {'path': path},
            ) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> installPackage(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>(
              'installPackage',
              {'path': path},
            ) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> installIso(
    String path, {
    String? keyPath,
  }) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('installIso', {
              'path': path,
              if (keyPath != null) 'keyPath': keyPath,
            }) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> installZip(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>(
              'installZip',
              {'path': path},
            ) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> installFolder(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>(
              'installFolder',
              {'path': path},
            ) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> launchGame({
    required String titleId,
    String? savestateId,
  }) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('launchGame', {
              'titleId': titleId,
              if (savestateId != null) 'savestateId': savestateId,
            }) ??
            const <String, dynamic>{},
      );

  static Future<int> emulationState() async =>
      (await _channel.invokeMethod<int>('emulationState')) ?? 0;

  static Future<bool> stop() async =>
      (await _channel.invokeMethod<bool>('stop')) ?? false;
}
