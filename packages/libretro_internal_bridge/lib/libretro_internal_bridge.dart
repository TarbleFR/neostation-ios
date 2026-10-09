import 'dart:async';
import 'dart:typed_data';

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

  /// Frontend settings of one console as stored by the native
  /// LibretroFrontendStore in `directory`:
  /// `{"console": {key: value}, "games": {gameKey: {key: value}}}`.
  static Future<Map<String, dynamic>> frontendSettings({
    required String directory,
    required String console,
  }) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>(
              'frontendSettings',
              <String, Object?>{'directory': directory, 'console': console},
            ) ??
            const <String, dynamic>{},
      );

  /// Stores one frontend setting for the console (`game` null) or for one
  /// game key; a null `value` removes it at that scope. The native store is
  /// the only writer of the files. False when the value was refused.
  static Future<bool> setFrontendSetting({
    required String directory,
    required String console,
    String? game,
    required String key,
    Object? value,
  }) async =>
      await _channel.invokeMethod<bool>('setFrontendSetting', <String, Object?>{
        'directory': directory,
        'console': console,
        'game': game,
        'key': key,
        'value': value,
      }) ??
      false;

  /// Parses an unpacked skin with the native parser:
  /// `{"ok": true, "summary": {identifier, name, author, consoles,
  /// gameTypeIdentifier, orientations, warnings, debug}}` or
  /// `{"ok": false, "error": "SKIN_..."}`.
  static Future<Map<String, dynamic>> inspectSkin({
    required String directory,
    required Map<String, Object?> consoleGeometry,
  }) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>(
              'inspectSkin',
              <String, Object?>{
                'directory': directory,
                'consoleGeometry': consoleGeometry,
              },
            ) ??
            const <String, dynamic>{'ok': false},
      );

  /// PNG preview of a skin (`skinDirectory` null for NeoStation's default
  /// skin of `console`) in one orientation ("portrait" or "landscape") at
  /// `width` x `height` points; null when it cannot be drawn.
  static Future<Uint8List?> skinPreview({
    String? skinDirectory,
    required String console,
    required String orientation,
    required double width,
    required double height,
    required Map<String, Object?> consoleGeometry,
    required String cacheDirectory,
    double? scale,
  }) =>
      _channel.invokeMethod<Uint8List>('skinPreview', <String, Object?>{
        'skinDirectory': skinDirectory,
        'console': console,
        'orientation': orientation,
        'width': width,
        'height': height,
        'consoleGeometry': consoleGeometry,
        'cacheDirectory': cacheDirectory,
        if (scale != null) 'scale': scale,
      });

  /// Before a skin is deleted or replaced: removes its selections, touch
  /// remaps and layouts from every console file in `directory` (the frontend
  /// directory) and its cached images under `cacheDirectory`.
  static Future<void> forgetSkin({
    required String directory,
    required String skinId,
    required String skinDirectory,
    required String cacheDirectory,
  }) async {
    await _channel.invokeMethod<Object?>('forgetSkin', <String, Object?>{
      'directory': directory,
      'skinId': skinId,
      'skinDirectory': skinDirectory,
      'cacheDirectory': cacheDirectory,
    });
  }
}
