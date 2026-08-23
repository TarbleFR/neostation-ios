import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';

void main() {
  group('Fin cold-start persistence', () {
    test('Fin virtual rows survive normal physical ROM scans', () {
      expect(
        SqliteDatabaseService.isPersistentExternalLibraryPath(
          'fin://launch?system=wii&id=RMCP01&game=Mario%20Kart%20Wii.rvz',
        ),
        isTrue,
      );
      expect(
        SqliteDatabaseService.isPersistentExternalLibraryPath(
          '/roms/wii/game.rvz',
        ),
        isFalse,
      );
    });

    test('Fin startup restore is native-only on iOS', () {
      final source = File('lib/services/fin_library_service.dart')
          .readAsStringSync();
      expect(
        source,
        contains('final discovery = await _discoverLibraryNatively('),
      );
      expect(source, isNot(contains('nativeDiscovery ??')));
      expect(
        source,
        isNot(contains('if (root != null && await Directory(root).exists())')),
      );
      expect(
        source,
        contains("final discoveryMode = Platform.isIOS ? 'native-ios' : 'dart'"),
      );
    });

    test('Fin writes the exact Shortcut payload to a diagnostic file', () {
      final source = File('lib/services/fin_library_service.dart')
          .readAsStringSync();
      expect(source, contains('fin_launch_debug.txt'));
      expect(source, contains('Shortcut input (Nintendo Game ID)'));
      expect(source, contains('Native candidates:'));
      expect(source, contains('Unreadable prefixes:'));
    });
  });
}
