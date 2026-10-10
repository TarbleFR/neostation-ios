import 'dart:io';

import 'package:file_picker/file_picker.dart';
// The picker's platform interface is the only way to stand in for the Files
// sheet in a widget test.
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/libretro_locale.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/screens/libretro/libretro_library_actions.dart';
import 'package:neostation/services/libretro_core_catalog.dart';
import 'package:neostation/services/libretro_internal_service.dart';
import 'package:neostation/widgets/libretro_internal_playlist_actions.dart';

/// Files sheet that records what it was asked for and is then cancelled.
class _CancelledPicker extends FilePickerPlatform {
  final requests = <({FileType type, List<String>? extensions, bool multiple})>[];

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
    requests.add((type: type, extensions: allowedExtensions, multiple: allowMultiple));
    return null;
  }
}

/// The 3DS as the scanner copies it for its alias folder "n3ds"
/// (assets/systems/3ds.json: folders and extensions).
const SystemModel _n3ds = SystemModel(
  id: '3ds',
  folderName: 'n3ds',
  realName: 'Nintendo 3DS',
  iconImage: 'assets/images/systems/3ds-icon.webp',
  color: '#4DD0E1',
  folders: <String>['3ds', 'n3ds', 'Nintendo 3DS'],
  extensions: <String>['3ds', '3dsx', 'app', 'axf', 'cci', 'cxi', 'elf', 'zcci', 'zcxi'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final english = LibretroLocale.values['en']!;

  Future<void> pumpActions(
    WidgetTester tester,
    SystemModel system, {
    bool embedded = false,
    List<String> Function()? libraryFolders,
  }) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(600, 1200),
        builder: (context, child) => MaterialApp(
          locale: const Locale('en'),
          home: Scaffold(
            body: Center(
              child: LibretroInternalPlaylistActions(
                system: system,
                embedded: embedded,
                onLibraryChanged: (_) async {},
                libraryFolders: libraryFolders,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('libretro-internal-import-menu')));
    await tester.pumpAndSettle();
  }

  testWidgets('an alias-folder playlist imports and opens skins as its bound system', (tester) async {
    final picker = _CancelledPicker();
    final original = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);

    // The folder name alone is not bound; the canonical key is.
    expect(LibretroCoreCatalog.bindingFor(_n3ds.folderName), isNull);
    const actions = LibretroInternalPlaylistActions(system: _n3ds, onLibraryChanged: _nothing);
    expect(actions.systemFolder, '3ds');
    expect(actions.systemFolder, LibretroInternalService.systemKey(_n3ds));

    await pumpActions(tester, _n3ds);
    await openMenu(tester);
    expect(find.text(english['importGames']!), findsOneWidget);
    expect(find.text(english['importRetroArch']!), findsOneWidget);
    // The 3DS skins, although the folder is "n3ds".
    expect(find.text(english['skins']!), findsOneWidget);

    await tester.tap(find.text(english['importGames']!));
    await tester.pumpAndSettle();

    // The picker offers the 3DS formats the core opens and the scanner
    // indexes, not the bare '.zip' an unbound folder would get.
    final request = picker.requests.single;
    expect(request.type, FileType.custom);
    expect(request.multiple, isTrue);
    expect(request.extensions, <String>['3ds', '3dsx', 'app', 'axf', 'cci', 'cxi', 'elf', 'zcci', 'zcxi']);
    expect(request.extensions, LibretroCoreCatalog.importExtensionsFor('3ds', indexed: _n3ds.extensions).toList()..sort());
    // A cancelled sheet imports nothing and announces nothing.
    expect(find.byType(SnackBar), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('the tab action of a playlist the engine does not run has no Skins item', (tester) async {
    const other = SystemModel(
      id: 'pico8',
      folderName: 'pico8',
      realName: 'PICO-8',
      iconImage: 'assets/images/systems/pico8-icon.webp',
      color: '#000000',
    );
    await pumpActions(tester, other, embedded: true);
    await openMenu(tester);
    expect(find.text(english['importGames']!), findsOneWidget);
    expect(find.text(english['skins']!), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('outside iOS the playlist shows no embedded-engine action', (tester) async {
    await pumpActions(tester, _n3ds);
    expect(find.byKey(const ValueKey('libretro-internal-import-menu')), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  group('the library the games go to', () {
    late Directory temporary;
    late _CancelledPicker picker;
    late FilePickerPlatform original;

    setUp(() {
      temporary = Directory.systemTemp.createTempSync('libretro-libraries-');
      picker = _CancelledPicker();
      original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
    });

    tearDown(() {
      FilePickerPlatform.instance = original;
      temporary.deleteSync(recursive: true);
    });

    Future<void> importGames(WidgetTester tester, List<String> folders) async {
      await pumpActions(tester, _n3ds, libraryFolders: () => folders);
      await openMenu(tester);
      await tester.tap(find.text(english['importGames']!));
      // The menu runs its action once it has closed; the library folders are
      // then checked on the real file system.
      for (var step = 0; step < 12; step++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('with several libraries the user chooses one, then the Files sheet opens', (tester) async {
      final mine = Directory('${temporary.path}/Ma bibliothèque')..createSync();
      Directory('${mine.path}/Nintendo 3DS').createSync();
      final roms = Directory('${temporary.path}/roms')..createSync();
      await importGames(tester, [mine.path, roms.path, '${temporary.path}/gone']);

      expect(find.text(english['importLibraryTitle']!), findsOneWidget);
      expect(find.text('Ma bibliothèque'), findsOneWidget);
      expect(find.text('roms'), findsOneWidget);
      expect(find.byKey(const ValueKey('libretro-import-library-2')), findsNothing,
          reason: 'a folder this device cannot open is not offered');
      expect(picker.requests, isEmpty, reason: 'nothing is picked before the library is chosen');

      await tester.tap(find.byKey(const ValueKey('libretro-import-library-0')));
      await tester.pumpAndSettle();
      expect(picker.requests, hasLength(1));
      expect(find.byType(SnackBar), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('backing out of the choice imports nothing', (tester) async {
      final first = Directory('${temporary.path}/A')..createSync();
      final second = Directory('${temporary.path}/B')..createSync();
      await importGames(tester, [first.path, second.path]);
      expect(find.text(english['importLibraryTitle']!), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(picker.requests, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('a single library is used without asking', (tester) async {
      final only = Directory('${temporary.path}/Jeux')..createSync();
      await importGames(tester, [only.path]);
      expect(find.text(english['importLibraryTitle']!), findsNothing);
      expect(picker.requests, hasLength(1));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('no second library is created when the registered ones cannot be opened', (tester) async {
      await importGames(tester, ['${temporary.path}/old container/roms']);
      expect(picker.requests, isEmpty);
      expect(find.text(english['importLibraryUnavailable']!), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  test('libraries are shown as Files shows them', () {
    expect(
      libretroLibraryLocation('/private/var/mobile/Containers/Data/Application/247E7CB5-3272-44D3-B641-9D41F3CBCB69/Documents/roms/3ds'),
      'roms › 3ds',
    );
    expect(libretroLibraryLocation('/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Jeux/Nintendo 3DS'),
        'com~apple~CloudDocs › Jeux › Nintendo 3DS');
  });
}

Future<void> _nothing(LibretroImportResult _) async {}
