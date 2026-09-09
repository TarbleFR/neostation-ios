import 'dart:async';

import 'package:flutter/services.dart';

class Rpcs3InstallProgress {
  const Rpcs3InstallProgress({
    required this.current,
    required this.total,
    required this.detail,
  });

  final int current;
  final int total;
  final String detail;

  double? get fraction {
    if (total <= 0) return null;
    return (current / total).clamp(0.0, 1.0).toDouble();
  }
}

class Rpcs3InternalBridge {
  Rpcs3InternalBridge._();

  static const MethodChannel _channel = MethodChannel(
    'neostation/rpcs3_internal',
  );
  static const MethodChannel _jitChannel = MethodChannel(
    'neostation/rpcs3_jit',
  );
  static const MethodChannel _tuningChannel = MethodChannel(
    'neostation/rpcs3_tuning',
  );
  static const MethodChannel _documentsChannel = MethodChannel(
    'neostation/rpcs3_documents',
  );

  static final StreamController<Rpcs3InstallProgress>
  _installProgressController = StreamController<Rpcs3InstallProgress>.broadcast(
    sync: true,
  );
  static bool _callbackHandlerInstalled = false;

  static void _ensureCallbackHandler() {
    if (_callbackHandlerInstalled) return;
    _callbackHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'installProgress') return null;
      final raw = call.arguments;
      if (raw is! Map) return null;
      final current = (raw['current'] as num?)?.toInt() ?? 0;
      final total = (raw['total'] as num?)?.toInt() ?? 0;
      final detail = raw['detail']?.toString() ?? '';
      _installProgressController.add(
        Rpcs3InstallProgress(
          current: current,
          total: total,
          detail: detail,
        ),
      );
      return null;
    });
  }

  static Stream<Rpcs3InstallProgress> get installProgress {
    _ensureCallbackHandler();
    return _installProgressController.stream;
  }

  static Future<Map<String, dynamic>> diagnostics() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('diagnostics') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> jitStatus() async =>
      Map<String, dynamic>.from(
        await _jitChannel.invokeMapMethod<String, dynamic>('status') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> preflight() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('preflight') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> prepareJit({
    required String pairingFilePath,
  }) async => Map<String, dynamic>.from(
    await _jitChannel.invokeMapMethod<String, dynamic>('prepareJit', {
          'pairingFilePath': pairingFilePath,
        }) ??
        const <String, dynamic>{},
  );

  static Future<Map<String, dynamic>> initialize({
    required String supportPath,
    required String cachePath,
    bool expandedJitRegion = false,
  }) async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>('initialize', {
          'supportPath': supportPath,
          'cachePath': cachePath,
          'expandedJitRegion': expandedJitRegion,
        }) ??
        const <String, dynamic>{},
  );

  /// Call only after initialize has prepared and sealed the Core JIT arena.
  static Future<Map<String, dynamic>> completeJit() async =>
      Map<String, dynamic>.from(
        await _jitChannel.invokeMapMethod<String, dynamic>('completeJit') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> shutdown() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('shutdown') ??
            const <String, dynamic>{},
      );

  static Future<String> firmwareVersion() async =>
      (await _channel.invokeMethod<String>('firmwareVersion')) ?? '';

  static Future<Map<String, dynamic>> installFirmware(String path) async {
    _ensureCallbackHandler();
    return Map<String, dynamic>.from(
      await _channel.invokeMapMethod<String, dynamic>('installFirmware', {
            'path': path,
          }) ??
          const <String, dynamic>{},
    );
  }

  static Future<Map<String, dynamic>> installPackage(String path) async {
    _ensureCallbackHandler();
    return Map<String, dynamic>.from(
      await _channel.invokeMapMethod<String, dynamic>('installPackage', {
            'path': path,
          }) ??
          const <String, dynamic>{},
    );
  }

  static Future<Map<String, dynamic>> installIso(
    String path, {
    String? keyPath,
  }) async {
    _ensureCallbackHandler();
    return Map<String, dynamic>.from(
      await _channel.invokeMapMethod<String, dynamic>('installIso', {
            'path': path,
            if (keyPath != null) 'keyPath': keyPath,
          }) ??
          const <String, dynamic>{},
    );
  }

  static Future<Map<String, dynamic>> installZip(String path) async {
    _ensureCallbackHandler();
    return Map<String, dynamic>.from(
      await _channel.invokeMapMethod<String, dynamic>('installZip', {
            'path': path,
          }) ??
          const <String, dynamic>{},
    );
  }

  static Future<Map<String, dynamic>> installFolder(String path) async {
    _ensureCallbackHandler();
    return Map<String, dynamic>.from(
      await _channel.invokeMapMethod<String, dynamic>('installFolder', {
            'path': path,
          }) ??
          const <String, dynamic>{},
    );
  }

  static Future<List<String>?> pickGameFilesOpenInPlace() async {
    final values = await _documentsChannel.invokeListMethod<String>(
      'pickGameFiles',
    );
    return values?.toList(growable: false);
  }

  static Future<String?> pickGameFolderOpenInPlace() =>
      _documentsChannel.invokeMethod<String>('pickGameFolder');

  static Future<void> releaseScopedResources() async {
    await _documentsChannel.invokeMethod<bool>('releaseScopedResources');
  }

  static Future<Map<String, dynamic>> setSetting(
    String key,
    String value,
  ) async => Map<String, dynamic>.from(
    await _tuningChannel.invokeMapMethod<String, dynamic>('setSetting', {
          'key': key,
          'value': value,
        }) ??
        const <String, dynamic>{},
  );

  static Future<Map<String, dynamic>> setGameSetting(
    String titleId,
    String key,
    String value,
  ) async => Map<String, dynamic>.from(
    await _tuningChannel.invokeMapMethod<String, dynamic>('setGameSetting', {
          'titleId': titleId,
          'key': key,
          'value': value,
        }) ??
        const <String, dynamic>{},
  );

  static Future<Map<String, dynamic>> deleteGame(String titleId) async =>
      Map<String, dynamic>.from(
        await _tuningChannel.invokeMapMethod<String, dynamic>('deleteGame', {
              'titleId': titleId,
            }) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> abortBoot() async =>
      Map<String, dynamic>.from(
        await _tuningChannel.invokeMapMethod<String, dynamic>('abortBoot') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> bootProgress() async =>
      Map<String, dynamic>.from(
        await _tuningChannel.invokeMapMethod<String, dynamic>('bootProgress') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> launchGame({
    required String titleId,
    String? savestateId,
  }) async => Map<String, dynamic>.from(
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
