import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RPCS3 uses a third isolated StikJIT path', () {
    final launcher = File(
      'lib/services/rpcs3_launch_service.dart',
    ).readAsStringSync();
    expect(
      launcher,
      contains('JitBackendPreferenceService.useStikDebugFallback()'),
    );
    expect(launcher, contains('StikJitRpcs3Service.isExperimentalEnabled'));
    expect(launcher, contains('StikJitRpcs3Service.launch'));
    expect(launcher, contains('ExternalFolderAccess.openJitRequest'));

    final service = File(
      'lib/services/stikjit_rpcs3_service.dart',
    ).readAsStringSync();
    expect(service, contains('NEOSTATION_EXPERIMENTAL_STIKJIT_RPCS3'));
    expect(service, contains("defaultValue: 'com.xitrix.RPCS3'"));
    expect(service, contains('enableRpcs3Jit'));
    expect(service, contains('stikjit_rpcs3_debug.txt'));
  });

  test('RPCS3 registration wraps existing MeloNX and ARMSX2 registration', () {
    final wrapper = File(
      'packages/stikjit_bridge/ios/Classes/'
      'NeoStationStikjitBridgePluginV2.swift',
    ).readAsStringSync();
    expect(
      wrapper,
      contains('NeoStationStikjitBridgePlugin.register(with: registrar)'),
    );
    expect(
      wrapper,
      contains('StikjitRpcs3BridgePlugin.register(with: registrar)'),
    );

    final existingComposite = File(
      'packages/stikjit_bridge/ios/Classes/'
      'NeoStationStikjitBridgePlugin.swift',
    ).readAsStringSync();
    expect(
      existingComposite,
      contains('StikjitBridgePluginV2.register(with: registrar)'),
    );
    expect(
      existingComposite,
      contains('StikjitArmsx2BridgePlugin.register(with: registrar)'),
    );
    expect(existingComposite, isNot(contains('StikjitRpcs3BridgePlugin')));

    final pluginManifest = File(
      'packages/stikjit_bridge/pubspec.yaml',
    ).readAsStringSync();
    expect(
      pluginManifest,
      contains('pluginClass: NeoStationStikjitBridgePluginV2'),
    );
  });

  test('native RPCS3 bridge has its own channel and bundle discovery', () {
    final nativeBridge = File(
      'packages/stikjit_bridge/ios/Classes/'
      'StikjitRpcs3BridgePlugin.swift',
    ).readAsStringSync();
    expect(nativeBridge, contains('neostation/stikjit_rpcs3'));
    expect(nativeBridge, contains('enableRpcs3Jit'));
    expect(nativeBridge, contains('launchRpcs3Suspended'));
    expect(nativeBridge, contains('STATE: RPCS3_JIT_READY'));

    final runtime = File(
      'packages/stikjit_bridge/ios/Classes/Rpcs3IdeviceRuntime.swift',
    ).readAsStringSync();
    expect(runtime, contains('discoverRpcs3BundleId'));
    expect(runtime, contains('installation_proxy_get_apps'));
    expect(runtime, contains('process_control_launch_app'));
    expect(runtime, contains('rpcs3NotFound'));
  });

  test('Dart bridge exposes RPCS3 without changing existing methods', () {
    final bridge = File(
      'packages/stikjit_bridge/lib/stikjit_bridge.dart',
    ).readAsStringSync();
    expect(bridge, contains('enableMeloNxJit'));
    expect(bridge, contains('enableArmsx2Jit'));
    expect(bridge, contains('enableRpcs3Jit'));
    expect(bridge, contains('neostation/stikjit_rpcs3'));
  });
}
