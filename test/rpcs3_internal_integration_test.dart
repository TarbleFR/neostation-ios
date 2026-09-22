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
      expect(service, contains("jit['code']?.toString()"));
      expect(service, isNot(contains('_actionableJitFailure')));
      expect(service, isNot(contains('saved RPPairing entry for this iPhone')));
      expect(service, isNot(contains('dolphin_internal_bridge')));
      expect(service, isNot(contains('DolphinInternalBridge')));
      expect(hostJit, contains('com.neogamelab.neostation.rpcs3-jit-request'));
      expect(hostJit, contains('NeoStationRPCS3JITHelper'));
      expect(hostJit, isNot(contains('Dolphin')));
      expect(helper, contains('var script = StikJIT.Script.universal'));
      expect(helper, contains('script = .custom(scriptURL)'));
      expect(helper, contains('forceScript: requiresCoreHandshake'));
      expect(helper, isNot(contains('script = .legacy')));
      expect(helper, isNot(contains('script: .legacy')));
      expect(helper, isNot(contains('com.xitrix.RPCS3')));
    });

    test('every RPCS3 startup performs one explicit StikJIT attach', () {
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();

      final pairingIndex = service.indexOf(
        'PairingFileService.hasStoredPairingFile',
      );
      final prepareIndex = service.indexOf('Rpcs3InternalBridge.prepareJit');

      expect(pairingIndex, greaterThanOrEqualTo(0));
      expect(prepareIndex, greaterThan(pairingIndex));
      expect(
        service,
        contains('static final _startup = Rpcs3StartupTransaction()'),
      );
      expect(service, contains("'RPCS3_JIT_PREPARATION_TIMEOUT'"));
      expect(service, isNot(contains("current['debugged'] == true")));
      expect(service, contains('Duration(minutes: 11)'));
      expect(service, isNot(contains('Duration(seconds: 90)')));
    });

    test('constructor crash diagnostics bracket RPCS3 JIT page preparation', () {
      final early = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3EarlyLoaderDiagnostics.h',
      ).readAsStringSync();
      final script = File(
        'packages/rpcs3_jit_helper/ios/Resources/rpcs3-universal.js',
      ).readAsStringSync();

      expect(early, contains('NEOSTATION_EARLY_LOADER_295'));
      expect(
        early,
        contains(
          'next expected event is Core JIT region preparation or dlopen return',
        ),
      );
      expect(script, contains('NEOSTATION_RPCS3_PREPARE_BEGIN'));
      expect(script, contains('NEOSTATION_RPCS3_PREPARE_END'));
      expect(script, contains('prepare_memory_region(jitPageAddress, x1)'));
    });

    test(
      'RPCS3 launch is one linear transaction with the proven Core',
      () {
        final service = File(
          'lib/services/rpcs3_internal_service.dart',
        ).readAsStringSync();
        final bridge = File(
          'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
        ).readAsStringSync();

        final route = service.indexOf('LocalDevVpnRouteService.ensureReachable');
        final pairing = service.indexOf('PairingFileService.hasStoredPairingFile');
        final attach = service.indexOf('Rpcs3InternalBridge.prepareJit');
        final initialize = service.indexOf('Rpcs3InternalBridge.initialize');
        final complete = service.indexOf('Rpcs3InternalBridge.completeJit');
        expect(route, greaterThanOrEqualTo(0));
        expect(pairing, greaterThan(route));
        expect(attach, greaterThan(pairing));
        expect(initialize, greaterThan(attach));
        expect(complete, greaterThan(initialize));

        expect(service, isNot(contains('Rpcs3StartupTransaction')));
        expect(service, isNot(contains('abortStartup')));
        expect(service, isNot(contains('verifyJitExecution')));
        expect(service, isNot(contains('reserveAddressSpace')));
        expect(service, isNot(contains('_bootCrashMarker')));
        expect(service, isNot(contains('bootProgress')));
        expect(service, contains('expandedJitRegion: false'));

        expect(bridge, contains('RPCS3HostIsDebugged'));
        expect(bridge, contains('RPCS3JitConfirmCoreLoadHandoff'));
        expect(bridge, contains('NEOSTATION_RPCS3_SINGLE_DLOPEN_V1'));
        expect(bridge, contains('rpcs3_ios_run_llvm_self_test'));
        expect(bridge, isNot(contains('_startupEntered')));
        expect(bridge, isNot(contains('abortStartup')));
        expect(bridge, isNot(contains('verifyJitExecution')));
        expect(bridge, isNot(contains('RPCS3JitTransactionIsClosed')));
        expect(bridge, isNot(contains('Rpcs3ArenaReservation')));
        expect(bridge, isNot(contains('reset_failed_startup')));
        expect('dlopen('.allMatches(bridge).length, 1);

        final handoff = bridge.indexOf('if (!RPCS3JitConfirmCoreLoadHandoff())');
        final dlopen = bridge.indexOf('handle = dlopen(');
        final initializeCall = bridge.indexOf('self->_api.initialize(&options)');
        final launch = bridge.indexOf(
          'if ([call.method isEqualToString:@"launchGame"])',
        );
        final selfTest = bridge.indexOf('rpcs3_ios_run_llvm_self_test', launch);
        final boot = bridge.indexOf('self->_api.boot_game', launch);
        expect(handoff, greaterThanOrEqualTo(0));
        expect(dlopen, greaterThan(handoff));
        expect(initializeCall, greaterThan(dlopen));
        expect(launch, greaterThan(initializeCall));
        expect(selfTest, greaterThan(launch));
        expect(boot, greaterThan(selfTest));
      },
    );

    test('manager inspection does not leave a Universal helper waiting', () {
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();
      final manager = File(
        'lib/screens/rpcs3_manager_screen.dart',
      ).readAsStringSync();

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

    test(
      'Universal attach returns before completion and forces the matching script',
      () {
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
      },
    );

    test('RPCS3 in-game menu mirrors Dolphin navigation and follows 12 locales', () {
      final menu = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3SessionMenu.mm',
      ).readAsStringSync();
      final plugin = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
      ).readAsStringSync();
      final localization = File(
        'packages/rpcs3_internal_bridge/ios/Classes/RPCS3InGameLocalization.mm',
      ).readAsStringSync();
      final input = File(
        'packages/rpcs3_internal_bridge/ios/Classes/RPCS3GameInputController.mm',
      ).readAsStringSync();

      expect(menu, contains('UITableViewStyleInsetGrouped'));
      expect(menu, contains('UINavigationBarAppearance'));
      expect(menu, contains('RPCS3MenuGraphics'));
      expect(menu, contains('RPCS3MenuSystem'));
      expect(menu, contains('RPCS3MenuControls'));
      expect(menu, contains('RPCS3MenuSaveStates'));
      expect(menu, contains('RPCS3MenuLoadStates'));
      expect(menu, contains('systemImageNamed'));
      expect(plugin, contains('Rpcs3SessionMenu* menu'));
      expect(plugin, contains('UIModalPresentationOverFullScreen'));
      expect(plugin, contains('performSessionCommand'));
      expect(plugin, contains('readSessionStates'));
      expect(plugin, contains('performSessionStateAtSlot'));
      expect(input, contains('self.touchControlsEnabled'));

      for (final locale in const [
        'en',
        'es',
        'pt',
        'ru',
        'zh',
        'zh_Hant',
        'fr',
        'de',
        'it',
        'id',
        'ja',
        'ko',
      ]) {
        expect(localization, contains('@"$locale": @{'), reason: locale);
      }
      for (final key in const [
        'graphicsMenu',
        'systemMenu',
        'controlsMenu',
        'resumeGame',
        'performanceOverlay',
        'touchControls',
      ]) {
        expect(localization, contains('@"$key"'), reason: key);
      }
    });

    test('firmware picker is shown before RPCS3 runtime initialization', () {
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();
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
      final config = File(
        'build-utils/configure_rpcs3_ios_v2.py',
      ).readAsStringSync();

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
      final launcher = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();

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
      final service = File(
        'lib/services/rpcs3_internal_service.dart',
      ).readAsStringSync();
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
