import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/libretro_skin_catalog_service.dart';
import 'package:neostation/services/libretro_skin_service.dart';
import 'package:path/path.dart' as path;

const _channel = MethodChannel('neostation/libretro_internal');

/// Shape of https://provenance-emu.com/skins/catalog.json (version 2),
/// reduced to the cases NeoStation handles.
const _catalog = '''
{
  "version": 2,
  "lastUpdated": "2026-10-04T05:11:24Z",
  "totalSkins": 9,
  "skins": [
    {"id": "a1", "name": "Lux GBA", "author": "Polyphian", "systems": ["gba"],
     "gameTypeIdentifier": "com.rileytestut.delta.game.gba",
     "downloadURL": "https://raw.githubusercontent.com/Polyphian/deltaEmu/main/gba/Lux.deltaskin",
     "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/a1.png",
     "downloadCount": 120, "source": "github.com/Polyphian/deltaEmu", "description": "Dark GBA skin"},
    {"id": "b2", "name": "Litboy Color", "author": "LitRitt", "systems": ["gbc"],
     "gameTypeIdentifier": null,
     "downloadURL": "https://github.com/delta-skins/delta-skins.github.io/raw/master/gbc/itephra#1717_GBC.deltaskin",
     "thumbnailURL": null, "downloadCount": null, "source": "delta-skins.github.io"},
    {"id": "c3", "name": "Genesis Classic", "author": "someone", "systems": ["genesis"],
     "gameTypeIdentifier": null, "downloadURL": "https://deltastyles.com/files/skins/1/Genesis.manicskin",
     "downloadCount": 7, "source": "deltastyles.com"},
    {"id": "d4", "name": "Modern Black", "author": "stars33k", "systems": ["threeDS"],
     "gameTypeIdentifier": null, "downloadURL": "https://drive.google.com/uc?export=download&id=abc",
     "downloadCount": 3, "source": "deltastyles.com"},
    {"id": "e5", "name": "Touch Max", "author": "colinh68", "systems": ["gba"],
     "gameTypeIdentifier": null, "downloadURL": "https://colinh68.gumroad.com/l/deltatouchmax2",
     "downloadCount": 1, "source": "gumroad"},
    {"id": "f6", "name": "Mark III", "author": "HoriZon", "systems": ["masterSystem"],
     "gameTypeIdentifier": null, "downloadURL": "https://deltastyles.com/files/skins/2/ms.manicskin"},
    {"id": "g7", "name": "ClearDoom", "author": "starvingartist", "systems": ["dos"],
     "gameTypeIdentifier": "public.aoshuang.game.dos",
     "downloadURL": "https://deltastyles.com/files/skins/674/cleardoom.manicskin"},
    {"id": "h8", "name": "No link", "author": "nobody", "systems": ["gba"], "downloadURL": null},
    {"id": "i9", "name": "Plain http", "author": "nobody", "systems": ["gba"],
     "downloadURL": "http://example.com/skin.deltaskin"}
  ]
}
''';

List<int> _skinArchive() {
  final archive = Archive()
    ..add(ArchiveFile.bytes(
      'info.json',
      utf8.encode(jsonEncode(<String, Object?>{
        'name': 'Lux GBA',
        'identifier': 'com.polyphian.lux.gba',
        'gameTypeIdentifier': 'com.rileytestut.delta.game.gba',
        'representations': <String, Object?>{},
      })),
    ));
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final entries = LibretroSkinCatalogService.parse(_catalog);
  LibretroSkinCatalogEntry byId(String id) => entries.singleWhere((entry) => entry.id == id);
  List<String> ids(Iterable<LibretroSkinCatalogEntry> list) => list.map((entry) => entry.id).toList();

  late Directory root;
  late LibretroSkinService skins;
  late List<MethodCall> nativeCalls;

  LibretroSkinCatalogService catalogService(http.Client client, {DateTime Function()? clock, int? maxBytes}) =>
      LibretroSkinCatalogService(
        cacheDirectory: path.join(root.path, 'Caches'),
        skins: skins,
        client: client,
        clock: clock,
        maxDownloadBytes: maxBytes ?? LibretroSkinService.maxArchiveBytes,
      );

  List<FileSystemEntity> leftoverDownloads() {
    final folder = Directory(path.join(root.path, 'Caches', LibretroSkinCatalogService.downloadsFolderName));
    return folder.existsSync() ? folder.listSync() : const <FileSystemEntity>[];
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('libretro-skin-catalog-');
    nativeCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      nativeCalls.add(call);
      if (call.method != 'inspectSkin') return null;
      final directory = (call.arguments as Map)['directory'] as String;
      final info = jsonDecode(File(path.join(directory, 'info.json')).readAsStringSync()) as Map;
      return <String, Object?>{
        'ok': true,
        'summary': <String, Object?>{
          'identifier': info['identifier'],
          'name': info['name'],
          'author': 'Author in info.json',
          'consoles': <String>['gba'],
          'gameTypeIdentifier': info['gameTypeIdentifier'],
          'orientations': <String, Object?>{'iphone': <String>['portrait'], 'ipad': <String>[]},
          'warnings': <String>[],
        },
      };
    });
    skins = LibretroSkinService(
      skinsDirectory: path.join(root.path, 'Skins'),
      frontendDirectory: path.join(root.path, 'Config', 'Frontend'),
      cacheDirectory: path.join(root.path, 'Caches'),
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_channel, null);
    await root.delete(recursive: true);
  });

  test('catalog entries are parsed, with optional fields left empty', () {
    expect(ids(entries), <String>['a1', 'b2', 'c3', 'd4', 'e5', 'f6', 'g7', 'i9']);
    final lux = byId('a1');
    expect(lux.name, 'Lux GBA');
    expect(lux.author, 'Polyphian');
    expect(lux.systems, <String>['gba']);
    expect(lux.gameTypeIdentifier, 'com.rileytestut.delta.game.gba');
    expect(lux.downloadCount, 120);
    expect(lux.thumbnailURL, endsWith('/a1.png'));
    expect(lux.source, 'github.com/Polyphian/deltaEmu');
    expect(lux.description, 'Dark GBA skin');
    final litboy = byId('b2');
    expect(litboy.gameTypeIdentifier, isNull);
    expect(litboy.downloadCount, isNull);
    expect(litboy.thumbnailURL, isNull);
    expect(litboy.description, isNull);
    expect(() => LibretroSkinCatalogService.parse('{"skins": 3}'), throwsFormatException);
  });

  test('entries are filtered by NeoStation console through the catalog system codes', () {
    List<String> forConsole(String console) => ids(LibretroSkinCatalogService.forConsole(entries, console));
    expect(forConsole('gba'), <String>['a1', 'e5', 'i9']);
    // The catalog files Game Boy skins under "gbc".
    expect(forConsole('gb'), <String>['b2']);
    expect(forConsole('gbc'), <String>['b2']);
    expect(forConsole('md'), <String>['c3']);
    expect(forConsole('mcd'), <String>['c3']);
    expect(forConsole('32x'), <String>['c3']);
    expect(forConsole('3ds'), <String>['d4']);
    expect(forConsole('sms'), <String>['f6']);
    expect(forConsole('nes'), isEmpty);
    expect(forConsole('unknown'), isEmpty);
    expect(byId('b2').consoles, <String>['gb', 'gbc']);
    expect(byId('c3').consoles, <String>['md', 'mcd', '32x']);
    expect(byId('g7').consoles, isEmpty);
  });

  test('search looks at names and authors', () {
    expect(ids(LibretroSkinCatalogService.search(entries, 'LUX')), <String>['a1']);
    expect(ids(LibretroSkinCatalogService.search(entries, 'litritt')), <String>['b2']);
    expect(LibretroSkinCatalogService.search(entries, '  '), hasLength(entries.length));
  });

  test('only links to skin files are direct downloads', () {
    expect(byId('a1').isDirectDownload, isTrue);
    expect(byId('c3').isDirectDownload, isTrue);
    expect(byId('d4').isDirectDownload, isTrue);
    expect(byId('e5').isDirectDownload, isFalse);
    expect(byId('i9').isDirectDownload, isFalse);
    // The '#' belongs to the file name, not to a fragment.
    final litboy = byId('b2');
    expect(litboy.isDirectDownload, isTrue);
    expect(litboy.downloadUri!.path, endsWith('/itephra%231717_GBC.deltaskin'));
    expect(litboy.downloadUri!.hasFragment, isFalse);
  });

  test('the catalog is fetched once a day, from GitHub when the site fails, and cached', () async {
    final requests = <String>[];
    var siteUp = false;
    var online = true;
    final client = MockClient((request) async {
      requests.add(request.url.toString());
      if (!online) throw const SocketException('offline');
      if (request.url.host == 'provenance-emu.com' && !siteUp) return http.Response('busy', 503);
      return http.Response(_catalog, 200);
    });
    var now = DateTime.now();
    final service = catalogService(client, clock: () => now);

    expect(await service.load(), hasLength(8));
    expect(requests, <String>[LibretroSkinCatalogService.catalogUrl, LibretroSkinCatalogService.fallbackCatalogUrl]);
    final cache = File(path.join(root.path, 'Caches', LibretroSkinCatalogService.cacheFileName));
    expect(cache.existsSync(), isTrue);

    requests.clear();
    expect(await service.load(), hasLength(8));
    expect(requests, isEmpty);

    siteUp = true;
    now = now.add(const Duration(hours: 25));
    expect(await service.load(), hasLength(8));
    expect(requests, <String>[LibretroSkinCatalogService.catalogUrl]);

    requests.clear();
    online = false;
    expect(await service.load(refresh: true), hasLength(8), reason: 'the older copy is kept offline');
    expect(requests, hasLength(2));

    await cache.delete();
    expect(await service.load(refresh: true), isNull);
  });

  test('a link that is not a skin archive is refused before the import', () async {
    final service = catalogService(MockClient((request) async => http.Response(
          '<!DOCTYPE html><html><body>Download page</body></html>',
          200,
          headers: <String, String>{'content-type': 'text/html'},
        )));
    final result = await service.download(byId('a1'));
    expect(result, isA<LibretroSkinImportFailed>());
    expect((result as LibretroSkinImportFailed).messageKey, LibretroSkinMessages.notArchive);
    expect(nativeCalls.where((call) => call.method == 'inspectSkin'), isEmpty);
    expect(leftoverDownloads(), isEmpty);
  });

  test('store pages, failed requests and oversized files are refused', () async {
    var called = false;
    final storeService = catalogService(MockClient((request) async {
      called = true;
      return http.Response('', 200);
    }));
    final store = await storeService.download(byId('e5')) as LibretroSkinImportFailed;
    expect(store.messageKey, LibretroSkinMessages.notDirect);
    expect(called, isFalse);

    final missing = await catalogService(MockClient((request) async => http.Response('gone', 404)))
        .download(byId('a1')) as LibretroSkinImportFailed;
    expect(missing.messageKey, LibretroSkinMessages.download);
    expect(missing.technicalDetails, contains('404'));

    final declared = await catalogService(
      MockClient((request) async => http.Response.bytes(_skinArchive(), 200)),
      maxBytes: 16,
    ).download(byId('a1')) as LibretroSkinImportFailed;
    expect(declared.messageKey, LibretroSkinMessages.tooLarge);

    final streamed = await catalogService(
      MockClient.streaming((request, body) async => http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              _skinArchive().sublist(0, 8),
              List<int>.filled(64, 0),
            ]),
            200,
          )),
      maxBytes: 16,
    ).download(byId('a1')) as LibretroSkinImportFailed;
    expect(streamed.messageKey, LibretroSkinMessages.tooLarge);
    expect(nativeCalls.where((call) => call.method == 'inspectSkin'), isEmpty);
    expect(leftoverDownloads(), isEmpty);
  });

  test('a downloaded skin is installed with its link and catalog author', () async {
    Uri? requested;
    final service = catalogService(MockClient((request) async {
      requested = request.url;
      return http.Response.bytes(_skinArchive(), 200);
    }));
    final result = await service.download(byId('a1'));
    expect(result, isA<LibretroSkinImported>());
    final skin = (result as LibretroSkinImported).skin;
    expect(requested.toString(), byId('a1').downloadURL);
    expect(skin.source, byId('a1').downloadURL);
    expect(skin.author, 'Polyphian');
    final metadata = jsonDecode(
      File(path.join(skin.directory, LibretroSkinService.metadataFileName)).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(metadata['source'], 'https://raw.githubusercontent.com/Polyphian/deltaEmu/main/gba/Lux.deltaskin');
    expect(metadata['author'], 'Polyphian');
    expect(leftoverDownloads(), isEmpty);
  });
}
