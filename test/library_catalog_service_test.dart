import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/library_addon_service.dart';
import 'package:neostation/services/library_catalog_service.dart';

void main() {
  group('Native Library source classification', () {
    test('recognizes a browsable NeoStation catalog source', () {
      final addon = LibraryAddon.fromManifest({
        'schema': LibraryAddon.schemaV1,
        'id': 'com.example.books',
        'name': 'Example Books',
        'version': '1.0.0',
        'baseUrl': 'https://example.com/api/',
        'endpoints': {
          'catalog': 'catalog.json',
          'search': 'search?q={query}',
        },
      }, origin: 'https://example.com/manifest.json');

      expect(addon.sourceKind, LibrarySourceKind.catalog);
      expect(addon.canBrowseOnIos, isTrue);
      expect(addon.catalogEndpoint, 'catalog.json');
      expect(addon.searchEndpoint, 'search?q={query}');
    });

    test('accepts a native local-library declaration without baseUrl', () {
      final addon = LibraryAddon.fromManifest({
        'schema': LibraryAddon.schemaV1,
        'id': 'local.reading',
        'name': 'Local Reading',
        'version': '1.0.0',
        'sourceType': 'local-library',
      }, origin: 'file:local.json');

      expect(addon.sourceKind, LibrarySourceKind.localLibrary);
      expect(addon.baseUrl, isNull);
      expect(addon.canBrowseOnIos, isFalse);
    });

    test('keeps Tachiyomi APK-backed entries out of the native catalog', () {
      final addon = LibraryAddon.fromManifest({
        'schema': LibraryAddon.schemaV1,
        'id': 'tachiyomi.example.source',
        'name': 'Example Source',
        'version': '1.0.0',
        'baseUrl': 'https://example.com',
        'iosCompatibility': 'metadata-only',
        'provider': {
          'type': LibraryAddon.tachiyomiProviderType,
          'package': 'eu.kanade.tachiyomi.extension.example',
        },
      }, origin: 'file:repo.json');

      expect(addon.sourceKind, LibrarySourceKind.metadataOnly);
      expect(addon.canBrowseOnIos, isFalse);
    });
  });

  group('Native Library catalog normalization', () {
    test('normalizes cover, metadata and relative reader URLs', () {
      final item = LibraryCatalogItem.fromJson({
        'id': 'book-1',
        'title': 'A Native Book',
        'type': 'book',
        'author': 'Neo Author',
        'summary': 'A normalized catalog entry.',
        'cover': 'covers/book-1.webp',
        'readerUrl': 'reader/book-1.txt',
      }, baseUri: Uri.parse('https://example.com/api/'));

      expect(item.id, 'book-1');
      expect(item.mediaType, LibraryMediaType.book);
      expect(item.subtitle, 'Neo Author');
      expect(item.description, 'A normalized catalog entry.');
      expect(item.coverUrl, 'https://example.com/api/covers/book-1.webp');
      expect(item.contentUrl, 'https://example.com/api/reader/book-1.txt');
      expect(item.hasReadableContent, isTrue);
    });

    test('normalizes image pages for an in-app manga reader', () {
      final item = LibraryCatalogItem.fromJson({
        'name': 'Chapter One',
        'type': 'manga',
        'pages': [
          'pages/001.webp',
          'https://cdn.example.com/002.webp',
          'http://unsafe.example.com/003.webp',
        ],
      }, baseUri: Uri.parse('https://example.com/manga/'));

      expect(item.mediaType, LibraryMediaType.manga);
      expect(item.pageUrls, [
        'https://example.com/manga/pages/001.webp',
        'https://cdn.example.com/002.webp',
      ]);
      expect(item.hasReadableContent, isTrue);
    });

    test('parses Gallica OPDS acquisitions as readable EPUB books', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>https://gallica.bnf.fr/ark:/12148/bpt6k123</id>
    <title>Un livre du domaine public</title>
    <author><name>Auteur Exemple</name></author>
    <summary>Résumé du livre.</summary>
    <link
      rel="http://opds-spec.org/image"
      type="image/jpeg"
      href="http://gallica.bnf.fr/ark:/12148/bpt6k123.highres" />
    <link
      rel="http://opds-spec.org/acquisition"
      type="application/epub+zip"
      href="http://gallica.bnf.fr/ark:/12148/bpt6k123.epub" />
  </entry>
  <entry>
    <id>navigation</id>
    <title>Catégorie</title>
    <link
      rel="subsection"
      type="application/atom+xml"
      href="https://gallica.bnf.fr/opds?query=test" />
  </entry>
</feed>
''';

      final items = LibraryCatalogService.parseGallicaOpdsDocument(
        xml,
        baseUri: Uri.parse('https://gallica.bnf.fr/'),
      );

      expect(items, hasLength(1));
      final book = items.single;
      expect(book.title, 'Un livre du domaine public');
      expect(book.subtitle, 'Auteur Exemple');
      expect(book.mediaType, LibraryMediaType.book);
      expect(
        book.coverUrl,
        'https://gallica.bnf.fr/ark:/12148/bpt6k123.highres',
      );
      expect(
        book.contentUrl,
        'https://gallica.bnf.fr/ark:/12148/bpt6k123.epub',
      );
      expect(book.raw['contentType'], 'application/epub+zip');
      expect(book.hasReadableContent, isTrue);
    });
  });
}
