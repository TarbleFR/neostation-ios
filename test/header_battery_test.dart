import 'package:flutter_test/flutter_test.dart';
import 'package:neoplay_bridge/neoplay_bridge.dart';
import 'package:neostation/services/controller_battery_service.dart';
import 'package:neostation/widgets/header_battery.dart';

/// The header's battery: the connected controller's (iOS) rather than the
/// phone's, never a made-up level.
void main() {
  NeoPlayControllerBattery pad(int player, int? percent, {String charge = 'discharging', String name = 'Xbox Wireless Controller'}) =>
      NeoPlayControllerBattery(player: player, name: name, percent: percent, charge: charge, low: false);

  test('a connected controller replaces the device battery', () {
    final battery = HeaderBattery.choose(controllers: [pad(1, 62)], deviceLevel: 100, deviceCharging: true)!;
    expect(battery.controller, isTrue);
    expect(battery.percent, 62);
    expect(battery.charging, isFalse, reason: 'the phone charging says nothing about the controller');
  });

  test('the first player\'s controller is shown', () {
    final battery = HeaderBattery.choose(
      controllers: [pad(2, 10, name: 'Pad B'), pad(1, 80)],
      deviceLevel: 40,
      deviceCharging: false,
    )!;
    expect(battery.percent, 80);
  });

  test('a controller that does not report its level is shown as unknown, not 100%', () {
    final battery = HeaderBattery.choose(controllers: [pad(1, null, charge: 'unknown')], deviceLevel: 100, deviceCharging: false)!;
    expect(battery.controller, isTrue);
    expect(battery.percent, isNull);
  });

  test('a charging controller is marked as charging', () {
    final battery = HeaderBattery.choose(controllers: [pad(1, 35, charge: 'charging')], deviceLevel: 90, deviceCharging: false)!;
    expect(battery.charging, isTrue);
  });

  test('without a controller the device battery is shown, and nothing when it is unknown', () {
    final device = HeaderBattery.choose(controllers: const [], deviceLevel: 47, deviceCharging: true)!;
    expect(device.controller, isFalse);
    expect(device.percent, 47);
    expect(device.charging, isTrue);
    expect(HeaderBattery.choose(controllers: const [], deviceLevel: -1, deviceCharging: false), isNull);
  });

  test('the native payload is decoded without inventing a level', () {
    final reported = NeoPlayControllerBattery.fromMap({
      'player': 1,
      'name': 'Xbox Wireless Controller',
      'percent': 70,
      'charge': 'discharging',
      'low': false,
    });
    expect(reported.percent, 70);
    expect(reported.charging, isFalse);
    final unknown = NeoPlayControllerBattery.fromMap({'player': 2, 'name': 'Pad', 'percent': null, 'charge': 'unknown', 'low': false});
    expect(unknown.percent, isNull);
    expect(unknown.charge, 'unknown');
  });

  test('each change is logged with the level iOS reports', () {
    expect(ControllerBatteryService.describe(const []), 'no controller');
    expect(
      ControllerBatteryService.describe([pad(1, 100), pad(2, null, charge: 'unknown', name: 'Pad')]),
      'player 1 "Xbox Wireless Controller" 100% discharging; player 2 "Pad" level not reported unknown',
    );
  });
}
