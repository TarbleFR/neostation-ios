import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Library source policy', () {
    test('Gallica is import-only while compatibility remains', () {
      final addons = File('lib/services/library_addon_service.dart')
          .readAsStringSync();
      final catalog = File('lib/services/library_catalog_service.dart')
          .readAsStringSync();
      final screen = File('lib/screens/library_screen/library_screen.dart')
          .readAsStringSync();

      expect(addons, isNot(contains('_builtInGallicaAddon')));
      expect(addons, isNot(contains('gallicaAddonId')));
      expect(addons, contains("gallicaProviderType = 'gallica-opds'"));
      expect(addons, contains('isGallicaSource'));
      expect(catalog, contains('parseGallicaOpdsDocument'));
      expect(screen, isNot(contains('Les sources natives sont conservées')));
      expect(screen, contains('entry.source?.isGallicaSource == true'));
    });

    test('other Library compatibility layers remain present', () {
      expect(
        File('lib/services/library_mangadex_service.dart').existsSync(),
        isTrue,
      );
      expect(File('assets/data/manga-providers.json').existsSync(), isFalse);
      final metadata = File(
        'lib/services/library_metadata_provider_service.dart',
      );
      expect(metadata.existsSync(), isTrue);
      final metadataSource = metadata.readAsStringSync();
      expect(metadataSource, isNot(contains('rootBundle.loadString')));
      expect(metadataSource, isNot(contains('manifestAsset')));
    });
  });
}
