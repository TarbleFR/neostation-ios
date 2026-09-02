import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ARMSX2 safe StikJIT path stays isolated from MeloNX routing', () {
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
    expect(melonx, isNot(contains('enableArmsx2JitSafe')));
    expect(melonx, isNot(contains('NEOSTATION_EXPERIMENTAL_STIKJIT_ARMSX2')));

    final armsx2 = File(
      'lib/services/stikjit_armsx2_service.dart',
    ).readAsStringSync();
    expect(armsx2, contains('NEOSTATION_EXPERIMENTAL_STIKJIT_ARMSX2'));
    expect(armsx2, contains("defaultValue: 'com.armsx2.ios'"));
    expect(armsx2, contains('enableArmsx2JitSafe'));
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
    expect(armsx2, contains('ARMSX2_SAFE_BOOT_COMPLETE'));
    expect(armsx2, contains('stikjit_armsx2_debug.txt'));
  });

  test('native ARMSX2 safe boot queues ISO before universal first continue', () {
    final safeBridge = File(
      'packages/stikjit_bridge/ios/Classes/'
      'StikjitArmsx2SafeBridgePlugin.swift',
    ).readAsStringSync();
    expect(safeBridge, contains('neostation/stikjit_armsx2_safe'));
    expect(safeBridge, contains('enableArmsx2JitSafe'));
    expect(safeBridge, contains('launchArmsx2Suspended'));
    expect(safeBridge, contains('ARMSX2_SAFE_SUSPENDED'));
    expect(safeBridge, contains('ARMSX2_SAFE_BEFORE_ENABLE_JIT'));
    expect(safeBridge, contains('message.hasPrefix("attach_response =")'));
    expect(safeBridge, contains('ARMSX2_SAFE_SCRIPT_ATTACHED'));
    expect(safeBridge, contains('handoff.openSynchronously(gameURL)'));
    expect(safeBridge, contains('ARMSX2_SAFE_GAME_URL_OPENED'));
    expect(safeBridge, contains('ARMSX2_SAFE_AFTER_ENABLE_JIT'));
    expect(safeBridge, contains('ARMSX2_SAFE_BOOT_COMPLETE'));
    expect(safeBridge, contains('safe_staged_url_during_jit'));
    expect(safeBridge, isNot(contains('Bundle.main.bundleIdentifier')));
    expect(
      safeBridge,
      isNot(contains('Armsx2NeoStationProcessActivator().activate(')),
    );

    final guard = File(
      'packages/stikjit_bridge/ios/Classes/'
      'Armsx2AutoLoadPreferenceGuard.swift',
    ).readAsStringSync();
    expect(guard, contains('house_arrest_client_connect_rsd'));
    expect(guard, contains('house_arrest_vend_container'));
    expect(guard, contains('afc_file_read_entire'));
    expect(guard, contains('afc_file_write'));
    expect(guard, contains('Library/Preferences/'));
    expect(guard, contains('automaticloadlastgame'));
    expect(guard, contains('autoloadlastgame'));
    expect(guard, contains('ARMSX2_SAFE_AUTOLOAD_TEMP_DISABLED'));
    expect(guard, contains('try writeFile('));
    expect(guard, contains('originalData'));

    final registration = File(
      'packages/stikjit_bridge/ios/Classes/'
      'NeoStationStikjitBridgePluginV2.swift',
    ).readAsStringSync();
    expect(
      registration,
      contains('StikjitArmsx2SafeBridgePlugin.register(with: registrar)'),
    );
    expect(
      registration,
      contains('StikjitRpcs3BridgePlugin.register(with: registrar)'),
    );

    final dartBridge = File(
      'packages/stikjit_bridge/lib/stikjit_bridge.dart',
    ).readAsStringSync();
    expect(dartBridge, contains('neostation/stikjit_armsx2_safe'));
    expect(dartBridge, contains('enableArmsx2JitSafe'));
    expect(dartBridge, contains("'enableArmsx2JitSafe'"));
    expect(dartBridge, contains('detectedAutoLoadLastGame'));
    expect(dartBridge, contains('detectedAutoLoadPreferenceKey'));
    expect(dartBridge, contains('jitReady'));
  });

  test('existing native paths and iOS library return behavior remain intact', () {
    final legacyArmsx2 = File(
      'packages/stikjit_bridge/ios/Classes/'
      'NeoStationStikjitBridgePlugin.swift',
    ).readAsStringSync();
    expect(legacyArmsx2, contains('reacquireNeoStationForeground = false'));
    expect(legacyArmsx2, contains('ARMSX2_NATURAL_HANDOFF'));

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

    final launchFlow = File(
      'lib/screens/game_screen/my_games_list/launch_flow.dart',
    ).readAsStringSync();
    expect(launchFlow, contains('if (Platform.isIOS) return;'));
    expect(
      launchFlow,
      contains('Error refreshing played game after iOS emulator return'),
    );
    expect(launchFlow, contains('GameService.getGameDetails('));

    final melonxNative = File(
      'packages/stikjit_bridge/ios/Classes/StikjitBridgePluginV2.swift',
    ).readAsStringSync();
    expect(melonxNative, contains('enableMeloNxJit'));
    expect(melonxNative, isNot(contains('enableArmsx2JitSafe')));

    final pluginManifest = File(
      'packages/stikjit_bridge/pubspec.yaml',
    ).readAsStringSync();
    expect(
      pluginManifest,
      contains('pluginClass: NeoStationStikjitBridgePluginV2'),
    );
  });
}
