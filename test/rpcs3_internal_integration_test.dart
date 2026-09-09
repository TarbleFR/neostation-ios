import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RPCS3 internal engine contracts', () {
    test('RPCS3 JIT path is isolated from Dolphin and standalone RPCS3', () {
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();
      final hostJit = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm',
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

    test('maintenance mode installs firmware/content without requiring JIT', () {
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();
      final bridge = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
      ).readAsStringSync();

      expect(service, contains('ensureManagementInitialized'));
      expect(service, contains('if (gameplay) await _ensureJit();'));
      expect(service, contains('expandedJitRegion: gameplay'));
      expect(service, contains('await ensureManagementInitialized();'));
      expect(service, contains('Rpcs3InternalBridge.installFirmware'));
      expect(service, contains('_stageFirmware'));
      expect(bridge, contains('@"shutdown"'));
      expect(bridge, contains('initializedWithExpandedJit'));
    });

    test('launch boots the selected title directly through RPCS3 Core', () {
      final plugin = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
      ).readAsStringSync();
      final launcher = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();

      expect(plugin, contains('rpcs3_ios_boot_game'));
      expect(plugin, contains('self->_api.boot_game'));
      expect(plugin, contains('@"launchGame"'));
      expect(plugin, contains('!self.initializedWithExpandedJit'));
      expect(launcher, contains('Rpcs3InternalService.launchTitle'));
      expect(launcher, isNot(contains('openJitRequest')));
      expect(launcher, isNot(contains('com.xitrix.RPCS3')));
      expect(service, contains('await ensureGameplayInitialized();'));

      // The standalone SwiftUI gate is not embedded or recreated. Game launch
      // goes directly to rpcs3_ios_boot_game after firmware + JIT readiness.
      expect(plugin, isNot(contains('setTitle:@"Start"')));
      expect(plugin, isNot(contains('setTitle:@"Commencer"')));
      expect(service, isNot(contains('com.xitrix.RPCS3')));
    });

    test('firmware remains mandatory before direct boot', () {
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();
      final firmwareCheck = service.indexOf("'firmwareRequired'");
      final gameplayInit = service.indexOf('await ensureGameplayInitialized();');
      final launchCall = service.indexOf('Rpcs3InternalBridge.launchGame');

      expect(firmwareCheck, greaterThanOrEqualTo(0));
      expect(gameplayInit, greaterThan(firmwareCheck));
      expect(launchCall, greaterThan(gameplayInit));
    });

    test('PS3 library exposes emulator manager and all import actions', () {
      final widget = File(
        'lib/widgets/rpcs3_internal_playlist_actions.dart',
      ).readAsStringSync();
      final manager = File(
        'lib/screens/rpcs3_manager_screen.dart',
      ).readAsStringSync();

      expect(widget, contains("value: 'open'"));
      expect(widget, contains('Ouvrir RPCS3'));
      expect(widget, contains('Rpcs3ManagerScreen'));
      expect(widget, contains("value: 'games'"));
      expect(widget, contains("value: 'folder'"));
      expect(widget, contains("value: 'firmware'"));
      expect(widget, contains('Importer le firmware PS3'));
      expect(manager, contains('rpcs3-manager-firmware'));
      expect(manager, contains('rpcs3-manager-games'));
      expect(manager, contains('rpcs3-manager-folder'));
      expect(manager, isNot(contains('Start')));
      expect(manager, isNot(contains('Commencer')));
    });
  });
}
