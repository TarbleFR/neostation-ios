import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/library_catalog_service.dart';
import 'package:neostation/services/library_download_service.dart';
import 'package:neostation/services/library_metadata_provider_service.dart';

void main() {
  test('parses source-declared acquisition links without inventing URLs', () {
    final item = LibraryCatalogItem.fromJson(<String, dynamic>{
      'id': 'legal-book',
      'title': 'Legal Book',
      'type': 'book',
      'acquisitionLinks': <Map<String, dynamic>>[
        <String, dynamic>{
          'label': 'EPUB',
          'url': 'https://example.org/books/legal.epub',
          'action': 'download',
          'format': 'epub',
          'mimeType': 'application/epub+zip',
        },
        <String, dynamic>{
          'label': 'Reader',
          'url': 'https://example.org/read/legal',
          'action': 'read',
        },
      ],
    }, baseUri: Uri.parse('https://example.org/'));

    expect(item.acquisitionLinks, hasLength(2));
    expect(item.acquisitionLinks.first.canDownload, isTrue);
    expect(item.acquisitionLinks.first.format, 'epub');
    expect(item.acquisitionLinks.last.isExternalReader, isTrue);
  });

  test('rejects non-HTTPS acquisition URLs', () {
    final item = LibraryCatalogItem.fromJson(<String, dynamic>{
      'id': 'unsafe',
      'title': 'Unsafe',
      'type': 'book',
      'downloadUrl': 'http://example.org/file.epub',
    }, baseUri: Uri.parse('https://example.org/'));

    expect(item.acquisitionLinks, isEmpty);
  });

  test('Google Books exposes only explicitly available official links', () {
    final links =
        LibraryMetadataProviderService.googleBooksAcquisitionsFromAccessInfo(
          <String, dynamic>{
            'epub': <String, dynamic>{
              'isAvailable': true,
              'downloadLink': 'https://books.googleusercontent.com/book.epub',
            },
            'pdf': <String, dynamic>{
              'isAvailable': false,
              'downloadLink': 'https://books.googleusercontent.com/book.pdf',
            },
            'webReaderLink': 'https://play.google.com/books/reader?id=test',
          },
        );

    expect(links.where((link) => link.canDownload), hasLength(1));
    expect(links.first.format, 'epub');
    expect(links.any((link) => link.isExternalReader), isTrue);
    expect(links.any((link) => link.format == 'pdf'), isFalse);
  });

  test('download service creates a safe deterministic filename', () {
    const acquisition = LibraryAcquisitionLink(
      label: 'EPUB',
      url: 'https://example.org/download?id=123',
      action: 'download',
      format: 'epub',
      mimeType: 'application/epub+zip',
    );

    final fileName = LibraryDownloadService.suggestedFileName(
      title: 'Manga: Tome 1 / édition spéciale',
      acquisition: acquisition,
    );
    expect(fileName, endsWith('.epub'));
    expect(fileName, isNot(contains('/')));
    expect(fileName, isNot(contains(':')));
  });
}
