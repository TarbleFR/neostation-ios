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
    expect(armsx2, contains('jit.jitReady'));
    expect(armsx2, contains('ARMSX2_GAME_URL_NOT_DELIVERED_JIT_READY'));
    expect(armsx2, contains('stikjit_armsx2_debug.txt'));
  });

  test(
    'native ARMSX2 bridge preserves auto-load detection with natural return',
    () {
      final composite = File(
        'packages/stikjit_bridge/ios/Classes/'
        'NeoStationStikjitBridgePlugin.swift',
      ).readAsStringSync();
      expect(
        composite,
        contains('StikjitBridgePluginV2.register(with: registrar)'),
      );
      expect(composite, contains('neostation/stikjit_armsx2'));
      expect(composite, contains('enableArmsx2Jit'));
      expect(composite, contains('launchArmsx2Suspended'));
      expect(composite, contains('Armsx2PreferenceDetector'));
      expect(composite, contains('detectedAutoLoadLastGame'));
      expect(composite, contains('effectiveAutoLoadLastGame'));
      expect(composite, contains('autoLoadModeSource'));
      expect(composite, contains('ARMSX2_LAUNCH_MODE_AUTO_DETECTED'));
      expect(composite, contains('ARMSX2_LAUNCH_MODE_FALLBACK'));
      expect(composite, contains('ARMSX2_NATURAL_HANDOFF'));
      expect(composite, contains('reacquireNeoStationForeground = false'));
      expect(composite, contains('response["jitReady"] = true'));
      expect(composite, contains('openGameWhenNeoStationIsActive'));
      expect(composite, contains('NEOSTATION_ACTIVE_TIMEOUT'));
      expect(composite, contains('Self.describe(state)'));

      // The old self-bundle process_control call is retained only behind the
      // explicit escape hatch. It must never precede the natural-handoff guard.
      final escapeHatch = composite.indexOf(
        'guard Self.reacquireNeoStationForeground else',
      );
      final selfActivator = composite.indexOf(
        'Armsx2NeoStationProcessActivator().activate(',
      );
      expect(escapeHatch, greaterThanOrEqualTo(0));
      expect(selfActivator, greaterThan(escapeHatch));

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
      expect(dartBridge, contains('jitReady'));

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
      expect(launchFlow, contains('if (Platform.isIOS) return;'));
      expect(
        launchFlow,
        contains('Error refreshing played game after iOS emulator return'),
      );
      expect(launchFlow, contains('GameService.getGameDetails('));
      expect(launchFlow, contains('_databaseProvider.refresh();'));

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
