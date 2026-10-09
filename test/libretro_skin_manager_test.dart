import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:file_picker/file_picker.dart';
// The picker's platform interface is the only way to stand in for the Files
// sheet in a widget test.
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/l10n/libretro_locale.dart';
import 'package:neostation/screens/libretro/libretro_skin_catalog_screen.dart';
import 'package:neostation/screens/libretro/libretro_skin_manager_screen.dart';
import 'package:neostation/services/libretro_skin_catalog_service.dart';
import 'package:neostation/services/libretro_skin_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

const _bridge = MethodChannel('neostation/libretro_internal');
const _gamepads = MethodChannel('xyz.luan/gamepads');

/// Delta-style skin archive whose info.json declares [gameType].
List<int> _skinArchive(String name, String gameType) => ZipEncoder().encodeBytes(Archive()
  ..add(ArchiveFile.bytes(
    'info.json',
    utf8.encode(jsonEncode(<String, Object?>{
      'name': name,
      'identifier': 'com.example.${name.toLowerCase().replaceAll(' ', '')}',
      'gameTypeIdentifier': gameType,
      'representations': <String, Object?>{},
    })),
  )));

/// Files sheet returning [picked] (null: cancelled).
class _FilesSheet extends FilePickerPlatform {
  String? picked;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
    AndroidSAFOptions? androidSafOptions,
  }) async {
    final file = picked;
    if (file == null) return null;
    return FilePickerResult(<PlatformFile>[
      PlatformFile(path: file, name: path.basename(file), size: File(file).lengthSync()),
    ]);
  }
}

/// Native side of the bridge as the skin manager uses it: the frontend store
/// keeps its values in memory, previews are unavailable (null), and
/// forgetSkin drops the selections naming the skin. The skin parser maps the
/// last part of the declared gameTypeIdentifier to a console, like
/// +[LibretroSkin consolesForGameTypeIdentifier:] ("...delta.game.gba" is
/// "gba").
class _FakeNative {
  final calls = <MethodCall>[];
  final console = <String, Object?>{};

  Iterable<MethodCall> named(String method) => calls.where((call) => call.method == method);

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final arguments = (call.arguments as Map).cast<String, Object?>();
    switch (call.method) {
      case 'inspectSkin':
        final directory = arguments['directory'] as String;
        final info = jsonDecode(File(path.join(directory, 'info.json')).readAsStringSync()) as Map;
        final type = info['gameTypeIdentifier'] as String;
        return <String, Object?>{
          'ok': true,
          'summary': <String, Object?>{
            'identifier': info['identifier'],
            'name': info['name'],
            'consoles': <String>[type.split('.').last],
            'gameTypeIdentifier': type,
            'orientations': <String, Object?>{
              'iphone': <String>['portrait', 'landscape'],
              'ipad': <String>['portrait', 'landscape'],
            },
            'warnings': <String>[],
          },
        };
      case 'frontendSettings':
        return <String, Object?>{'console': Map<String, Object?>.of(console), 'games': <String, Object?>{}};
      case 'setFrontendSetting':
        final key = arguments['key'] as String;
        final value = arguments['value'];
        if (value == null) {
          console.remove(key);
        } else {
          console[key] = value;
        }
        return true;
      case 'forgetSkin':
        console.removeWhere((key, value) => value == arguments['skinId']);
        return null;
      case 'skinPreview':
        return null;
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final english = LibretroLocale.values['en']!;
  late Directory root;
  late _FakeNative native;
  late LibretroSkinService service;

  String en(String key, [Map<String, Object?> values = const <String, Object?>{}]) =>
      LibretroLocale.format(const Locale('en'), key, values);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = Directory.systemTemp.createTempSync('libretro_skin_manager_test');
    native = _FakeNative();
    service = LibretroSkinService(
      skinsDirectory: path.join(root.path, 'Skins'),
      frontendDirectory: path.join(root.path, 'Frontend'),
      cacheDirectory: path.join(root.path, 'Cache'),
    );
    messenger.setMockMethodCallHandler(_bridge, native.handle);
    // GamepadNavigation.initialize() lists the controllers: none here.
    messenger.setMockMethodCallHandler(_gamepads, (call) async => <dynamic>[]);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_bridge, null);
    messenger.setMockMethodCallHandler(_gamepads, null);
    root.deleteSync(recursive: true);
  });

  /// Writes an installed skin the way LibretroSkinService._install does.
  void installSkin({
    required String id,
    required String name,
    List<String> consoles = const <String>['3ds'],
    Map<String, List<String>> orientations = const <String, List<String>>{
      'iphone': <String>['portrait', 'landscape'],
      'ipad': <String>['portrait', 'landscape'],
    },
    List<String> warnings = const <String>[],
    String? license,
  }) {
    final directory = Directory(path.join(root.path, 'Skins', id))..createSync(recursive: true);
    final skin = LibretroInstalledSkin(
      id: id,
      identifier: 'com.example.$id',
      name: name,
      consoles: consoles,
      orientations: orientations,
      warnings: warnings,
      source: LibretroSkinService.sourceFile,
      license: license,
      sha256: id.padRight(64, '0'),
      importedAt: DateTime.utc(2026, 10, 9),
      directory: directory.path,
    );
    File(path.join(directory.path, LibretroSkinService.metadataFileName))
        .writeAsStringSync(jsonEncode(skin.toJson()));
  }

  /// The manager reads the skins folder with real file I/O: each step needs
  /// real time (runAsync) and then a pump to run its continuation in the
  /// fake async zone of testWidgets. Stops once [until] is found and the
  /// manager is idle again.
  Future<void> settle(WidgetTester tester, Finder until, {int rounds = 200}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
      if (until.evaluate().isNotEmpty && find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        // A few more rounds let the reads still running (previews) finish.
        for (var extra = 0; extra < 5; extra++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump();
        }
        return;
      }
    }
    fail('Timed out waiting for $until');
  }

  Future<void> pumpManager(WidgetTester tester, {String console = '3ds'}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(600, 1200),
        builder: (context, child) => MaterialApp(
          locale: const Locale('en'),
          home: LibretroSkinManagerScreen(console: console, service: service),
        ),
      ),
    );
    // The footer appears once the skins and the selections are read.
    await settle(tester, find.text(english['skinsLicenseNotice']!));
  }

  testWidgets('a console without imported skin shows the default skin and both choices', (tester) async {
    await pumpManager(tester);

    expect(find.text(en('skinsTitle', {'console': 'Nintendo 3DS'})), findsOneWidget);
    expect(find.text(en('skinsSelectedPortrait', {'name': english['skinDefaultName']})), findsOneWidget);
    expect(find.text(en('skinsSelectedLandscape', {'name': english['skinDefaultName']})), findsOneWidget);
    // The default skin card (its name), and no installed-skins section.
    expect(find.text(english['skinDefaultName']!), findsOneWidget);
    expect(find.text(english['skinsInstalled']!), findsNothing);
    expect(find.text(english['skinsImportFromFiles']!), findsOneWidget);
    expect(find.text(english['skinsBrowseCatalog']!), findsOneWidget);
    expect(find.text(english['skinsResetDefault']!), findsOneWidget);
    expect(find.text(english['skinsDelete']!), findsNothing);
    expect(find.text(english['skinsLicenseNotice']!), findsOneWidget);
    // Both orientations are selected on the default skin.
    expect(find.text(english['orientationPortrait']!), findsOneWidget);
    expect(find.text(english['orientationLandscape']!), findsOneWidget);

    // Selections come from the native frontend store of this console; the
    // previews of the default skin are asked for both orientations.
    expect(native.named('frontendSettings').single.arguments['console'], '3ds');
    final previews = native.named('skinPreview').toList();
    expect(previews.map((call) => call.arguments['orientation']).toSet(), {'portrait', 'landscape'});
    for (final call in previews) {
      expect(call.arguments['skinDirectory'], isNull);
      expect(call.arguments['console'], '3ds');
    }
    // A missing preview leaves a placeholder, not an endless spinner.
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNWidgets(2));
  });

  testWidgets('an installed skin shows its credits and remarks and can be chosen for one orientation',
      (tester) async {
    installSkin(
      id: '0123456789abcdef',
      name: 'Clear 3DS',
      consoles: const <String>['3ds', 'nds'],
      warnings: const <String>['SKIN_WARN_DEBUG_MISSING', 'SKIN_WARN_NOT_A_CODE'],
      license: 'CC BY 4.0',
    );
    installSkin(id: 'fedcba9876543210', name: 'Other console', consoles: const <String>['gba']);
    await pumpManager(tester);

    expect(find.text(english['skinsInstalled']!), findsOneWidget);
    expect(find.text('Clear 3DS'), findsOneWidget);
    expect(find.text('Other console'), findsNothing);
    expect(
      find.text(en('skinsCredits', {'author': english['skinsAuthorUnknown'], 'source': english['skinsSourceFiles']})),
      findsOneWidget,
    );
    expect(find.text(en('skinsLicense', {'license': 'CC BY 4.0'})), findsOneWidget);
    expect(find.text(en('skinsForConsoles', {'consoles': 'Nintendo 3DS, Nintendo DS'})), findsOneWidget);
    // Known remark translated; unknown codes are not shown raw.
    expect(find.text(english['skinWarnDebugMissing']!), findsOneWidget);
    expect(find.textContaining('SKIN_WARN'), findsNothing);

    final useLandscape = find.text(english['skinsUseForLandscape']!).last;
    await tester.ensureVisible(useLandscape);
    await tester.tap(useLandscape);
    await settle(tester, find.text(en('skinsSelectedLandscape', {'name': 'Clear 3DS'})));

    final stored = native.named('setFrontendSetting').single.arguments as Map;
    expect(stored['console'], '3ds');
    expect(stored['game'], isNull);
    expect(stored['key'], 'skin.landscape');
    expect(stored['value'], '0123456789abcdef');
    expect(find.text(en('skinsSelectedLandscape', {'name': 'Clear 3DS'})), findsOneWidget);
    expect(find.text(en('skinsSelectedPortrait', {'name': english['skinDefaultName']})), findsOneWidget);
  });

  testWidgets('deleting a skin asks first, then forgets it natively and removes its folder', (tester) async {
    installSkin(id: '0123456789abcdef', name: 'Clear 3DS');
    native.console['skin.portrait'] = '0123456789abcdef';
    await pumpManager(tester);
    expect(find.text(en('skinsSelectedPortrait', {'name': 'Clear 3DS'})), findsOneWidget);

    final delete = find.text(english['skinsDelete']!);
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(en('skinsDeleteConfirm', {'name': 'Clear 3DS'})), findsOneWidget);

    // Cancel keeps the skin.
    await tester.tap(find.text(english['cancel']!));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsNothing);
    expect(native.named('forgetSkin'), isEmpty);
    expect(Directory(path.join(root.path, 'Skins', '0123456789abcdef')).existsSync(), isTrue);

    await tester.ensureVisible(find.text(english['skinsDelete']!));
    await tester.tap(find.text(english['skinsDelete']!));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The dialog's confirm button carries the same label as the card action.
    await tester.tap(find.text(english['skinsDelete']!).last);
    await settle(tester, find.text(en('skinsSelectedPortrait', {'name': english['skinDefaultName']})));

    final forget = native.named('forgetSkin').single.arguments as Map;
    expect(forget['skinId'], '0123456789abcdef');
    expect(Directory(path.join(root.path, 'Skins', '0123456789abcdef')).existsSync(), isFalse);
    expect(find.text('Clear 3DS'), findsNothing);
    expect(find.text(en('skinsSelectedPortrait', {'name': english['skinDefaultName']})), findsOneWidget);
  });

  testWidgets('arrow keys move the focus, Enter activates once and Backspace leaves the page', (tester) async {
    // Wide enough for both header buttons on one row with the test font.
    tester.view.physicalSize = const Size(1800, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(600, 1200),
        builder: (context, child) => MaterialApp(
          locale: const Locale('en'),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LibretroSkinManagerScreen(console: 'gba', service: service),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    // Navigation sounds use flutter_soloud (FFI), which has no test double:
    // keep them off for this test.
    SfxService().setEnabled(false);
    addTearDown(() => SfxService().setEnabled(true));
    await tester.tap(find.text('open'));
    await settle(tester, find.text(english['skinsLicenseNotice']!));

    bool focused(String label) {
      final node = FocusManager.instance.primaryFocus;
      var inside = false;
      find.text(label).evaluate().single.visitAncestorElements((ancestor) {
        inside = ancestor == node?.context;
        return !inside;
      });
      return inside;
    }

    // The page's navigation layer ignores input for a short grace period after
    // it is activated, and throttles repeated keys (real clock).
    Future<void> press(LogicalKeyboardKey key) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 220)));
      await tester.sendKeyEvent(key);
      await tester.pump();
    }

    await press(LogicalKeyboardKey.arrowDown);
    expect(focused(english['skinsImportFromFiles']!), isTrue);
    await press(LogicalKeyboardKey.arrowRight);
    expect(focused(english['skinsBrowseCatalog']!), isTrue);
    await press(LogicalKeyboardKey.arrowLeft);
    expect(focused(english['skinsImportFromFiles']!), isTrue);
    await press(LogicalKeyboardKey.arrowRight);

    // Enter opens the catalog exactly once: Flutter's own Enter activation is
    // switched off inside the page, only the navigation layer answers.
    await press(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LibretroSkinCatalogScreen), findsOneWidget);
    // flutter_test answers every HTTP request with 400: the catalog settles
    // on its translated failure state (no request left running).
    await settle(tester, find.text(english['catalogFailed']!));
    expect(find.text(english['catalogRetry']!), findsOneWidget);

    // Backspace closes the catalog, then the manager.
    await press(LogicalKeyboardKey.backspace);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LibretroSkinCatalogScreen), findsNothing);
    expect(find.byType(LibretroSkinManagerScreen), findsOneWidget);
    await settle(tester, find.text(english['skinsLicenseNotice']!));

    await press(LogicalKeyboardKey.backspace);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LibretroSkinManagerScreen), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  /// Catalog entry card holding [name].
  Finder catalogCard(String name) => find.ancestor(of: find.text(name), matching: find.byType(Card));

  testWidgets('a catalog skin declaring another console is announced as such and not marked installed',
      (tester) async {
    // The live catalog lists "Sega Game Gear" under the Game Gear, but its
    // info.json declares the GBA (com.rileytestut.delta.game.gba).
    const catalog = '''
{"skins": [
  {"id": "gg1", "name": "Sega Game Gear", "author": "someone", "systems": ["gamegear"],
   "downloadURL": "https://example.com/skins/SEGAgamegear.deltaskin"},
  {"id": "gg2", "name": "Clear Game Gear", "author": "someone else", "systems": ["gamegear"],
   "downloadURL": "https://example.com/skins/ClearGameGear.deltaskin"}
]}
''';
    final client = MockClient((request) async {
      final file = request.url.pathSegments.last;
      if (file == 'catalog.json') return http.Response(catalog, 200);
      if (file == 'SEGAgamegear.deltaskin') {
        return http.Response.bytes(_skinArchive('Sega Game Gear', 'com.rileytestut.delta.game.gba'), 200);
      }
      return http.Response.bytes(_skinArchive('Clear Game Gear', 'com.example.game.gg'), 200);
    });
    final catalogService = LibretroSkinCatalogService(
      cacheDirectory: path.join(root.path, 'Cache'),
      skins: service,
      client: client,
    );
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        home: LibretroSkinCatalogScreen(console: 'gg', skins: service, catalog: catalogService),
      ),
    );
    await settle(tester, find.text('Clear Game Gear'));
    expect(find.byIcon(Icons.check), findsNothing);

    final otherConsoles = en('skinInstalledForOtherConsoles', {'consoles': 'Game Boy Advance'});
    await tester.tap(find.descendant(of: catalogCard('Sega Game Gear'), matching: find.text(english['catalogInstall']!)));
    await settle(tester, find.text(otherConsoles), rounds: 1000);
    expect(find.text(en('skinsImported', {'name': 'Sega Game Gear'})), findsOneWidget);
    expect(find.descendant(of: catalogCard('Sega Game Gear'), matching: find.byIcon(Icons.check)), findsNothing);
    expect(find.descendant(of: catalogCard('Sega Game Gear'), matching: find.byIcon(Icons.download)), findsOneWidget);
    // Installed, and listed for the Game Boy Advance only.
    final forGba = await tester.runAsync(() => service.installedSkins(console: 'gba'));
    final forGameGear = await tester.runAsync(() => service.installedSkins(console: 'gg'));
    expect(forGba!.map((skin) => skin.name), <String>['Sega Game Gear']);
    expect(forGameGear, isEmpty);

    // A skin for this console is marked installed.
    await tester.tap(find.descendant(of: catalogCard('Clear Game Gear'), matching: find.text(english['catalogInstall']!)));
    await settle(
      tester,
      find.descendant(of: catalogCard('Clear Game Gear'), matching: find.byIcon(Icons.check)),
      rounds: 1000,
    );
    expect(find.descendant(of: catalogCard('Sega Game Gear'), matching: find.byIcon(Icons.check)), findsNothing);
    final installed = await tester.runAsync(() => service.installedSkins(console: 'gg'));
    expect(installed!.map((skin) => skin.name), <String>['Clear Game Gear']);
  });

  testWidgets('a skin imported from Files for another console is announced as such on this page', (tester) async {
    final sheet = _FilesSheet();
    final original = FilePickerPlatform.instance;
    FilePickerPlatform.instance = sheet;
    addTearDown(() => FilePickerPlatform.instance = original);
    final archive = File(path.join(root.path, 'Incoming', 'SEGAgamegear.deltaskin'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(_skinArchive('Sega Game Gear', 'com.rileytestut.delta.game.gba'));
    sheet.picked = archive.path;

    await pumpManager(tester, console: 'gg');
    await tester.tap(find.text(english['skinsImportFromFiles']!));
    final otherConsoles = en('skinInstalledForOtherConsoles', {'consoles': 'Game Boy Advance'});
    await settle(tester, find.text(otherConsoles), rounds: 1000);
    expect(find.text(en('skinsImported', {'name': 'Sega Game Gear'})), findsOneWidget);
    // Not listed on the Game Gear page.
    expect(find.text(english['skinsInstalled']!), findsNothing);
    expect(find.text('Sega Game Gear'), findsNothing);
  });
}
