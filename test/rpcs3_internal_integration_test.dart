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

    test('JIT and arena policy are ready before RPCS3 Core dlopen', () {
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();
      final bridge = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
      ).readAsStringSync();

      final serviceJit = service.indexOf('await _ensureJit();');
      final serviceInitialize = service.indexOf('Rpcs3InternalBridge.initialize');
      expect(serviceJit, greaterThanOrEqualTo(0));
      expect(serviceInitialize, greaterThan(serviceJit));

      expect(bridge, contains('RPCS3HostIsDebugged'));
      expect(bridge, contains('RPCS3ProbeExecutableMemory'));
      expect(bridge, contains('RPCS3_IOS_EXPANDED_JIT_ARENA'));
      final setenvIndex = bridge.indexOf(
        'setenv("RPCS3_IOS_EXPANDED_JIT_ARENA"',
      );
      final dlopenIndex = bridge.indexOf('dlopen(path.fileSystemRepresentation');
      expect(setenvIndex, greaterThanOrEqualTo(0));
      expect(dlopenIndex, greaterThan(setenvIndex));

      // Diagnostics must never be the first code path that loads RPCS3.
      final diagnosticsStart = bridge.indexOf(
        'if ([call.method isEqualToString:@"diagnostics"])',
      );
      final initializeStart = bridge.indexOf(
        'if ([call.method isEqualToString:@"initialize"])',
      );
      final diagnosticsBlock = bridge.substring(diagnosticsStart, initializeStart);
      expect(diagnosticsBlock, isNot(contains('loadCoreWithExpandedJit')));
    });

    test('firmware and game imports use the same validated RPCS3 runtime', () {
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();

      expect(service, contains('ensureManagementInitialized'));
      expect(service, contains('expandedJitRegion: true'));
      expect(service, contains('Rpcs3InternalBridge.installFirmware'));
      expect(service, contains('_stageFirmware'));
      expect(service, isNot(contains('expandedJitRegion: gameplay')));
      expect(service, isNot(contains('if (gameplay) await _ensureJit();')));
    });

    test('RPCS3 signing capabilities match the original iOS runtime needs', () {
      final config = File(
        'build-utils/configure_rpcs3_ios_v2.py',
      ).readAsStringSync();

      expect(config, contains("'get-task-allow': True"));
      expect(
        config,
        contains("'com.apple.developer.kernel.extended-virtual-addressing': True"),
      );
      expect(
        config,
        contains("'com.apple.developer.kernel.increased-memory-limit': True"),
      );
      expect(
        config,
        contains("'com.apple.developer.kernel.increased-debugging-memory-limit': True"),
      );
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
      final gameplayInit = service.indexOf('await ensureGameplayInitialized();');
      final firmwareCheck = service.indexOf("'firmwareRequired'");
      final launchCall = service.indexOf('Rpcs3InternalBridge.launchGame');

      expect(gameplayInit, greaterThanOrEqualTo(0));
      expect(firmwareCheck, greaterThan(gameplayInit));
      expect(launchCall, greaterThan(firmwareCheck));
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
