import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RPCS3 Build 230 import and boot contracts', () {
    test('native install progress is exposed to Flutter', () {
      final bridge = File(
        'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart',
      ).readAsStringSync();
      final playlist = File(
        'lib/widgets/rpcs3_internal_playlist_actions.dart',
      ).readAsStringSync();

      expect(bridge, contains("call.method != 'installProgress'"));
      expect(bridge, contains('Stream<Rpcs3InstallProgress> get installProgress'));
      expect(playlist, contains('rpcs3-import-progress-overlay'));
      expect(playlist, contains('LinearProgressIndicator(value: fraction)'));
      expect(playlist, contains("'$percent %'"));
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
    });

    test('iOS launch skips blocking PPU SPU LLVM precompilation', () {
      final launcher = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();
      final tuning = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3RuntimeTuningPlugin.mm',
      ).readAsStringSync();

      expect(launcher, contains("'advanced.llvm_precompilation': 'false'"));
      expect(launcher, contains("'emulator.max_llvm_threads': '0'"));
      expect(launcher, contains('await _applyMobileBootProfile();'));
      expect(tuning, contains('rpcs3_ios_set_setting'));
      expect(tuning, contains('rpcs3_ios_get_boot_progress'));
    });
  });
}
