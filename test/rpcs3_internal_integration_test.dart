import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RPCS3 internal engine contracts', () {
    test('RPCS3 JIT path is isolated from Dolphin and standalone RPCS3', () {
      final service = File('lib/services/rpcs3_internal_service.dart')
          .readAsStringSync();
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

    test('only legacy JIT may reuse the persistent debugged flag', () {
      final service = File('lib/services/rpcs3_internal_service.dart')
          .readAsStringSync();

      final statusIndex = service.indexOf(
        'final current = await _jitStatus();',
      );
      final debuggedIndex = service.indexOf("current['debugged'] == true");
      final pairingIndex = service.indexOf(
        'PairingFileService.hasStoredPairingFile',
      );
      final prepareIndex = service.indexOf('Rpcs3InternalBridge.prepareJit');

      expect(statusIndex, greaterThanOrEqualTo(0));
      expect(debuggedIndex, greaterThan(statusIndex));
      expect(pairingIndex, greaterThan(debuggedIndex));
      expect(prepareIndex, greaterThan(pairingIndex));
      expect(service, contains('static Future<void>? _jitPreparation'));
      expect(service, contains("'jitTimeout'"));
      expect(service, contains("current['requiresCoreHandshake'] != true"));
      expect(service, contains('Duration(minutes: 11)'));
      expect(service, isNot(contains('Duration(seconds: 90)')));
    });

    test('JIT and arena policy are ready before RPCS3 Core dlopen', () {
      final service = File('lib/services/rpcs3_internal_service.dart')
          .readAsStringSync();
      final bridge = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
      ).readAsStringSync();
      final dartBridge = File(
        'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart',
      ).readAsStringSync();

      final serviceJit = service.indexOf('await _attachJitForCore();');
      final serviceInitialize = service.indexOf(
        'Rpcs3InternalBridge.initialize',
      );
      final serviceComplete = service.indexOf(
        'Rpcs3InternalBridge.completeJit',
      );
      expect(serviceJit, greaterThanOrEqualTo(0));
      expect(serviceInitialize, greaterThan(serviceJit));
      expect(serviceComplete, greaterThan(serviceInitialize));
      expect(
        service.indexOf('_initialized = true;'),
        greaterThan(serviceComplete),
      );

      expect(bridge, contains('RPCS3HostIsDebugged'));
      expect(bridge, contains('RPCS3ProbeExecutableMemory'));
      expect(bridge, contains('RPCS3JitHasActiveCoreHandshake()'));
      expect(bridge, contains('RPCS3_IOS_EXPANDED_JIT_ARENA'));
      final setenvIndex = bridge.indexOf(
        'setenv("RPCS3_IOS_EXPANDED_JIT_ARENA"',
      );
      final dlopenIndex = bridge.indexOf(
        'dlopen(path.fileSystemRepresentation',
      );
      expect(setenvIndex, greaterThanOrEqualTo(0));
      expect(dlopenIndex, greaterThan(setenvIndex));

      // Build 234 crashed after successfully preparing the optional 512 MiB
      // arena: generated ARM64 execution jumped to 0x7000000000. Keep every
      // embedded entry point on the stable standard Universal arena.
      expect(service, contains('expandedJitRegion: false'));
      expect(service, isNot(contains('expandedJitRegion: true')));
      expect(dartBridge, contains('bool expandedJitRegion = false'));
      expect(bridge, contains('BOOL expanded = NO;'));
      expect(
        bridge,
        isNot(
          contains('BOOL expanded = [args[@"expandedJitRegion"] boolValue];'),
        ),
      );

      final diagnosticsStart = bridge.indexOf(
        'if ([call.method isEqualToString:@"diagnostics"])',
      );
      final initializeStart = bridge.indexOf(
        'if ([call.method isEqualToString:@"initialize"])',
      );
      final diagnosticsBlock = bridge.substring(
        diagnosticsStart,
        initializeStart,
      );
      expect(diagnosticsBlock, isNot(contains('loadCoreWithExpandedJit')));
    });

    test('manager inspection does not leave a Universal helper waiting', () {
      final service = File('lib/services/rpcs3_internal_service.dart')
          .readAsStringSync();
      final manager = File('lib/screens/rpcs3_manager_screen.dart')
          .readAsStringSync();

      final start = service.indexOf('static Future<void> prepareManager()');
      final end = service.indexOf(
        'static Future<void> ensureJitReady()',
        start,
      );
      final inspection = service.substring(start, end);
      expect(inspection, contains('await _jitStatus()'));
      expect(inspection, isNot(contains('_attachJitForCore')));
      expect(inspection, isNot(contains('_ensureRuntime')));
      expect(manager, contains('Rpcs3InternalService.prepareManager()'));
      expect(manager, contains('RPCS3 Core'));
      expect(manager, contains('À la demande'));
      expect(
        manager,
        isNot(contains('const Center(child: CircularProgressIndicator())')),
      );
      expect(manager, contains('LinearProgressIndicator'));
      expect(manager, contains('Réessayer'));
    });

    test('Universal attach returns before completion and forces the matching script', () {
      final host = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm',
      ).readAsStringSync();
      final helper = File(
        'packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift',
      ).readAsStringSync();
      final prepare = host.substring(
        host.indexOf('if (![call.method isEqualToString:@"prepareJit"])'),
      );
      expect(prepare, contains('waitUntilAttached:kRpcs3AttachTimeout'));
      expect(prepare, isNot(contains('waitUntilFinished:')));
      expect(prepare, contains('response[@"requiresCompletion"] = @YES'));
      expect(host, contains('isEqualToString:@"completeJit"'));
      expect(host, contains('waitUntilFinished:kRpcs3CompletionTimeout'));
      expect(helper, contains('forceScript: requiresCoreHandshake'));
      expect(host, contains('cancelExtensionRequestWithIdentifier:'));
    });

    test('firmware picker is shown before RPCS3 runtime initialization', () {
      final service = File('lib/services/rpcs3_internal_service.dart')
          .readAsStringSync();
      final methodStart = service.indexOf(
        'static Future<bool> importFirmware()',
      );
      final methodEnd = service.indexOf(
        'static Future<Rpcs3ImportResult> importGames()',
        methodStart,
      );
      final method = service.substring(methodStart, methodEnd);
      final picker = method.indexOf('FilePicker.pickFiles');
      final initialize = method.indexOf('ensureManagementInitialized');

      expect(picker, greaterThanOrEqualTo(0));
      expect(initialize, greaterThan(picker));
      expect(method, contains('_stageFirmware'));
      expect(method, contains("'firmwareInstallTimeout'"));
    });

    test('RPCS3 signing capabilities match the original iOS runtime needs', () {
      final config = File('build-utils/configure_rpcs3_ios_v2.py')
          .readAsStringSync();

      expect(config, contains("'get-task-allow': True"));
      expect(
        config,
        contains(
          "'com.apple.developer.kernel.extended-virtual-addressing': True",
        ),
      );
      expect(
        config,
        contains("'com.apple.developer.kernel.increased-memory-limit': True"),
      );
      expect(
        config,
        contains(
          "'com.apple.developer.kernel.increased-debugging-memory-limit': True",
        ),
      );
    });

    test('launch boots the selected title directly through RPCS3 Core', () {
      final plugin = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
      ).readAsStringSync();
      final launcher = File('lib/services/rpcs3_launch_service.dart')
          .readAsStringSync();
      final service = File('lib/services/rpcs3_internal_service.dart')
          .readAsStringSync();

      expect(plugin, contains('rpcs3_ios_boot_game'));
      expect(plugin, contains('self->_api.boot_game'));
      expect(plugin, contains('@"launchGame"'));
      // The standard arena also supports gameplay; expansion is optional.
      expect(plugin, isNot(contains('!self.initializedWithExpandedJit')));
      expect(launcher, contains('Rpcs3InternalService.launchTitle'));
      expect(launcher, isNot(contains('openJitRequest')));
      expect(launcher, isNot(contains('com.xitrix.RPCS3')));
      expect(service, contains('await ensureGameplayInitialized();'));
      expect(plugin, isNot(contains('setTitle:@"Start"')));
      expect(plugin, isNot(contains('setTitle:@"Commencer"')));
      expect(service, isNot(contains('com.xitrix.RPCS3')));
    });

    test('firmware remains mandatory before direct boot', () {
      final service = File('lib/services/rpcs3_internal_service.dart')
          .readAsStringSync();
      final gameplayInit = service.indexOf(
        'await ensureGameplayInitialized();',
      );
      final firmwareCheck = service.indexOf("'firmwareRequired'");
      final launchCall = service.indexOf('Rpcs3InternalBridge.launchGame');

      expect(gameplayInit, greaterThanOrEqualTo(0));
      expect(firmwareCheck, greaterThan(gameplayInit));
      expect(launchCall, greaterThan(firmwareCheck));
    });

    test('PS3 library exposes emulator manager and all import actions', () {
      final widget = File('lib/widgets/rpcs3_internal_playlist_actions.dart')
          .readAsStringSync();
      final manager = File('lib/screens/rpcs3_manager_screen.dart')
          .readAsStringSync();

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
