import 'package:flutter/services.dart';

/// One connected controller's battery as iOS reports it. [percent] is null
/// when the controller does not report a level (never a made-up value).
class NeoPlayControllerBattery {
  const NeoPlayControllerBattery({
    required this.player,
    required this.name,
    required this.percent,
    required this.charge,
    required this.low,
  });

  factory NeoPlayControllerBattery.fromMap(Map<Object?, Object?> map) => NeoPlayControllerBattery(
        player: (map['player'] as num?)?.toInt() ?? 1,
        name: map['name'] as String? ?? '',
        percent: (map['percent'] as num?)?.toInt(),
        charge: map['charge'] as String? ?? 'unknown',
        low: map['low'] as bool? ?? false,
      );

  final int player;
  final String name;
  final int? percent;

  /// unknown, discharging, charging or full.
  final String charge;
  final bool low;

  bool get charging => charge == 'charging';
}

class NeoPlayBridge {
  static const _methods = MethodChannel('neostation/neoplay');
  static const _events = EventChannel('neostation/neoplay/events');
  static const _controllerBatteries = EventChannel('neostation/neoplay/controller_battery');

  /// The connected controllers' batteries (iOS): the current list first, then
  /// every change.
  static Stream<List<NeoPlayControllerBattery>> get controllerBatteries =>
      _controllerBatteries.receiveBroadcastStream().map((event) => [
            for (final item in (event as List<Object?>? ?? const <Object?>[]))
              NeoPlayControllerBattery.fromMap(Map<Object?, Object?>.from(item as Map)),
          ]);
  static Stream<Map<String, dynamic>> get events => _events.receiveBroadcastStream().map((event) => Map<String, dynamic>.from(event as Map));
  static Future<Map<String, dynamic>> snapshot() async => Map<String, dynamic>.from(await _methods.invokeMapMethod<String, dynamic>('snapshot') ?? const {});
  static Future<void> configureGameHUD({required bool active, required Map<String,String> labels}) => _methods.invokeMethod<void>('configureGameHUD', {'active':active,'labels':labels});
  static Future<void> discover() => _methods.invokeMethod<void>('discover');
  static Future<void> stopDiscovery() => _methods.invokeMethod<void>('stopDiscovery');
  static Future<void> disconnect() => _methods.invokeMethod<void>('disconnect');
  static Future<void> connect({required String id, required String stopLabel, String pin = ''}) => _methods.invokeMethod<void>('connect', {'id': id, 'pin': pin, 'stopLabel': stopLabel});
}
