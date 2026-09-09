import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Build 227 runtime contracts', () {
    test('RPCS3 no longer preloads its Core before Universal JIT', () {
      final bridge = File(
        'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart',
      ).readAsStringSync();
      expect(bridge, isNot(contains("import 'dart:ffi'")));
      expect(bridge, isNot(contains('DynamicLibrary.open')));
      expect(bridge, isNot(contains('preloadCoreImage')));
      expect(bridge, contains("'expandedJitRegion': false"));
    });

    test('RPCS3 bridge has no preload-only ffi dependency', () {
      final pubspec = File(
        'packages/rpcs3_internal_bridge/pubspec.yaml',
      ).readAsStringSync();
      expect(pubspec, isNot(contains('ffi: ^')));
    });

    test('Dolphin long press opens multi-selection deletion', () {
      final list = File(
        'lib/screens/game_screen/game_list_view.dart',
      ).readAsStringSync();
      expect(list, contains('onLongPress:'));
      expect(list, contains('DolphinMultiDeleteDialog.show'));
      expect(list, contains('DolphinInternalV2Service.isDolphinSystem'));
    });

    test('Dolphin multi-delete refreshes private playlist immediately', () {
      final dialog = File(
        'lib/widgets/dolphin_multi_delete_dialog.dart',
      ).readAsStringSync();
      expect(dialog, contains('Set<String> _selected'));
      expect(dialog, contains('GameRepository.deleteGame'));
      expect(dialog, contains('refreshDolphinInternalLibrary'));
      expect(dialog, contains('SqliteDatabaseProvider'));
      expect(dialog, contains('Select all'));
    });
  });
}
