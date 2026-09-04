import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dolphin is routed before the general iOS launcher and only for gc/wii', () {
    final launcher = File(
      'lib/services/game/game_launch_service.dart',
    ).readAsStringSync();
    expect(launcher, contains('DolphinInternalV2Service.isDolphinSystem'));
    expect(
      launcher.indexOf('DolphinInternalV2Service.isDolphinSystem'),
      lessThan(launcher.indexOf('if (Platform.isIOS)')),
    );
    expect(launcher, contains('Rpcs3LaunchService.launchTitle'));
    expect(launcher, contains('MelonxLibraryService.launchGameByRomPath'));
    expect(launcher, contains('Armsx2LibraryService.launchGameByRomPath'));
    expect(launcher, contains('RetroArchLibraryService.launchGameByRomPath'));
  });

  test('Dolphin JIT policy is legacy-only and does not alter shared StikJIT', () {
    final helper = File(
      'packages/dolphin_jit_helper/ios/Classes/DolphinJITRequestHandlerBase.swift',
    ).readAsStringSync();
    expect(helper, contains('script: .legacy'));
    expect(helper, isNot(contains('.universal')));

    for (final path in [
      'packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift',
      'packages/stikjit_bridge/ios/Classes/NeoStationStikjitBridgePlugin.swift',
      'packages/stikjit_bridge/ios/Classes/StikjitRpcs3BridgePlugin.swift',
    ]) {
      final file = File(path);
      if (file.existsSync()) {
        expect(file.readAsStringSync(), contains('script: .universal'));
      }
    }
  });

  test('Dolphin does not own generic executable extensions', () {
    final service = File(
      'lib/services/dolphin_internal_v2_service.dart',
    ).readAsStringSync();
    expect(service, isNot(contains("'elf'")));
    expect(service, isNot(contains("'dol'")));
    expect(service, contains("normalized == 'gc' || normalized == 'wii'"));
  });
}
