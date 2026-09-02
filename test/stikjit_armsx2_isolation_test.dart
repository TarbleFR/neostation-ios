import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ARMSX2 uses a second StikJIT path without changing MeloNX routing', () {
    final shortcut = File(
      'lib/services/ios_shortcut_jit_launch_service.dart',
    ).readAsStringSync();
    expect(shortcut, contains('StikJitMeloNxService.launch(gameUrl: input)'));
    expect(shortcut, contains('StikJitArmsx2Service.launch(gameUrl: input)'));
    expect(shortcut, contains('shortcutName == melonxShortcutName'));
    expect(shortcut, contains('shortcutName == armsx2ShortcutName'));

    final melonx = File(
      'lib/services/stikjit_melonx_service.dart',
    ).readAsStringSync();
    expect(melonx, contains('enableMeloNxJit'));
    expect(melonx, isNot(contains('enableArmsx2Jit')));
    expect(melonx, isNot(contains('NEOSTATION_EXPERIMENTAL_STIKJIT_ARMSX2')));

    final armsx2 = File(
      'lib/services/stikjit_armsx2_service.dart',
    ).readAsStringSync();
    expect(armsx2, contains('NEOSTATION_EXPERIMENTAL_STIKJIT_ARMSX2'));
    expect(armsx2, contains("defaultValue: 'com.armsx2.ios'"));
    expect(armsx2, contains('enableArmsx2Jit'));
    expect(armsx2, contains('stikjit_armsx2_debug.txt'));
  });

  test('native ARMSX2 bridge is registered beside the untouched MeloNX bridge', () {
    final composite = File(
      'packages/stikjit_bridge/ios/Classes/'
      'NeoStationStikjitBridgePlugin.swift',
    ).readAsStringSync();
    expect(composite, contains('StikjitBridgePluginV2.register(with: registrar)'));
    expect(composite, contains('neostation/stikjit_armsx2'));
    expect(composite, contains('enableArmsx2Jit'));
    expect(composite, contains('launchArmsx2Suspended'));

    final melonxNative = File(
      'packages/stikjit_bridge/ios/Classes/StikjitBridgePluginV2.swift',
    ).readAsStringSync();
    expect(melonxNative, contains('enableMeloNxJit'));
    expect(melonxNative, isNot(contains('enableArmsx2Jit')));
    expect(melonxNative, isNot(contains('stikjit_armsx2')));

    final pluginManifest = File(
      'packages/stikjit_bridge/pubspec.yaml',
    ).readAsStringSync();
    expect(pluginManifest, contains('pluginClass: NeoStationStikjitBridgePlugin'));
  });
}
