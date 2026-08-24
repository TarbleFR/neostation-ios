import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS gamepad bridge discovers connected pads and emits canonical keys', () {
    final listener = File(
      'packages/gamepads_darwin/ios/Classes/GamepadsListener.swift',
    ).readAsStringSync();
    final plugin = File(
      'packages/gamepads_darwin/ios/Classes/GamepadsIosPlugin.swift',
    ).readAsStringSync();
    final translator = File(
      'lib/utils/gamepad_translator.dart',
    ).readAsStringSync();

    expect(listener, contains('GCController.controllers()'));
    expect(listener, contains('gamepad.valueChangedHandler'));
    expect(listener, contains('firstIndex(of: gamepad)'));

    expect(plugin, isNot(contains('sfSymbolsName')));
    expect(plugin, contains('(\"dpadup\",'));
    expect(plugin, contains('(\"dpaddown\",'));
    expect(plugin, contains('(\"leftthumbstickx\",'));
    expect(plugin, contains('(\"a\", gamepad.buttonA.value)'));

    expect(translator, contains('Platform.isWindows || Platform.isIOS'));
    expect(translator, contains('_translateNamedGamepadKey'));
    expect(translator, contains("case 'dpadup':"));
    expect(translator, contains("case 'leftthumbstickx':"));
    expect(translator, contains("case 'home':"));
  });
}
