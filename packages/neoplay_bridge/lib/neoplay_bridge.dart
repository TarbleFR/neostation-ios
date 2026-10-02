import 'package:flutter/services.dart';

class NeoPlayBridge {
  static const _methods = MethodChannel('neostation/neoplay');
  static const _events = EventChannel('neostation/neoplay/events');
  static Stream<Map<String, dynamic>> get events => _events.receiveBroadcastStream().map((event) => Map<String, dynamic>.from(event as Map));
  static Future<Map<String, dynamic>> snapshot() async => Map<String, dynamic>.from(await _methods.invokeMapMethod<String, dynamic>('snapshot') ?? const {});
  static Future<void> configureGameHUD({required bool active, required Map<String,String> labels}) => _methods.invokeMethod<void>('configureGameHUD', {'active':active,'labels':labels});
  static Future<void> discover() => _methods.invokeMethod<void>('discover');
  static Future<void> stopDiscovery() => _methods.invokeMethod<void>('stopDiscovery');
  static Future<void> disconnect() => _methods.invokeMethod<void>('disconnect');
  static Future<void> connect({required String id, required String stopLabel, String pin = ''}) => _methods.invokeMethod<void>('connect', {'id': id, 'pin': pin, 'stopLabel': stopLabel});
}
