import 'package:flutter/foundation.dart';
import 'package:neoplay_bridge/neoplay_bridge.dart';

/// What the header's battery indicator shows: the battery of the connected
/// controller when there is one (iOS, the first player's), else the device's
/// own battery (a handheld's controller is the device).
@immutable
class HeaderBattery {
  const HeaderBattery._({
    required this.controller,
    required this.percent,
    required this.charging,
  });

  /// The reading belongs to a controller, not to the device.
  final bool controller;

  /// Null when the controller does not report a level: shown as "—", never
  /// as a made-up percentage.
  final int? percent;
  final bool charging;

  /// Null when nothing can be shown (no controller, device level unknown).
  static HeaderBattery? choose({
    required List<NeoPlayControllerBattery> controllers,
    required int deviceLevel,
    required bool deviceCharging,
  }) {
    if (controllers.isNotEmpty) {
      final first = controllers.reduce((a, b) => b.player < a.player ? b : a);
      return HeaderBattery._(controller: true, percent: first.percent, charging: first.charging);
    }
    if (deviceLevel < 0) return null;
    return HeaderBattery._(controller: false, percent: deviceLevel, charging: deviceCharging);
  }
}
