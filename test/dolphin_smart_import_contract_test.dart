import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Dolphin smart import contract', () {
    test('DiscIO identity decides GameCube versus Wii', () {
      final source = File(
        'lib/services/dolphin_smart_import_service.dart',
      ).readAsStringSync();

      expect(source, contains("'saveIdentity'"));
      expect(source, contains("const <String>['gc', 'wii']"));
      expect(source, contains("identity['system']?.toString() == system"));
      expect(source, contains('DolphinInternalV2Service.libraryDirectory('));
      expect(source, contains('actualSystem'));
    });

    test('picker accepts the union of both Dolphin playlists', () {
      final source = File(
        'lib/services/dolphin_smart_import_service.dart',
      ).readAsStringSync();

      expect(
        source,
        contains("...DolphinInternalV2Service.extensionsFor('gc')"),
      );
      expect(
        source,
        contains("...DolphinInternalV2Service.extensionsFor('wii')"),
      );
      expect(source, contains('allowedExtensions: extensions'));
    });

    test('older misplaced private-library files are silently repaired', () {
      final source = File(
        'lib/services/dolphin_smart_import_service.dart',
      ).readAsStringSync();
      final widget = File(
        'lib/widgets/dolphin_internal_playlist_actions.dart',
      ).readAsStringSync();

      expect(source, contains('repairLibraryPlacement()'));
      expect(source, contains('actualSystem == declaredSystem'));
      expect(source, contains('await entity.rename(output.path)'));
      expect(widget, contains('_repairPlacement()'));
      expect(widget, contains('repairLibraryPlacement()'));
    });

    test('cross-routed imports refresh the opposite playlist', () {
      final widget = File(
        'lib/widgets/dolphin_internal_playlist_actions.dart',
      ).readAsStringSync();

      expect(widget, contains('DolphinSmartImportService.importGames('));
      expect(widget, contains('result.changedSystems'));
      expect(widget, contains('refreshDolphinInternalLibrary(system)'));
    });
  });
}
