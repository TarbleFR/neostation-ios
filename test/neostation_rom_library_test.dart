import 'dart:io';

import 'package:file_picker/file_picker.dart';
// The picker's platform interface is the only way to stand in for the Files
// sheet in a test.
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/libretro_internal_service.dart';
import 'package:neostation/services/neostation_rom_library.dart';
import 'package:path/path.dart' as path;

/// Files sheet that returns the given files.
class _PickedFiles extends FilePickerPlatform {
  _PickedFiles(this.files);

  final List<String> files;

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
  }) async =>
      FilePickerResult([
        for (final file in files)
          PlatformFile(path: file, name: path.basename(file), size: File(file).lengthSync()),
      ]);
}

void main() {
  late Directory temporary;

  setUp(() => temporary = Directory.systemTemp.createTempSync('neostation-library-'));
  tearDown(() => temporary.deleteSync(recursive: true));

  File write(String relative, int length) {
    final file = File(path.join(temporary.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(length, 7));
    return file;
  }

  group('console folders', () {
    test('one folder per console of the embedded engine, named as the scanner knows them', () async {
      final roms = path.join(temporary.path, 'roms');
      final folders = NeoStationRomLibrary.consoleFolders();
      expect(folders, containsAll(<String>['3ds', 'psp', 'gba', 'ps1', 'ds', 'n64', 'nes', 'snes']));
      expect(await NeoStationRomLibrary.createConsoleFolders(roms), folders.length);
      for (final folder in folders) {
        expect(Directory(path.join(roms, folder)).existsSync(), isTrue, reason: folder);
      }
    });

    test('existing folders and their games are kept', () async {
      final roms = path.join(temporary.path, 'roms');
      final game = write('roms/3ds/Mario Kart 7.3ds', 64);
      final created = await NeoStationRomLibrary.createConsoleFolders(roms);
      expect(created, NeoStationRomLibrary.consoleFolders().length - 1);
      expect(game.lengthSync(), 64);
      expect(await NeoStationRomLibrary.createConsoleFolders(roms), 0);
    });
  });

  group('moving a library', () {
    test('console folders are moved into roms, keeping their place; other folders stay', () async {
      // Files keeps a trailing space in a folder name; Windows cannot.
      final library = Platform.isWindows ? 'Bibliothèque' : 'Bibliothèque ';
      final source = path.join(temporary.path, 'RetroArch', library);
      write('RetroArch/$library/Nintendo DS/Zelda.nds', 30);
      write('RetroArch/$library/psp/Jeux/Patapon.iso', 50);
      write('RetroArch/$library/BIOS/scph.bin', 10);
      write('RetroArch/$library/notes.txt', 3);
      final roms = path.join(temporary.path, 'NeoStation', 'roms');
      final progress = <int>[];

      final move = await NeoStationRomLibrary.moveLibrary(
        sourceRoot: source,
        romsRoot: roms,
        consoleFolderNames: {'nds', 'ds', 'Nintendo DS', 'psp'},
        onProgress: (done, total) => progress.add(done),
      );

      expect(move.moved, 2);
      expect(move.complete, isTrue);
      expect(File(path.join(roms, 'Nintendo DS', 'Zelda.nds')).lengthSync(), 30);
      expect(File(path.join(roms, 'psp', 'Jeux', 'Patapon.iso')).lengthSync(), 50);
      expect(File(path.join(source, 'Nintendo DS', 'Zelda.nds')).existsSync(), isFalse, reason: 'moved, not copied');
      expect(File(path.join(source, 'BIOS', 'scph.bin')).existsSync(), isTrue, reason: 'not a console folder');
      expect(File(path.join(source, 'notes.txt')).existsSync(), isTrue);
      expect(progress.last, 2);
    });

    test('a game already in roms stays in the source; another file of the same name gets a new name', () async {
      final source = path.join(temporary.path, 'Library');
      write('Library/3ds/Mario Kart 7.3ds', 64);
      write('Library/3ds/Pilotwings.3ds', 40);
      write('roms/3ds/Mario Kart 7.3ds', 64);
      write('roms/3ds/Pilotwings.3ds', 12);
      final roms = path.join(temporary.path, 'roms');

      final move = await NeoStationRomLibrary.moveLibrary(
        sourceRoot: source,
        romsRoot: roms,
        consoleFolderNames: {'3ds'},
      );

      expect(move.alreadyPresent, 1);
      expect(move.moved, 1);
      expect(File(path.join(source, '3ds', 'Mario Kart 7.3ds')).existsSync(), isTrue);
      expect(File(path.join(roms, '3ds', 'Pilotwings.3ds')).lengthSync(), 12);
      expect(File(path.join(roms, '3ds', 'Pilotwings (2).3ds')).lengthSync(), 40);
      expect(Directory(path.join(roms, '3ds')).listSync(), hasLength(3), reason: 'no "(2)" copy of Mario Kart');
    });

    test('files iCloud has not downloaded are reported as not moved', () async {
      final source = path.join(temporary.path, 'Library');
      write('Library/gba/.Metroid.gba.icloud', 1);
      write('Library/gba/Advance Wars.gba', 8);
      final move = await NeoStationRomLibrary.moveLibrary(
        sourceRoot: source,
        romsRoot: path.join(temporary.path, 'roms'),
        consoleFolderNames: {'gba'},
      );
      expect(move.moved, 1);
      expect(move.failed, 1);
      expect(move.complete, isFalse, reason: 'the source is still needed');
    });

    test('NeoStation\'s own library is never moved into itself', () async {
      final roms = path.join(temporary.path, 'roms');
      write('roms/3ds/Mario Kart 7.3ds', 64);
      for (final source in [roms, temporary.path, path.join(roms, '3ds')]) {
        final move = await NeoStationRomLibrary.moveLibrary(
          sourceRoot: source,
          romsRoot: roms,
          consoleFolderNames: {'3ds', 'roms'},
        );
        expect(move.total, 0, reason: source);
      }
      expect(File(path.join(roms, '3ds', 'Mario Kart 7.3ds')).existsSync(), isTrue);
    });
  });

  group('import into a library', () {
    test('the console folder of each library that opens, its alias folder kept', () async {
      Directory(path.join(temporary.path, 'Mine', 'Nintendo 3DS')).createSync(recursive: true);
      Directory(path.join(temporary.path, 'roms')).createSync();
      Directory(path.join(temporary.path, 'Only', '3ds')).createSync(recursive: true);
      final libraries = await LibretroInternalService.importLibraries(
        '3ds',
        registeredRoots: [
          path.join(temporary.path, 'Mine'),
          path.join(temporary.path, 'roms'),
          path.join(temporary.path, 'Mine'),
          path.join(temporary.path, 'gone'),
          path.join(temporary.path, 'Only', '3ds'),
          'content://com.android.externalstorage.documents/tree/primary%3AROMs',
        ],
        folderAliases: ['n3ds', 'Nintendo 3DS'],
      );
      expect(libraries.map((library) => library.directory), [
        path.join(temporary.path, 'Mine', 'Nintendo 3DS'),
        path.join(temporary.path, 'roms', '3ds'),
        path.join(temporary.path, 'Only', '3ds'),
      ]);
      expect(libraries.map((library) => library.name), ['Mine', 'roms', '3ds']);
    });

    test('a picked game already in the library is not copied again', () async {
      final library = LibretroImportLibrary(
        root: path.join(temporary.path, 'Mine'),
        directory: path.join(temporary.path, 'Mine', 'Nintendo 3DS'),
      );
      final mario = write('Downloads/Mario Kart 7.3ds', 64);
      final original = FilePickerPlatform.instance;
      addTearDown(() => FilePickerPlatform.instance = original);

      FilePickerPlatform.instance = _PickedFiles([mario.path]);
      final first = await LibretroInternalService.importGames('3ds', systemExtensions: ['3ds'], library: library);
      expect(first.imported, 1);
      expect(first.alreadyPresent, 0);
      expect(first.createdLibraryRoot, isNull, reason: 'the user\'s library, no second one');

      final second = await LibretroInternalService.importGames('3ds', systemExtensions: ['3ds'], library: library);
      expect(second.imported, 0);
      expect(second.alreadyPresent, 1);
      expect(Directory(library.directory).listSync(), hasLength(1), reason: 'no "(2)" copy');

      final other = write('Other/Mario Kart 7.3ds', 65);
      FilePickerPlatform.instance = _PickedFiles([other.path]);
      final third = await LibretroInternalService.importGames('3ds', systemExtensions: ['3ds'], library: library);
      expect(third.imported, 1);
      expect(File(path.join(library.directory, 'Mario Kart 7 (2).3ds')).lengthSync(), 65,
          reason: 'another file with the same name is kept apart');
    });
  });
}
