import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/library_metadata_provider_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('parses BnF Dublin Core records into metadata-only items', () {
    const xml = '''
      <srw:searchRetrieveResponse xmlns:srw="http://www.loc.gov/zing/srw/"
          xmlns:oai_dc="http://www.openarchives.org/OAI/2.0/oai_dc/"
          xmlns:dc="http://purl.org/dc/elements/1.1/">
        <srw:numberOfRecords>1</srw:numberOfRecords>
        <srw:records>
          <srw:record>
            <srw:recordData>
              <oai_dc:dc>
                <dc:title>Akira</dc:title>
                <dc:creator>Ōtomo, Katsuhiro</dc:creator>
                <dc:publisher>Glénat</dc:publisher>
                <dc:date>1990</dc:date>
                <dc:language>fre</dc:language>
                <dc:subject>Manga</dc:subject>
                <dc:description>Édition française.</dc:description>
                <dc:identifier>ark:/12148/cb12345678x</dc:identifier>
                <dc:identifier>ISBN 9781234567897</dc:identifier>
              </oai_dc:dc>
            </srw:recordData>
          </srw:record>
        </srw:records>
      </srw:searchRetrieveResponse>
    ''';

    final items = LibraryMetadataProviderService.parseBnfXml(xml);
    expect(items, hasLength(1));
    final item = items.single;
    expect(item.title, 'Akira');
    expect(item.subtitle, contains('Ōtomo'));
    expect(item.contentUrl, isNull);
    expect(item.pageUrls, isEmpty);
    expect(item.raw['metadataOnly'], isTrue);
    expect(item.raw['ark'], 'ark:/12148/cb12345678x');
    expect(item.raw['isbn'], contains('9781234567897'));
    expect(item.coverUrl, contains('recupererImage'));
  });
  test('parses the bundled Manga Provider registry format', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const raw = '''{
      "schemaVersion": 1,
      "name": "NeoStation Manga Metadata Providers",
      "contentPolicy": "metadata-only",
      "providers": [
        {
          "id": "jikan",
          "name": "Jikan",
          "kind": "manga_database",
          "transport": "rest",
          "baseURL": "https://api.jikan.moe/v4"
        }
      ]
    }''';

    final count = await LibraryMetadataProviderService.instance
        .importRegistryJsonIfSupported(raw);
    expect(count, 1);
    expect(
      LibraryMetadataProviderService.instance.providerLabels['jikan'],
      'Jikan',
    );
  });
}
