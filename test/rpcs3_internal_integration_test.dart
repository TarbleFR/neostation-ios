import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RPCS3 internal engine contracts', () {
    test('RPCS3 JIT path is isolated from Dolphin and standalone RPCS3', () {
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();
      final hostJit = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3HostJit.mm',
      ).readAsStringSync();
      final helper = File(
        'packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift',
      ).readAsStringSync();

      expect(service, contains('Rpcs3InternalBridge.prepareJit'));
      expect(service, isNot(contains('dolphin_internal_bridge')));
      expect(service, isNot(contains('DolphinInternalBridge')));
      expect(hostJit, contains('com.neogamelab.neostation.rpcs3-jit-request'));
      expect(hostJit, contains('NeoStationRPCS3JITHelper'));
      expect(hostJit, isNot(contains('Dolphin')));
      expect(helper, contains('script: .universal'));
      expect(helper, isNot(contains('script: .legacy')));
      expect(helper, isNot(contains('com.xitrix.RPCS3')));
    });

    test('launch boots the selected title directly through RPCS3 Core', () {
      final plugin = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
      ).readAsStringSync();
      final launcher = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();

      expect(plugin, contains('rpcs3_ios_boot_game'));
      expect(plugin, contains('self->_api.boot_game'));
      expect(plugin, contains('@"launchGame"'));
      expect(launcher, contains('Rpcs3InternalService.launchTitle'));
      expect(launcher, isNot(contains('openJitRequest')));
      expect(launcher, isNot(contains('com.xitrix.RPCS3')));
    });

    test('firmware remains mandatory before direct boot', () {
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();
      final firmwareCheck = service.indexOf("'firmwareRequired'");
      final launchCall = service.indexOf('Rpcs3InternalBridge.launchGame');

      expect(firmwareCheck, greaterThanOrEqualTo(0));
      expect(launchCall, greaterThan(firmwareCheck));
      expect(service, contains('Rpcs3InternalBridge.installFirmware'));
    });

    test('PS3 library exposes game and firmware imports', () {
      final widget = File(
        'lib/widgets/rpcs3_internal_playlist_actions.dart',
      ).readAsStringSync();

      expect(widget, contains("value: 'games'"));
      expect(widget, contains("value: 'folder'"));
      expect(widget, contains("value: 'firmware'"));
      expect(widget, contains('Importer le firmware PS3'));
      expect(widget, contains('Firmware requis'));
    });
  });
}
