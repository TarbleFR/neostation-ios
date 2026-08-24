import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/rpcs3_launch_service.dart';
import 'package:neostation/services/rpcs3_library_service.dart';
import 'package:neostation/services/rpcs3_title_catalog_service.dart';

void main() {
  group('RPCS3 reliability', () {
    test(
      'cached raw serial receives GameDB title even without live folder',
      () async {
        final enriched = await Rpcs3LibraryService.applyTitleCatalogForTesting(
          const <Rpcs3LibraryGame>[
            Rpcs3LibraryGame(
              titleId: 'BLES00412',
              title: 'BLES00412',
              version: '',
              category: '',
              sourcePath: '/unavailable/RPCS3/Data/game.iso',
              sourceKind: 'games.yml',
            ),
          ],
          const <String, String>{
            'BLES00412': 'The Lord of the Rings: Conquest',
          },
        );
        expect(enriched.single.title, 'The Lord of the Rings: Conquest');
      },
    );

    test('GameDB normalization accepts dashed PS3 serials', () {
      expect(
        Rpcs3TitleCatalogService.normalizeTitleId('BLES-00412'),
        'BLES00412',
      );
    });

    test('launcher validates serials and uses Universal JIT', () {
      expect(Rpcs3LaunchService.normalizeTitleId('bles00412'), 'BLES00412');
      expect(Rpcs3LaunchService.normalizeTitleId(''), isNull);

      final service = File(
        'lib/services/rpcs3_launch_service.dart',
      ).readAsStringSync();
      expect(service, contains('openJitRequest'));
      expect(service, contains("scriptName: 'universal.js'"));
      expect(service, contains('rpcs3_launch_debug.txt'));
    });
  });
}
