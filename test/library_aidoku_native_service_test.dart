import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/library_addon_service.dart';
import 'package:neostation/services/library_aidoku_native_service.dart';

LibraryAddon _aidokuAddon(String sourceId) {
  return LibraryAddon.fromManifest(
    <String, dynamic>{
      'schema': LibraryAddon.schemaV1,
      'id': 'aidoku.$sourceId',
      'name': sourceId,
      'version': '1',
      'baseUrl': 'https://example.com/',
      'iosCompatibility': 'metadata-only',
      'provider': <String, dynamic>{
        'type': LibraryAddon.aidokuProviderType,
        'sourceId': sourceId,
        'sourceLang': 'fr',
        'downloadUrl': 'https://example.com/source.aix',
        'repositoryOrigin': 'https://example.com/index.min.json',
      },
    },
    origin: 'https://example.com/index.min.json',
  );
}

void main() {
  final service = LibraryAidokuNativeService.instance;

  test('supports the currently working French Aidoku web sources', () {
    const supported = <String>[
      'fr.astralmanga',
      'fr.mangascantrad',
      'fr.mangasorigines',
      'fr.lelscanfr',
      'fr.phenixscans',
      'fr.sushiscan',
      'fr.sushiscans',
    ];

    for (final sourceId in supported) {
      expect(
        service.supports(_aidokuAddon(sourceId)),
        isTrue,
        reason: sourceId,
      );
    }
  });

  test('does not expose upstream-broken sources as native catalogs', () {
    const unsupported = <String>[
      'fr.reaperscans',
      'fr.mangascan',
      'fr.legacyscans',
    ];

    for (final sourceId in unsupported) {
      final addon = _aidokuAddon(sourceId);
      expect(service.supports(addon), isFalse, reason: sourceId);
      expect(service.unsupportedReason(addon), isNotNull, reason: sourceId);
    }
  });

  test('catalog page model preserves pagination metadata', () {
    const page = LibraryAidokuCatalogPage(
      items: [],
      page: 3,
      hasMore: true,
    );
    expect(page.page, 3);
    expect(page.hasMore, isTrue);
    expect(page.items, isEmpty);
  });

}
