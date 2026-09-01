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
    expect(armsx2, contains('useArmsx2AutoLoadLastGame'));
    expect(
      armsx2,
      contains('autoLoadLastGame: fallbackAutoLoadLastGame'),
    );
    expect(armsx2, contains('detectedAutoLoadLastGame'));
    expect(armsx2, contains('effectiveAutoLoadLastGame'));
    expect(armsx2, contains('autoLoadModeSource'));
    expect(armsx2, contains('setUseArmsx2AutoLoadLastGame'));
    expect(armsx2, contains('postJitHandoffSkipped'));
    expect(armsx2, contains('targetResumed'));
    expect(armsx2, contains('ARMSX2_AUTOLOAD_RESUMED'));
    expect(armsx2, contains('stikjit_armsx2_debug.txt'));
  });

  test(
    'registered ARMSX2 bridge uses detach-only automatic load and legacy URL fallback',
    () {
      final registration = File(
        'packages/stikjit_bridge/ios/Classes/'
        'NeoStationStikjitBridgePluginV2.swift',
      ).readAsStringSync();
      expect(
        registration,
        contains('StikjitBridgePluginV2.register(with: registrar)'),
      );
      expect(
        registration,
        contains('StikjitArmsx2BridgePluginV2.register(with: registrar)'),
      );
      expect(
        registration,
        contains('StikjitRpcs3BridgePlugin.register(with: registrar)'),
      );
      expect(
        registration,
        isNot(contains('NeoStationStikjitBridgePlugin.register(with: registrar)')),
      );

      final native = File(
        'packages/stikjit_bridge/ios/Classes/'
        'StikjitArmsx2BridgePluginV2.swift',
      ).readAsStringSync();
      expect(native, contains('neostation/stikjit_armsx2'));
      expect(native, contains('enableArmsx2Jit'));
      expect(native, contains('launchArmsx2Suspended'));
      expect(native, contains('Armsx2PreferenceDetector'));
      expect(native, contains('detectedAutoLoadLastGame'));
      expect(native, contains('effectiveAutoLoadLastGame'));
      expect(native, contains('autoLoadModeSource'));
      expect(native, contains('STATE: ARMSX2_V2_JIT_PID_READY'));
      expect(native, contains('STATE: ARMSX2_V2_DETACH_ONLY'));
      expect(native, contains('"resumeStrategy"] = "stikjit_detach_only"'));
      expect(native, contains('completed["postJitHandoffSkipped"] = true'));
      expect(native, contains('completed["targetResumed"] = true'));
      expect(native, contains('completed["gameUrlOpened"] = false'));
      expect(native, contains('performLifecycleHandoff('));
      expect(native, contains('targetURL: gameUrl'));

      final detector = File(
        'packages/stikjit_bridge/ios/Classes/'
        'Armsx2PreferenceDetector.swift',
      ).readAsStringSync();
      expect(detector, contains('house_arrest_client_connect_rsd'));
      expect(detector, contains('house_arrest_vend_container'));
      expect(detector, contains('afc_file_read_entire'));
      expect(detector, contains('Library/Preferences/'));
      expect(detector, contains('automaticloadlastgame'));
      expect(detector, contains('autoloadlastgame'));
      expect(detector, contains('ARMSX2_AUTOLOAD_PREFERENCE_DETECTED'));
      expect(detector, contains('ARMSX2_AUTOLOAD_PREFERENCE_UNAVAILABLE'));

      final dartBridge = File(
        'packages/stikjit_bridge/lib/stikjit_bridge.dart',
      ).readAsStringSync();
      expect(dartBridge, contains("'autoLoadLastGame': autoLoadLastGame"));
      expect(dartBridge, contains('detectedAutoLoadLastGame'));
      expect(dartBridge, contains('effectiveAutoLoadLastGame'));
      expect(dartBridge, contains('autoLoadModeSource'));
      expect(dartBridge, contains('detectedAutoLoadPreferenceKey'));
      expect(dartBridge, contains('postJitHandoffSkipped'));
      expect(dartBridge, contains('targetResumed'));

      final preferences = File(
        'lib/services/jit_backend_preference_service.dart',
      ).readAsStringSync();
      expect(preferences, contains('ios_armsx2_autoload_last_game_v1'));
      expect(preferences, contains('setUseArmsx2AutoLoadLastGame'));

      final tools = File(
        'lib/screens/settings_screen/new_settings_options/'
        'tools_settings_content.dart',
      ).readAsStringSync();
      expect(tools, contains('Armsx2JitModeLocale'));
      expect(tools, contains('_setUseArmsx2AutoLoadLastGame'));

      final footer = File(
        'lib/screens/game_screen/game_details_card/widgets/'
        'game_details_footer.dart',
      ).readAsStringSync();
      expect(footer, isNot(contains('GameUtils.formatGameName(game.name)')));
      expect(footer, contains('_CombinedGameStatsPill'));
      expect(footer, contains('currentGameInfo!.imageIcon'));
      expect(footer, contains('Symbols.schedule_rounded'));

      final media = File(
        'lib/screens/game_screen/game_details_card/tabs/'
        'game_details_screenshot_video_tab.dart',
      ).readAsStringSync();
      expect(media, contains('final headerClearance = 58.r'));
      expect(media, contains('final footerClearance = 72.r'));
      expect(media, contains('availableWidth < 230.r'));
      expect(media, contains('availableHeight < 175.r'));
      expect(media, contains('return LayoutBuilder('));

      final launchFlow = File(
        'lib/screens/game_screen/my_games_list/launch_flow.dart',
      ).readAsStringSync();
      expect(launchFlow, isNot(contains('if (Platform.isIOS) return;')));
      expect(launchFlow, contains('imageCache.clear();'));
      expect(launchFlow, contains('_games = [];'));
      expect(launchFlow, contains('GameService.loadGamesForSystem(widget.system)'));

      final launchUtils = File(
        'lib/utils/game_launch_utils.dart',
      ).readAsStringSync();
      expect(
        launchUtils,
        contains('await GameSessionPersistence.saveGameSession('),
      );
      expect(
        launchUtils,
        contains('await GameSessionPersistence.clearGameSession();'),
      );

      final appScreen = File('lib/screens/app_screen.dart').readAsStringSync();
      expect(appScreen, contains('skipIosReturnScan'));
      expect(appScreen, contains('shouldSkipStartupScan()'));
      expect(
        appScreen,
        contains('startupScanPending && !skipIosReturnScan && mounted'),
      );

      final systemContent = File(
        'lib/screens/systems_screen/system_content.dart',
      ).readAsStringSync();
      expect(systemContent, contains('canReuseCachedIosLibrary'));
      expect(systemContent, contains('configProvider.hasDetectedSystems'));
      expect(systemContent, contains('!configProvider.pendingStartupScan'));
      expect(
        systemContent,
        contains('configProvider.scanCompleted || canReuseCachedIosLibrary'),
      );
      expect(systemContent, contains('_scheduleStartupPhaseProbe'));

      final melonxNative = File(
        'packages/stikjit_bridge/ios/Classes/StikjitBridgePluginV2.swift',
      ).readAsStringSync();
      expect(melonxNative, contains('enableMeloNxJit'));
      expect(melonxNative, isNot(contains('enableArmsx2Jit')));
      expect(melonxNative, isNot(contains('stikjit_armsx2')));

      final pluginManifest = File(
        'packages/stikjit_bridge/pubspec.yaml',
      ).readAsStringSync();
      expect(
        pluginManifest,
        contains('pluginClass: NeoStationStikjitBridgePluginV2'),
      );
    },
  );
}
