import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('embedded ARMSX2 PS2 library contract stays Files-visible', () {
    final storage = File(
      'lib/services/armsx2_internal_service.dart',
    ).readAsStringSync();
    final systems = File(
      'lib/repositories/system_repository.dart',
    ).readAsStringSync();
    final list = File(
      'lib/screens/game_screen/my_games_list.dart',
    ).readAsStringSync();
    final core = File(
      'packages/armsx2_internal_bridge/core/ARMSX2Core.mm',
    ).readAsStringSync();
    final launcher = File(
      'lib/services/stikjit_armsx2_service.dart',
    ).readAsStringSync();

    expect(storage, contains("path.join(documents.path, 'ARMSX2')"));
    expect(storage, contains("path.join(root.path, 'Games')"));
    expect(storage, contains("path.join(root.path, 'BIOS')"));
    expect(storage, contains("path.join(root.path, 'Saves')"));
    expect(storage, contains('importGames()'));
    expect(storage, contains('importBios()'));

    expect(systems, contains("const <String>['ps2', 'ps3']"));
    expect(list, contains('_isArmsx2Library'));
    expect(list, contains('_buildEmbeddedArmsx2ImportAction'));

    expect(core, contains('folder(saves_root,r.data,"Saves")'));
    expect(core, contains('folder(EmuFolders::MemoryCards,saves_root,"Memory Cards")'));
    expect(core, contains('folder(EmuFolders::Savestates,saves_root,"Savestates")'));

    expect(launcher, contains('Armsx2InternalService.ensureLayout()'));
    expect(launcher, contains("outside NeoStation/ARMSX2/Games"));
    expect(launcher, isNot(contains('resolveBookmarkedFolder')));
  });

  test('PS2 embedded library hides recursive scan and supports guarded long press deletion', () {
    final dialog = File(
      'lib/widgets/system_emulator_settings_dialog.dart',
    ).readAsStringSync();
    final tabs = File(
      'lib/widgets/system_emulator_settings_dialog/tabs.dart',
    ).readAsStringSync();
    final list = File(
      'lib/screens/game_screen/game_list_view.dart',
    ).readAsStringSync();
    final deletion = File(
      'lib/widgets/armsx2_multi_delete_dialog.dart',
    ).readAsStringSync();

    expect(dialog, contains('_showsRecursiveScan'));
    expect(dialog, contains("{'gc', 'wii', 'ps2', 'ps3'}"));
    expect(tabs, contains('if (_showsRecursiveScan)'));
    expect(list, contains('Armsx2MultiDeleteDialog.show'));
    expect(deletion, contains('linkedArmsx2GameFolderPath'));
    expect(deletion, contains('refreshArmsx2InternalLibrary'));
    expect(deletion, contains("systemFolderName: 'ps2'"));
    expect(deletion, isNot(contains('savesDirectory()')));
    expect(deletion, isNot(contains('biosDirectory()')));
  });

  test('embedded ARMSX2 game surface exposes touch controls and native game tools', () {
    final abi = File(
      'packages/armsx2_internal_bridge/ios/Classes/ARMSX2CoreABI.h',
    ).readAsStringSync();
    final plugin = File(
      'packages/armsx2_internal_bridge/ios/Classes/Armsx2InternalBridgePlugin.mm',
    ).readAsStringSync();
    final core = File(
      'packages/armsx2_internal_bridge/core/ARMSX2Core.mm',
    ).readAsStringSync();
    final sessionMenu = File(
      'packages/armsx2_internal_bridge/ios/Classes/Armsx2SessionMenu.mm',
    ).readAsStringSync();

    expect(abi, contains('NEO_ARMSX2_ABI_VERSION 3u'));
    expect(abi, contains('set_upscale_multiplier'));
    expect(abi, contains('set_aspect_ratio'));
    expect(abi, contains('set_cheats_enabled'));
    expect(abi, contains('save_state'));
    expect(abi, contains('load_state'));
    expect(abi, contains('get_retroachievements_state_json'));
    expect(abi, contains('set_retroachievements_option'));
    expect(abi, contains('login_retroachievements'));
    expect(abi, contains('logout_retroachievements'));

    expect(plugin, contains('armsx2-touch-controls'));
    expect(plugin, contains('armsx2-game-menu'));
    expect(plugin, contains('presentSessionMenuForController'));
    expect(plugin, contains('UIModalPresentationOverFullScreen'));
    expect(plugin, contains('line.3.horizontal'));
    expect(plugin, isNot(contains('[UIImage systemImageNamed:@"xmark"]')));
    expect(plugin, isNot(contains('[UIImage systemImageNamed:@"slider.horizontal.3"]')));
    expect(sessionMenu, contains('UITableViewStyleInsetGrouped'));
    expect(sessionMenu, contains('Commandes tactiles'));
    expect(sessionMenu, contains('Résolution interne'));
    expect(sessionMenu, contains('Format d’écran'));
    expect(sessionMenu, contains('Recharger cheats / patches'));
    expect(sessionMenu, contains('Sauvegarder un état'));
    expect(sessionMenu, contains('Charger un état'));
    expect(sessionMenu, contains('Reprendre le jeu'));
    expect(sessionMenu, contains('Quitter le jeu'));

    expect(core, contains('setPerGameINIFloat:@"EmuCore/GS"'));
    expect(core, contains('setPerGameINIString:@"EmuCore/GS"'));
    expect(core, contains('setPerGameINIBool:@"EmuCore"'));
    expect(core, contains('saveStateToSlot'));
    expect(core, contains('loadStateFromSlot'));
  });

  test('ARMSX2 exit is host-safe and RetroAchievements uses Dolphin-style native UI', () {
    final core = File(
      'packages/armsx2_internal_bridge/core/ARMSX2Core.mm',
    ).readAsStringSync();
    final plugin = File(
      'packages/armsx2_internal_bridge/ios/Classes/Armsx2InternalBridgePlugin.mm',
    ).readAsStringSync();
    final raMenu = File(
      'packages/armsx2_internal_bridge/ios/Classes/Armsx2RetroAchievementsMenu.mm',
    ).readAsStringSync();

    expect(core, contains('r.phase=Phase::Stopping'));
    expect(core, contains('VMManager::SetState(VMState::Stopping)'));
    expect(core, contains('initialize_sdl=!r.sdl_initialized'));
    expect(core, isNot(contains('SDL_QuitSubSystem(')));
    expect(core, contains('if (!si.ContainsValue("Achievements","Enabled"))'));
    expect(core, contains('parameters.disable_achievements_hardcore_mode=false'));
    expect(core, contains('[ARMSX2Bridge retroAchievementsState]'));
    expect(core, contains('[ARMSX2Bridge loginRetroAchievementsWithUsername:'));

    expect(plugin, contains('stopInProgress'));
    expect(plugin, contains('dismissGameControllerWithCompletion'));
    expect(plugin, contains('dismissViewControllerAnimated:NO completion:releaseView'));
    expect(plugin, contains('RetroAchievements'));
    expect(plugin, contains('presentSessionMenuForController'));
    expect(plugin, contains('invokeMethod:@"sessionEnded"'));
    expect(plugin, isNot(contains('showsMenuAsPrimaryAction = YES')));

    expect(raMenu, contains('UITableViewStyleInsetGrouped'));
    expect(raMenu, contains('UITableViewCellAccessoryCheckmark'));
    expect(raMenu, contains('hardcore'));
    expect(raMenu, contains('leaderboards'));
    expect(raMenu, contains('overlays'));
    expect(raMenu, contains('passwordField.text = @""'));
  });

  test('ARMSX2 launch teardown blocks duplicate play and AVPlayer audio leaks', () {
    final launchFlow = File(
      'lib/screens/game_screen/my_games_list/launch_flow.dart',
    ).readAsStringSync();
    final media = File(
      'lib/screens/game_screen/my_games_list/secondary_display.dart',
    ).readAsStringSync();
    final manager = File(
      'lib/services/game_launch_manager.dart',
    ).readAsStringSync();
    final launchService = File(
      'lib/services/game/game_launch_service.dart',
    ).readAsStringSync();
    final dartBridge = File(
      'packages/armsx2_internal_bridge/lib/armsx2_internal_bridge.dart',
    ).readAsStringSync();

    expect(launchFlow, contains('if (_isGameLaunching) return;'));
    expect(launchFlow, contains('await _stopVideoAndCleanup();'));
    expect(media, contains('Future<void> _stopVideoAndCleanup() async'));
    expect(media, contains('await _videoTransition'));
    expect(manager, contains("emulatorExe == 'ios_armsx2_internal'"));
    expect(manager, contains('Armsx2InternalBridge.sessionEvents.listen'));
    expect(launchService, contains("'ios_armsx2_internal'"));
    expect(dartBridge, contains("call.method != 'sessionEnded'"));
  });

  test('ARMSX2 process-lifetime Core performs a fresh JIT handshake on relaunch', () {
    final plugin = File(
      'packages/armsx2_internal_bridge/ios/Classes/Armsx2InternalBridgePlugin.mm',
    ).readAsStringSync();
    final jitBridge = File(
      'packages/armsx2_internal_bridge/ios/Classes/Armsx2JitBridgePlugin.mm',
    ).readAsStringSync();
    final launchService = File(
      'lib/services/game/game_launch_service.dart',
    ).readAsStringSync();

    final loadCore = plugin.indexOf('- (BOOL)loadCore:');
    final freshProof = plugin.indexOf(
      'ARMSX2JitConfirmCoreLoadHandoff()',
      loadCore,
    );
    final reuseReturn = plugin.indexOf(
      'if (coreAlreadyLoaded)',
      loadCore,
    );

    expect(loadCore, greaterThanOrEqualTo(0));
    expect(freshProof, greaterThan(loadCore));
    expect(reuseReturn, greaterThan(freshProof));
    expect(
      plugin,
      contains('Reusing process-lifetime Core after fresh JIT nonce proof.'),
    );
    expect(
      jitBridge,
      contains(
        'proofReady = !session.requiresCoreHandshake || session.coreLoadReady',
      ),
    );
    expect(
      jitBridge,
      contains(
        'ARMSX2 Core nonce handshake was not completed for this JIT transaction.',
      ),
    );
    expect(
      launchService,
      contains('Armsx2LibraryService.lastLaunchError?.trim()'),
    );
  });

  test('ARMSX2 import menu exposes BIOS and games', () {
    final widget = File(
      'lib/widgets/armsx2_internal_playlist_actions.dart',
    ).readAsStringSync();

    expect(widget, contains("ValueKey('armsx2-internal-import-menu')"));
    expect(widget, contains("'Importer des jeux'"));
    expect(widget, contains("'Importer le BIOS'"));
    expect(widget, contains('Armsx2InternalService.importGames()'));
    expect(widget, contains('Armsx2InternalService.importBios()'));
  });
}
