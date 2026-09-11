import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RPCS3 Build 231 import, boot and deletion contracts', () {
    test('native install progress is exposed to Flutter', () {
      final bridge = File(
        'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart',
      ).readAsStringSync();
      final playlist = File(
        'lib/widgets/rpcs3_internal_playlist_actions.dart',
      ).readAsStringSync();

      expect(bridge, contains("call.method != 'installProgress'"));
      expect(
        bridge,
        contains('Stream<Rpcs3InstallProgress> get installProgress'),
      );
      expect(playlist, contains('rpcs3-import-progress-overlay'));
      expect(playlist, contains('LinearProgressIndicator(value: fraction)'));
      expect(playlist, contains('(fraction * 100).round()'));
    });

    test('large PS3 files are selected open-in-place and released afterwards', () {
      final bridge = File(
        'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart',
      ).readAsStringSync();
      final picker = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3DocumentPickerPlugin.mm',
      ).readAsStringSync();
      final importer = File(
        'lib/services/rpcs3_content_import_service.dart',
      ).readAsStringSync();

      expect(bridge, contains('pickGameFilesOpenInPlace'));
      expect(picker, contains('UIDocumentPickerModeOpen'));
      expect(picker, contains('startAccessingSecurityScopedResource'));
      expect(importer, contains('releaseScopedResources'));
      expect(importer, contains("const {'.pkg', '.zip', '.iso'}"));
      expect(
        importer,
        contains(
          'if (imported > 0) await Rpcs3LibraryService.syncInternalLibrary();',
        ),
      );
    });

    test('decrypted PS3 folders use the security-scoped folder path', () {
      final importer = File(
        'lib/services/rpcs3_content_import_service.dart',
      ).readAsStringSync();

      expect(importer, contains('pickGameFolderOpenInPlace'));
      expect(importer, contains("path.join(root, 'PS3_GAME', 'PARAM.SFO')"));
      expect(
        importer,
        contains("path.join(root, 'PS3_GAME', 'USRDIR', 'EBOOT.BIN')"),
      );
      expect(importer, contains("path.join(root, 'USRDIR', 'EBOOT.BIN')"));
      expect(importer, contains('Rpcs3InternalBridge.installFolder(folder)'));
      expect(importer, isNot(contains('copyWithProgress')));
    });

    test('iOS boot profile is selected by serial and covers PPU stalls', () {
      final launcher = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();
      final profiles = File(
        'lib/services/rpcs3_game_profile_service.dart',
      ).readAsStringSync();
      final bridge = File(
        'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart',
      ).readAsStringSync();
      final tuning = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3RuntimeTuningPlugin.mm',
      ).readAsStringSync();

      expect(profiles, contains("'advanced.llvm_precompilation': 'false'"));
      expect(profiles, contains("'emulator.max_llvm_threads': '0'"));
      expect(
        profiles,
        contains("'experimental.mobile_spu_scheduling': 'Automatic'"),
      );
      expect(profiles, contains("'cpu.spu_block_size': 'Safe'"));
      expect(profiles, contains("'BLES00215'"));
      expect(profiles, contains("'BLUS30110'"));
      expect(profiles, contains("'cpu.ppu_decoder': 'Interpreter (static)'"));
      expect(profiles, contains("'BCUS98111'"));
      expect(profiles, contains("'BCES00510'"));
      expect(profiles, contains("'BCAS25003'"));
      expect(profiles, contains("'cpu.spu_block_size': 'Mega'"));
      expect(profiles, contains("'gpu.resolution_scale': '75'"));
      expect(
        profiles,
        contains("'experimental.fps_optimization_batch': 'Enabled'"),
      );
      expect(launcher, contains('_applyMobileBootProfile(String titleId)'));
      expect(launcher, contains('Rpcs3GameProfileService.applyForLaunch'));
      expect(launcher, isNot(contains('Rpcs3InternalBridge.setSetting(')));
      expect(launcher, isNot(contains('Rpcs3InternalBridge.setGameSetting(')));
      expect(launcher, contains("value.contains('ppu')"));
      expect(launcher, contains("value.contains('applying')"));
      expect(launcher, contains('Rpcs3InternalBridge.bootProgress()'));
      expect(launcher, contains("'bootPreparationStalled'"));
      expect(launcher, contains('Rpcs3InternalBridge.stop()'));
      expect(bridge, contains("'updateConfigDatabase'"));
      expect(
        bridge,
        contains("invokeMapMethod<String, dynamic>('bootProgress')"),
      );
      expect(tuning, contains('rpcs3_ios_update_config_database'));
      expect(tuning, contains('rpcs3_ios_get_boot_progress'));
    });

    test('PS3 long press opens native RPCS3 multi-delete', () {
      final list = File(
        'lib/screens/game_screen/game_list_view.dart',
      ).readAsStringSync();
      final dialog = File(
        'lib/widgets/rpcs3_multi_delete_dialog.dart',
      ).readAsStringSync();
      final bridge = File(
        'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart',
      ).readAsStringSync();
      final tuning = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3RuntimeTuningPlugin.mm',
      ).readAsStringSync();

      expect(list, contains("widget.system.folderName.toLowerCase() == 'ps3'"));
      expect(list, contains('Rpcs3MultiDeleteDialog.show'));
      expect(dialog, contains('Set<String> _selected'));
      expect(dialog, contains('Rpcs3InternalBridge.deleteGame(titleId)'));
      expect(dialog, contains('Rpcs3LibraryService.syncInternalLibrary()'));
      expect(dialog, contains('deleteNeoStationScrapedMedia'));
      expect(bridge, contains("invokeMapMethod<String, dynamic>('deleteGame'"));
      expect(tuning, contains('rpcs3_ios_delete_game'));
    });
  });
}
