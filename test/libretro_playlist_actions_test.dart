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

  Future<void> pumpActions(WidgetTester tester, SystemModel system, {bool embedded = false}) async {
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
                onLibraryChanged: () async {},
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
}

Future<void> _nothing() async {}
