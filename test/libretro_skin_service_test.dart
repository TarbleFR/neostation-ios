import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/libretro_locale.dart';
import 'package:neostation/services/libretro_skin_service.dart';
import 'package:path/path.dart' as path;

const _channel = MethodChannel('neostation/libretro_internal');

/// Stand-in for the native side of the bridge: the skin parser answers from
/// the unpacked info.json, the frontend store keeps its values in memory.
class FakeNative {
  final calls = <MethodCall>[];
  final stores = <String, Map<String, Object?>>{};
  final skinDirectoryPresentAtForget = <bool>[];
  Map<String, Object?> Function(String directory) inspect = deltaSummary;

  static Map<String, Object?> deltaSummary(String directory) {
    final info = jsonDecode(File(path.join(directory, 'info.json')).readAsStringSync()) as Map;
    return <String, Object?>{
      'ok': true,
      'summary': <String, Object?>{
        'identifier': info['identifier'],
        'name': info['name'],
        'author': null,
        'consoles': <String>['gba'],
        'gameTypeIdentifier': info['gameTypeIdentifier'],
        'orientations': <String, Object?>{
          'iphone': <String>['portrait', 'landscape'],
          'ipad': <String>['landscape'],
        },
        'warnings': <String>['SKIN_WARN_DEBUG_MISSING'],
        'debug': false,
      },
    };
  }

  Map<String, Object?> _store(String console) => stores.putIfAbsent(
        console,
        () => <String, Object?>{'console': <String, Object?>{}, 'games': <String, Object?>{}},
      );

  Map<String, Object?> _scope(String console, String? game) {
    final store = _store(console);
    if (game == null) return store['console'] as Map<String, Object?>;
    final games = store['games'] as Map<String, Object?>;
    return games.putIfAbsent(game, () => <String, Object?>{}) as Map<String, Object?>;
  }

  Iterable<MethodCall> named(String method) => calls.where((call) => call.method == method);

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final arguments = (call.arguments as Map).cast<String, Object?>();
    switch (call.method) {
      case 'inspectSkin':
        return inspect(arguments['directory'] as String);
      case 'frontendSettings':
        return _store(arguments['console'] as String);
      case 'setFrontendSetting':
        final scope = _scope(arguments['console'] as String, arguments['game'] as String?);
        final key = arguments['key'] as String;
        final value = arguments['value'];
        if (value == null) {
          scope.remove(key);
        } else {
          scope[key] = value;
        }
        return true;
      case 'forgetSkin':
        skinDirectoryPresentAtForget.add(Directory(arguments['skinDirectory'] as String).existsSync());
        final id = arguments['skinId'];
        for (final store in stores.values) {
          (store['console'] as Map).removeWhere((key, value) => value == id);
          for (final game in (store['games'] as Map).values) {
            (game as Map).removeWhere((key, value) => value == id);
          }
        }
        return null;
    }
    return null;
  }
}

List<int> infoJson({
  String identifier = 'com.example.skin',
  String name = 'Example',
  String type = 'com.rileytestut.delta.game.gba',
}) =>
    utf8.encode(jsonEncode(<String, Object?>{
      'name': name,
      'identifier': identifier,
      'gameTypeIdentifier': type,
      'representations': <String, Object?>{},
    }));

Uint8List zipOf(Map<String, List<int>> files, {Map<String, int> modes = const <String, int>{}}) {
  final archive = Archive();
  for (final entry in files.entries) {
    final file = ArchiveFile.bytes(entry.key, entry.value);
    final mode = modes[entry.key];
    if (mode != null) file.mode = mode;
    archive.add(file);
  }
  return ZipEncoder().encodeBytes(archive);
}

/// PNG signature and IHDR chunk declaring `width` x `height`.
List<int> pngHeader(int width, int height) {
  final size = ByteData(8)
    ..setUint32(0, width)
    ..setUint32(4, height);
  return <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
    ...size.buffer.asUint8List(),
    8, 6, 0, 0, 0, 0, 0, 0, 0,
  ];
}

Set<String> placeholders(String text) =>
    RegExp(r'\{(\w+)\}').allMatches(text).map((match) => match.group(1)!).toSet();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final english = LibretroLocale.values['en']!;
  late Directory root;
  late FakeNative native;
  late LibretroSkinService service;
  var archives = 0;

  String skinsPath() => path.join(root.path, 'Skins');
  String stagingPath() => path.join(skinsPath(), LibretroSkinService.stagingFolderName);

  Future<File> archiveFile(List<int> bytes) async {
    archives++;
    final file = File(path.join(root.path, 'incoming', 'skin$archives.deltaskin'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<LibretroSkinImportResult> importFiles(Map<String, List<int>> files, {Map<String, int> modes = const {}}) async =>
      service.importFromFile((await archiveFile(zipOf(files, modes: modes))).path);

  void expectRefused(LibretroSkinImportResult result, String key, {Map<String, Object> parameters = const {}}) {
    expect(result, isA<LibretroSkinImportFailed>());
    final failure = result as LibretroSkinImportFailed;
    expect(failure.messageKey, key);
    expect(failure.parameters, parameters);
    // The message can be formatted: every placeholder has its value.
    expect(english.containsKey(key), isTrue, reason: key);
    expect(placeholders(english[key]!), failure.parameters.keys.toSet(), reason: key);
  }

  void expectNothingInstalled() {
    final skins = Directory(skinsPath());
    if (!skins.existsSync()) return;
    expect(skins.listSync().map((entity) => path.basename(entity.path)).where(LibretroSkinService.isInstalledId),
        isEmpty);
    final staging = Directory(stagingPath());
    if (staging.existsSync()) expect(staging.listSync(), isEmpty);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('libretro-skins-');
    native = FakeNative();
    messenger.setMockMethodCallHandler(_channel, native.handle);
    service = LibretroSkinService(
      skinsDirectory: skinsPath(),
      frontendDirectory: path.join(root.path, 'Config', 'Frontend'),
      cacheDirectory: path.join(root.path, 'Caches'),
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_channel, null);
    await root.delete(recursive: true);
  });

  test('a valid skin is unpacked, parsed natively and described next to its files', () async {
    final bytes = zipOf(<String, List<int>>{
      'info.json': infoJson(name: 'Lux GBA'),
      'gba.pdf': utf8.encode('%PDF-1.4 portrait'),
      'assets/a.png': pngHeader(64, 64),
    });
    final digest = sha256.convert(bytes).toString();
    final result = await service.importFromFile((await archiveFile(bytes)).path);

    expect(result, isA<LibretroSkinImported>());
    final imported = result as LibretroSkinImported;
    final skin = imported.skin;
    expect(imported.alreadyInstalled, isFalse);
    expect(skin.id, digest.substring(0, 16));
    expect(skin.directory, path.join(skinsPath(), skin.id));
    expect(File(path.join(skin.directory, 'info.json')).existsSync(), isTrue);
    expect(File(path.join(skin.directory, 'gba.pdf')).readAsStringSync(), '%PDF-1.4 portrait');
    expect(File(path.join(skin.directory, 'assets', 'a.png')).existsSync(), isTrue);
    expect(imported.warningKeys, <String>['skinWarnDebugMissing']);
    expect(skin.supports('portrait'), isTrue);
    expect(skin.supports('portrait', iPad: true), isFalse);

    final metadata = jsonDecode(
      File(path.join(skin.directory, LibretroSkinService.metadataFileName)).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(metadata['id'], skin.id);
    expect(metadata['identifier'], 'com.example.skin');
    expect(metadata['name'], 'Lux GBA');
    expect(metadata['author'], isNull);
    expect(metadata['consoles'], <String>['gba']);
    expect(metadata['gameTypeIdentifier'], 'com.rileytestut.delta.game.gba');
    expect(metadata['orientations'], <String, Object?>{
      'iphone': <String>['portrait', 'landscape'],
      'ipad': <String>['landscape'],
    });
    expect(metadata['warnings'], <String>['SKIN_WARN_DEBUG_MISSING']);
    expect(metadata['source'], LibretroSkinService.sourceFile);
    expect(metadata['license'], isNull);
    expect(metadata['sha256'], digest);
    expect(DateTime.parse(metadata['importedAt'] as String).isUtc, isTrue);

    final inspect = native.named('inspectSkin').single;
    expect(path.isWithin(stagingPath(), inspect.arguments['directory'] as String), isTrue);
    expect((inspect.arguments['consoleGeometry'] as Map)['gba'], <String, Object>{'size': <int>[240, 160]});
    expect(Directory(stagingPath()).listSync(), isEmpty);

    final listed = await service.installedSkins(console: 'gba');
    expect(listed.map((installed) => installed.id), <String>[skin.id]);
    expect(listed.single.name, 'Lux GBA');
    expect(await service.installedSkins(console: 'nes'), isEmpty);
  });

  test('importing the same archive again changes nothing', () async {
    final bytes = zipOf(<String, List<int>>{'info.json': infoJson()});
    final first = await service.importFromFile((await archiveFile(bytes)).path) as LibretroSkinImported;
    final second = await service.importFromFile((await archiveFile(bytes)).path);
    expect(second, isA<LibretroSkinImported>());
    expect((second as LibretroSkinImported).alreadyInstalled, isTrue);
    expect(second.skin.id, first.skin.id);
    expect(native.named('inspectSkin'), hasLength(1));
    expect(Directory(stagingPath()).listSync(), isEmpty);
  });

  test('unsafe paths and links are refused before anything is written', () async {
    final cases = <String, Map<String, int>>{
      '../evil.png': const <String, int>{},
      '/tmp/evil.png': const <String, int>{},
      'skin\\evil.png': const <String, int>{},
      'Skin/../../evil.png': const <String, int>{},
      'evil.png': const <String, int>{'evil.png': 0xA1FF},
    };
    for (final entry in cases.entries) {
      final result = await importFiles(
        <String, List<int>>{'info.json': infoJson(), entry.key: pngHeader(16, 16)},
        modes: entry.value,
      );
      expectRefused(result, LibretroSkinMessages.unsafe);
    }
    expect(native.named('inspectSkin'), isEmpty);
    expect(root.listSync(recursive: true).where((entity) => path.basename(entity.path) == 'evil.png'), isEmpty);
    expectNothingInstalled();
  });

  test('archives with too many entries are refused', () async {
    final files = <String, List<int>>{'info.json': infoJson()};
    for (var index = 0; index < LibretroSkinService.maxEntries; index++) {
      files['parts/$index.txt'] = <int>[index & 0xff];
    }
    final result = await importFiles(files);
    expectRefused(result, LibretroSkinMessages.tooManyFiles, parameters: <String, Object>{'limit': 1024});
    expect(native.named('inspectSkin'), isEmpty);
    expectNothingInstalled();
  });

  test('an archive without info.json at its root or in a single folder is refused', () async {
    final layouts = <Map<String, List<int>>>[
      <String, List<int>>{'skin.json': infoJson(), 'a.png': pngHeader(8, 8)},
      <String, List<int>>{'A/B/info.json': infoJson(), 'A/B/a.png': pngHeader(8, 8)},
      <String, List<int>>{'A/info.json': infoJson(), 'B/info.json': infoJson()},
      <String, List<int>>{'A/info.json': infoJson(), 'readme.txt': utf8.encode('hello')},
    ];
    for (final files in layouts) {
      expectRefused(await importFiles(files), LibretroSkinMessages.infoMissing);
    }
    expect(native.named('inspectSkin'), isEmpty);
    expectNothingInstalled();
  });

  test('info.json inside one top-level folder becomes the skin root', () async {
    final result = await importFiles(<String, List<int>>{
      'Lux GBA/info.json': infoJson(),
      'Lux GBA/gba.pdf': utf8.encode('%PDF-1.4'),
    });
    final skin = (result as LibretroSkinImported).skin;
    expect(File(path.join(skin.directory, 'info.json')).existsSync(), isTrue);
    expect(File(path.join(skin.directory, 'gba.pdf')).existsSync(), isTrue);
    expect(Directory(path.join(skin.directory, 'Lux GBA')).existsSync(), isFalse);
  });

  test('macOS resource entries are ignored', () async {
    final result = await importFiles(<String, List<int>>{
      'Lux/info.json': infoJson(),
      'Lux/gba.pdf': utf8.encode('%PDF-1.4'),
      'Lux/.DS_Store': <int>[0, 1, 2],
      '__MACOSX/Lux/._info.json': <int>[0, 5, 22, 7],
      '__MACOSX/._Lux': <int>[0, 5, 22, 7],
    });
    final skin = (result as LibretroSkinImported).skin;
    final names = Directory(skin.directory)
        .listSync(recursive: true)
        .map((entity) => path.relative(entity.path, from: skin.directory))
        .toSet();
    expect(names, <String>{'info.json', 'gba.pdf', LibretroSkinService.metadataFileName});
  });

  test('size, expansion and image limits are enforced with translated messages', () async {
    final oversized = File(path.join(root.path, 'incoming', 'huge.deltaskin'));
    await oversized.parent.create(recursive: true);
    final handle = oversized.openSync(mode: FileMode.write)
      ..writeFromSync(<int>[0x50, 0x4B, 0x03, 0x04])
      ..truncateSync(LibretroSkinService.maxArchiveBytes + 1);
    handle.closeSync();
    expectRefused(await service.importFromFile(oversized.path), LibretroSkinMessages.tooLarge,
        parameters: <String, Object>{'limit': 50});

    // 2 MiB of zeros compress about a thousand times: a zip bomb pattern.
    expectRefused(
      await importFiles(<String, List<int>>{'info.json': infoJson(), 'bomb.bin': Uint8List(2 * 1024 * 1024)}),
      LibretroSkinMessages.expandedTooLarge,
      parameters: <String, Object>{'limit': 200},
    );

    expectRefused(
      await importFiles(<String, List<int>>{'info.json': infoJson(), 'huge.png': pngHeader(9000, 16)}),
      LibretroSkinMessages.imageTooLarge,
    );
    expect(native.named('inspectSkin'), isEmpty);
    expectNothingInstalled();

    final largest = await importFiles(<String, List<int>>{'info.json': infoJson(), 'big.png': pngHeader(8192, 8192)});
    expect(largest, isA<LibretroSkinImported>());
  });

  test('files that are not zip archives are refused', () async {
    final html = File(path.join(root.path, 'incoming', 'page.deltaskin'));
    await html.parent.create(recursive: true);
    await html.writeAsString('<!DOCTYPE html><html><body>Download</body></html>');
    expectRefused(await service.importFromFile(html.path), LibretroSkinMessages.notArchive);

    final truncated = await archiveFile(<int>[0x50, 0x4B, 0x03, 0x04, 1, 2, 3]);
    expectRefused(await service.importFromFile(truncated.path), LibretroSkinMessages.corrupt);
    expect(native.named('inspectSkin'), isEmpty);
    expectNothingInstalled();
  });

  test('native parser codes become translated messages and nothing is installed', () async {
    native.inspect = (_) => <String, Object?>{'ok': false, 'error': 'SKIN_CONSOLE_UNSUPPORTED'};
    final unsupported = await importFiles(<String, List<int>>{'info.json': infoJson(type: 'com.example.game.vb')});
    expectRefused(unsupported, LibretroSkinMessages.consoleUnsupported,
        parameters: <String, Object>{'type': 'com.example.game.vb'});
    expect((unsupported as LibretroSkinImportFailed).technicalDetails, contains('SKIN_CONSOLE_UNSUPPORTED'));

    native.inspect = (_) => <String, Object?>{'ok': false, 'error': 'SKIN_NO_DEVICE'};
    expectRefused(await importFiles(<String, List<int>>{'info.json': infoJson()}), 'skinErrorNoDevice');

    native.inspect = (_) => <String, Object?>{'ok': false, 'error': 'SKIN_SOMETHING_NEW', 'message': 'detail'};
    final unknown = await importFiles(<String, List<int>>{'info.json': infoJson()}) as LibretroSkinImportFailed;
    expect(unknown.messageKey, LibretroSkinMessages.importFailed);
    expect(unknown.technicalDetails, 'SKIN_SOMETHING_NEW: detail');
    expectNothingInstalled();
  });

  test('a skin with the same identifier is replaced only after confirmation', () async {
    final old = (await importFiles(<String, List<int>>{
      'info.json': infoJson(name: 'Old Name'),
      'gba.pdf': utf8.encode('%PDF-1.4 old'),
    }) as LibretroSkinImported)
        .skin;
    expect(await service.select(console: 'gba', orientation: 'portrait', skinId: old.id), isTrue);
    expect(await service.select(console: 'gba', orientation: 'landscape', skinId: old.id, game: 'gba/game.gba'),
        isTrue);

    final pending = await importFiles(<String, List<int>>{
      'info.json': infoJson(name: 'New Name'),
      'gba.pdf': utf8.encode('%PDF-1.4 new'),
    });
    expect(pending, isA<LibretroSkinNeedsReplaceConfirmation>());
    final confirmation = pending as LibretroSkinNeedsReplaceConfirmation;
    expect(confirmation.existingName, 'Old Name');
    expect(confirmation.skin.name, 'New Name');
    expect((await service.installedSkins()).map((installed) => installed.id), <String>[old.id]);
    expect(native.named('forgetSkin'), isEmpty);

    final replaced = await service.replace(confirmation);
    expect(replaced, isA<LibretroSkinImported>());
    final skin = (replaced as LibretroSkinImported).skin;
    expect(skin.name, 'New Name');
    expect(native.named('forgetSkin').single.arguments['skinId'], old.id);
    expect(Directory(old.directory).existsSync(), isFalse);
    expect(File(path.join(skin.directory, 'gba.pdf')).readAsStringSync(), '%PDF-1.4 new');
    expect((await service.installedSkins()).map((installed) => installed.id), <String>[skin.id]);
    // Remaps and layouts of the old skin are forgotten; its selections move.
    expect(await service.selectedSkins('gba'), <String, String?>{'portrait': skin.id, 'landscape': null});
    expect(await service.selectedSkins('gba', game: 'gba/game.gba'),
        <String, String?>{'portrait': null, 'landscape': skin.id});
    expect(Directory(stagingPath()).listSync(), isEmpty);
  });

  test('a cancelled replacement leaves the installed skin untouched', () async {
    final old = (await importFiles(<String, List<int>>{'info.json': infoJson(name: 'Old Name')})
            as LibretroSkinImported)
        .skin;
    final pending = await importFiles(<String, List<int>>{
      'info.json': infoJson(name: 'Other Name'),
      'extra.pdf': utf8.encode('%PDF-1.4'),
    }) as LibretroSkinNeedsReplaceConfirmation;
    await service.discard(pending);
    expect((await service.installedSkins()).map((installed) => installed.name), <String>['Old Name']);
    expect(Directory(old.directory).existsSync(), isTrue);
    expect(Directory(stagingPath()).listSync(), isEmpty);
    expect(native.named('forgetSkin'), isEmpty);
  });

  test('deleting a skin makes the native store forget it first', () async {
    final skin = (await importFiles(<String, List<int>>{'info.json': infoJson()}) as LibretroSkinImported).skin;
    await service.select(console: 'gba', orientation: 'landscape', skinId: skin.id);
    await service.delete(skin.id);

    final forget = native.named('forgetSkin').single;
    expect(forget.arguments, <String, Object?>{
      'directory': path.join(root.path, 'Config', 'Frontend'),
      'skinId': skin.id,
      'skinDirectory': skin.directory,
      'cacheDirectory': path.join(root.path, 'Caches'),
    });
    expect(native.skinDirectoryPresentAtForget, <bool>[true]);
    expect(Directory(skin.directory).existsSync(), isFalse);
    expect(await service.installedSkins(), isEmpty);
    expect(await service.selectedSkins('gba'), <String, String?>{'portrait': null, 'landscape': null});
    final outside = await Directory(path.join(root.path, 'Config')).create(recursive: true);
    await expectLater(service.delete(LibretroSkinService.defaultSkinId), throwsArgumentError);
    await expectLater(service.delete('../Config'), throwsArgumentError);
    expect(outside.existsSync(), isTrue);
    expect(native.named('forgetSkin'), hasLength(1));
  });

  test('selections are stored per console and orientation through the native store', () async {
    expect(await service.select(console: 'nds', orientation: 'portrait', skinId: 'default'), isTrue);
    final call = native.named('setFrontendSetting').single;
    expect(call.arguments, <String, Object?>{
      'directory': path.join(root.path, 'Config', 'Frontend'),
      'console': 'nds',
      'game': null,
      'key': 'skin.portrait',
      'value': 'default',
    });
    await service.select(console: 'nds', orientation: 'landscape', skinId: '0123456789abcdef');
    expect(await service.selectedSkins('nds'),
        <String, String?>{'portrait': 'default', 'landscape': '0123456789abcdef'});
    expect(await service.resetToDefault(console: 'nds'), isTrue);
    expect(native.named('setFrontendSetting').skip(2).map((update) => update.arguments['value']),
        <Object?>[null, null]);
    expect(await service.selectedSkins('nds'), <String, String?>{'portrait': null, 'landscape': null});
    expect(() => service.select(console: 'nds', orientation: 'sideways', skinId: 'default'), throwsArgumentError);
    expect(() => service.select(console: 'nds', orientation: 'portrait', skinId: 'A.B'), throwsArgumentError);
  });

  test('every native skin code has a translated message', () {
    final header = File('packages/libretro_internal_bridge/ios/Classes/LibretroSkin.h').readAsStringSync();
    final declared = RegExp(r'//\s*(SKIN_[A-Z_]+)').allMatches(header).map((match) => match.group(1)!).toSet();
    expect(declared, LibretroSkinMessages.codeKeys.keys.toSet());
    expect(LibretroSkinMessages.errorKeys.keys.toSet().intersection(LibretroSkinMessages.warningKeys.keys.toSet()),
        isEmpty);
    for (final source in Directory('packages/libretro_internal_bridge/ios/Classes')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.m'))) {
      for (final match in RegExp(r'@"(SKIN_[A-Z_]+)"').allMatches(source.readAsStringSync())) {
        expect(LibretroSkinMessages.codeKeys.containsKey(match.group(1)), isTrue,
            reason: '${path.basename(source.path)}: ${match.group(1)}');
      }
    }
    final keys = <String>{...LibretroSkinMessages.codeKeys.values}
      ..addAll(const <String>[
        LibretroSkinMessages.notArchive,
        LibretroSkinMessages.tooLarge,
        LibretroSkinMessages.unsafe,
        LibretroSkinMessages.corrupt,
        LibretroSkinMessages.tooManyFiles,
        LibretroSkinMessages.expandedTooLarge,
        LibretroSkinMessages.imageTooLarge,
        LibretroSkinMessages.download,
        LibretroSkinMessages.notDirect,
        LibretroSkinMessages.importFailed,
      ]);
    for (final key in keys) {
      expect(english.containsKey(key), isTrue, reason: key);
    }
  });
}
