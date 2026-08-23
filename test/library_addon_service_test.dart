import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/library_addon_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('LibraryAddon manifest validation', () {
    test('accepts NeoStation Library v1 HTTPS manifest', () {
      final addon = LibraryAddon.fromManifest({
        'schema': 'neostation.library.v1',
        'id': 'com.example.manga',
        'name': 'Example Manga',
        'version': '1.0.0',
        'baseUrl': 'https://example.com/api',
        'description': 'Example catalog',
        'endpoints': {'search': '/search?q={query}'},
      }, origin: 'https://example.com/manifest.json');

      expect(addon.id, 'com.example.manga');
      expect(addon.name, 'Example Manga');
      expect(addon.version, '1.0.0');
      expect(addon.baseUrl, 'https://example.com/api');
    });

    test('rejects unsupported schema', () {
      expect(
        () => LibraryAddon.fromManifest({
          'schema': 'other.schema',
          'id': 'com.example.manga',
          'name': 'Example Manga',
          'version': '1.0.0',
          'baseUrl': 'https://example.com/api',
        }, origin: 'local'),
        throwsA(isA<LibraryAddonException>()),
      );
    });

    test('rejects non-HTTPS catalog base URL', () {
      expect(
        () => LibraryAddon.fromManifest({
          'schema': 'neostation.library.v1',
          'id': 'com.example.manga',
          'name': 'Example Manga',
          'version': '1.0.0',
          'baseUrl': 'http://example.com/api',
        }, origin: 'local'),
        throwsA(isA<LibraryAddonException>()),
      );
    });
  });

  group('Tachiyomi/Mihon repository import', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('imports repository array and expands nested sources', () async {
      final raw = jsonEncode([
        {
          'name': 'Example One',
          'pkg': 'eu.kanade.tachiyomi.extension.en.exampleone',
          'apk': 'tachiyomi-en.exampleone-v1.0.0.apk',
          'lang': 'en',
          'code': 1,
          'version': '1.0.0',
          'nsfw': 0,
          'sources': [
            {
              'name': 'Example One',
              'lang': 'en',
              'id': '101',
              'baseUrl': 'https://one.example.com',
            },
          ],
        },
        {
          'name': 'Example Two',
          'pkg': 'eu.kanade.tachiyomi.extension.fr.exampletwo',
          'apk': 'tachiyomi-fr.exampletwo-v2.0.0.apk',
          'lang': 'fr',
          'code': 2,
          'version': '2.0.0',
          'nsfw': 0,
          'sources': [
            {
              'name': 'Example Two',
              'lang': 'fr',
              'id': '202',
              'baseUrl': 'https://two.example.com',
            },
          ],
        },
      ]);

      final result = await LibraryAddonService.instance.installDocumentFromJson(
        raw,
        origin: 'https://example.com/index.json',
      );

      expect(result.format, LibraryAddonDocumentFormat.tachiyomiRepository);
      expect(result.totalCount, 2);
      expect(result.addedCount, 2);
      expect(result.updatedCount, 0);
      expect(result.addons.first.isTachiyomiRepositorySource, isTrue);
      expect(result.addons.first.isMetadataOnlyOnIos, isTrue);
      expect(result.addons.first.androidApk, isNotEmpty);
      expect(result.addons.map((item) => item.id).toSet().length, 2);
    });

    test('imports current Keiyoushi extensionList repository object', () async {
      final raw = jsonEncode({
        'name': 'Keiyoushi',
        'extensionList': {
          'extensions': [
            {
              'name': 'Example Modern',
              'packageName': 'eu.kanade.tachiyomi.extension.fr.examplemodern',
              'resources': {
                'apkUrl':
                    'https://github.com/example/releases/example-modern.apk',
                'iconUrl': 'https://example.com/icon.png',
              },
              'extensionLib': '1.4',
              'versionCode': '7',
              'versionName': '1.4.7',
              'contentWarning': 'CONTENT_WARNING_NONE',
              'sources': [
                {
                  'id': '7001',
                  'name': 'Example Modern FR',
                  'language': 'fr',
                  'homeUrl': 'https://modern.example.com',
                },
              ],
            },
          ],
        },
      });

      final result = await LibraryAddonService.instance.installDocumentFromJson(
        raw,
        origin: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.json',
      );

      expect(result.format, LibraryAddonDocumentFormat.tachiyomiRepository);
      expect(result.totalCount, 1);
      expect(result.addons.single.name, 'Example Modern FR');
      expect(result.addons.single.language, 'fr');
      expect(
        result.addons.single.androidPackage,
        'eu.kanade.tachiyomi.extension.fr.examplemodern',
      );
      expect(
        result.addons.single.androidApk,
        'https://github.com/example/releases/example-modern.apk',
      );
    });

    test(
      'does not install Keiyoushi migration-warning pseudo sources',
      () async {
        final raw = jsonEncode([
          {
            'name': 'Outdated App',
            'pkg': 'eu.kanade.tachiyomi.extension.all.keiyoushi',
            'apk': 'tachiyomi-all.keiyoushi-v1.4.1.apk',
            'lang': 'all',
            'version': '1.4.1',
            'sources': [
              {
                'name': 'Outdated App',
                'lang': 'all',
                'id': '1',
                'baseUrl': 'https://keiyoushi.github.io',
              },
            ],
          },
          {
            'name': 'Update to Mihon 0.20.1+',
            'pkg': 'eu.kanade.tachiyomi.extension.all.mihon',
            'apk': 'tachiyomi-all.mihon-v1.4.1.apk',
            'lang': 'all',
            'version': '1.4.1',
            'sources': [
              {
                'name': 'Update to Mihon 0.20.1+',
                'lang': 'all',
                'id': '1',
                'baseUrl': 'https://mihon.app',
              },
            ],
          },
        ]);

        await expectLater(
          LibraryAddonService.instance.installDocumentFromJson(
            raw,
            origin: 'https://example.com/index.min.json',
          ),
          throwsA(isA<LibraryAddonException>()),
        );
      },
    );

    test('ignores non-HTTPS repository sources', () async {
      final raw = jsonEncode([
        {
          'name': 'Mixed',
          'pkg': 'eu.example.mixed',
          'version': '1.0.0',
          'sources': [
            {'name': 'Unsafe', 'id': '1', 'baseUrl': 'http://example.com'},
            {'name': 'Safe', 'id': '2', 'baseUrl': 'https://example.com'},
          ],
        },
      ]);

      final result = await LibraryAddonService.instance.installDocumentFromJson(
        raw,
        origin: 'file:test.json',
      );
      expect(result.totalCount, 1);
      expect(result.addons.single.name, 'Safe');
    });

    test('imports legacy Aidoku source-list entries', () async {
      final raw = jsonEncode([
        {
          'id': 'fr.example',
          'name': 'Example FR',
          'file': 'fr.example-v2.aix',
          'icon': 'fr.example-v2.png',
          'lang': 'fr',
          'version': 2,
          'nsfw': 0,
        },
      ]);

      final result = await LibraryAddonService.instance.installDocumentFromJson(
        raw,
        origin: 'https://raw.githubusercontent.com/example/aidoku/gh-pages/index.min.json',
      );

      expect(result.format, LibraryAddonDocumentFormat.aidokuRepository);
      expect(result.totalCount, 1);
      expect(result.addons.single.isAidokuRepositorySource, isTrue);
      expect(result.addons.single.language, 'fr');
      expect(
        result.addons.single.sourceDownloadUrl,
        'https://raw.githubusercontent.com/example/aidoku/gh-pages/sources/fr.example-v2.aix',
      );
    });

    test('removes every source belonging to one imported repository', () async {
      final raw = jsonEncode([
        {
          'id': 'fr.one',
          'name': 'One',
          'file': 'fr.one-v1.aix',
          'lang': 'fr',
          'version': 1,
        },
        {
          'id': 'fr.two',
          'name': 'Two',
          'file': 'fr.two-v1.aix',
          'lang': 'fr',
          'version': 1,
        },
      ]);
      const origin =
          'https://raw.githubusercontent.com/example/remove-test/gh-pages/index.min.json';
      await LibraryAddonService.instance.installDocumentFromJson(
        raw,
        origin: origin,
      );

      final removed = await LibraryAddonService.instance.removeRepository(
        origin,
      );
      expect(removed, 2);
      final remaining = await LibraryAddonService.instance.load();
      expect(
        remaining.where((item) => item.repositoryOrigin == origin),
        isEmpty,
      );
    });

    test('does not inject built-in Library sources', () async {
      final sources = await LibraryAddonService.instance.load();
      expect(sources.where((item) => item.isBuiltIn), isEmpty);
      expect(
        sources.where((item) => item.origin.startsWith('builtin:')),
        isEmpty,
      );
    });

    test('keeps explicitly imported Gallica OPDS compatible', () async {
      final raw = jsonEncode({
        'schema': LibraryAddon.schemaV1,
        'id': 'user.gallica.bnf',
        'name': 'Gallica / BnF',
        'version': '1',
        'baseUrl': 'https://gallica.bnf.fr/',
        'provider': {'type': LibraryAddon.gallicaProviderType},
        'endpoints': {
          'catalog': 'services/engine/search/opds?operation=searchRetrieve&version=1.2&maximumRecords=50',
        },
      });

      final result = await LibraryAddonService.instance.installDocumentFromJson(
        raw,
        origin: 'file:user-gallica.json',
      );
      final gallica = result.addons.single;
      expect(gallica.isBuiltIn, isFalse);
      expect(gallica.isGallicaSource, isTrue);
      expect(gallica.canBrowseOnIos, isTrue);
    });
  });
}
