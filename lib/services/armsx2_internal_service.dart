import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'armsx2_folder_service.dart';
import 'config_service.dart';

class Armsx2ImportResult {
  const Armsx2ImportResult({
    required this.imported,
    required this.rejected,
    this.errors = const <String>[],
  });

  final int imported;
  final int rejected;
  final List<String> errors;
}

/// Files-app-visible storage and import surface for NeoStation's embedded
/// ARMSX2 engine. This is the canonical PS2 storage root on iOS.
class Armsx2InternalService {
  Armsx2InternalService._();

  static Future<Directory> rootDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory(path.join(documents.path, 'ARMSX2'));
  }

  static Future<Directory> gamesDirectory() async {
    final root = await rootDirectory();
    return Directory(path.join(root.path, 'Games'));
  }

  static Future<Directory> biosDirectory() async {
    final root = await rootDirectory();
    return Directory(path.join(root.path, 'BIOS'));
  }

  static Future<Directory> savesDirectory() async {
    final root = await rootDirectory();
    return Directory(path.join(root.path, 'Saves'));
  }

  static Future<void> ensureLayout() async {
    final root = await rootDirectory();
    final games = Directory(path.join(root.path, 'Games'));
    final bios = Directory(path.join(root.path, 'BIOS'));
    final saves = Directory(path.join(root.path, 'Saves'));

    for (final directory in <Directory>[
      root,
      games,
      bios,
      saves,
      Directory(path.join(saves.path, 'Memory Cards')),
      Directory(path.join(saves.path, 'Savestates')),
    ]) {
      await directory.create(recursive: true);
    }

    // Keep the existing scanner/launcher ownership boundary but point it at
    // NeoStation's own Files-visible ARMSX2 root.
    ConfigService.linkedArmsx2FolderPath = root.path;
    ConfigService.linkedArmsx2GameFolderPath = games.path;
  }

  static Set<String> get supportedGameExtensions =>
      Armsx2FolderService.ps2GameExtensions
          .map((extension) => extension.replaceFirst('.', '').toLowerCase())
          .toSet();

  static Future<Armsx2ImportResult> importGames() async {
    await ensureLayout();
    final extensions = supportedGameExtensions.toList()..sort();
    final selection = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: extensions,
      withData: false,
      lockParentWindow: true,
    );
    if (selection == null) {
      return const Armsx2ImportResult(imported: 0, rejected: 0);
    }

    final destination = await gamesDirectory();
    return _copySelection(
      selection.files,
      destination,
      acceptedExtensions: supportedGameExtensions,
    );
  }

  static Future<Armsx2ImportResult> importBios() async {
    await ensureLayout();
    // BIOS dumps are encountered with several extensions (and occasionally
    // none). Let the Core's IsBIOS validation remain authoritative at launch.
    final selection = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.any,
      withData: false,
      lockParentWindow: true,
    );
    if (selection == null) {
      return const Armsx2ImportResult(imported: 0, rejected: 0);
    }
    return _copySelection(selection.files, await biosDirectory());
  }

  static Future<Armsx2ImportResult> _copySelection(
    List<PlatformFile> files,
    Directory destination, {
    Set<String>? acceptedExtensions,
  }) async {
    await destination.create(recursive: true);
    var imported = 0;
    var rejected = 0;
    final errors = <String>[];

    for (final picked in files) {
      final sourcePath = picked.path;
      final extension = path
          .extension(picked.name)
          .replaceFirst('.', '')
          .toLowerCase();
      if (sourcePath == null ||
          (acceptedExtensions != null &&
              !acceptedExtensions.contains(extension))) {
        rejected++;
        errors.add('${picked.name}: unsupported file.');
        continue;
      }

      final source = File(sourcePath);
      if (!await source.exists()) {
        rejected++;
        errors.add('${picked.name}: source file is not readable.');
        continue;
      }

      try {
        final output = await _uniqueDestination(destination, picked.name);
        await source.copy(output.path);
        final sourceLength = await source.length();
        final outputLength = await output.length();
        if (sourceLength <= 0 || sourceLength != outputLength) {
          if (await output.exists()) await output.delete();
          throw FileSystemException('Copied file length mismatch');
        }
        imported++;
      } catch (error) {
        rejected++;
        errors.add('${picked.name}: $error');
      }
    }

    return Armsx2ImportResult(
      imported: imported,
      rejected: rejected,
      errors: errors,
    );
  }

  static Future<File> _uniqueDestination(
    Directory directory,
    String originalName,
  ) async {
    final safeName = path.basename(originalName);
    var candidate = File(path.join(directory.path, safeName));
    if (!await candidate.exists()) return candidate;

    final stem = path.basenameWithoutExtension(safeName);
    final extension = path.extension(safeName);
    for (var index = 2; index < 10000; index++) {
      candidate = File(path.join(directory.path, '$stem ($index)$extension'));
      if (!await candidate.exists()) return candidate;
    }
    throw FileSystemException('No free destination name for $safeName');
  }
}
