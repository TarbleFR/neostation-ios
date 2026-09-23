import 'dart:io';

import 'package:dusklight_internal_bridge/dusklight_internal_bridge.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'dusklight_game_identity.dart';

class DusklightImportIssue {
  const DusklightImportIssue(this.fileName, this.messageKey, [this.details]);

  final String fileName;
  final String messageKey;
  final String? details;
}

class DusklightImportResult {
  const DusklightImportResult({
    required this.imported,
    required this.rejected,
    this.errors = const <DusklightImportIssue>[],
    this.importedPaths = const <String>[],
  });

  final int imported;
  final int rejected;
  final List<DusklightImportIssue> errors;
  final List<String> importedPaths;
}

class DusklightLaunchResult {
  const DusklightLaunchResult({
    required this.success,
    required this.message,
    this.stage,
    this.errorCode,
    this.technicalDetails = '',
  });

  final bool success;
  final String message;
  final String? stage;
  final String? errorCode;
  final String technicalDetails;
}

/// Files-visible library and native host boundary for NeoStation's Ports /
/// Dusklight integration.
class DusklightInternalService {
  DusklightInternalService._();

  static const Set<String> supportedGameExtensions = <String>{
    'iso',
    'gcm',
    'rvz',
    'wia',
    'wbfs',
    'ciso',
    'gcz',
  };

  static const Set<String> supportedDiscIds = <String>{
    'GZ2E01',
    'GZ2J01',
    'GZ2P01',
    'RZDE01',
    'RZDJ01',
    'RZDP01',
  };

  static Future<Directory> rootDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory(path.join(documents.path, 'Ports', 'Dusklight'));
  }

  static Future<Directory> gamesDirectory() async =>
      Directory(path.join((await rootDirectory()).path, 'Games'));

  static Future<Directory> savesDirectory() async =>
      Directory(path.join((await rootDirectory()).path, 'Saves'));

  static Future<Directory> configDirectory() async =>
      Directory(path.join((await rootDirectory()).path, 'Config'));

  static Future<Directory> modsDirectory() async =>
      Directory(path.join((await rootDirectory()).path, 'Mods'));

  static Future<void> ensureLayout() async {
    for (final directory in <Directory>[
      await rootDirectory(),
      await gamesDirectory(),
      await savesDirectory(),
      await configDirectory(),
      await modsDirectory(),
      Directory(path.join((await rootDirectory()).path, 'Metadata')),
    ]) {
      await directory.create(recursive: true);
    }
  }

  static Future<DusklightImportResult> importGames() async {
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
      return const DusklightImportResult(imported: 0, rejected: 0);
    }

    final destination = await gamesDirectory();
    var imported = 0;
    var rejected = 0;
    final errors = <DusklightImportIssue>[];
    final importedPaths = <String>[];
    for (final picked in selection.files) {
      final sourcePath = picked.path;
      final extension = path
          .extension(picked.name)
          .replaceFirst('.', '')
          .toLowerCase();
      if (sourcePath == null || !supportedGameExtensions.contains(extension)) {
        rejected++;
        errors.add(DusklightImportIssue(picked.name, 'formatUnsupported'));
        continue;
      }

      final source = File(sourcePath);
      if (!await source.exists() || await source.length() <= 0) {
        rejected++;
        errors.add(DusklightImportIssue(picked.name, 'gameUnreadable'));
        continue;
      }

      // Raw discs expose their six-byte product ID directly. Compressed
      // formats remain subject to Dusklight's authoritative native validator.
      if ((extension == 'iso' || extension == 'gcm') &&
          !await _hasSupportedRawDiscId(source)) {
        rejected++;
        errors.add(DusklightImportIssue(picked.name, 'unsupportedDisc'));
        continue;
      }

      File? temporary;
      try {
        // The embedded DiscIO reader also identifies compressed discs. Reject
        // another game before copying it or attaching Twilight Princess media.
        if (await DusklightGameIdentity.read(source.path) == null) {
          rejected++;
          errors.add(DusklightImportIssue(picked.name, 'unsupportedDisc'));
          continue;
        }
        final output = await _uniqueDestination(destination, picked.name);
        temporary = File('${output.path}.part');
        if (await temporary.exists()) await temporary.delete();
        await source.copy(temporary.path);
        if (await temporary.length() != await source.length()) {
          throw const FileSystemException('Copied file length mismatch');
        }
        await temporary.rename(output.path);
        importedPaths.add(output.path);
        imported++;
      } catch (error) {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
        rejected++;
        errors.add(DusklightImportIssue(picked.name, 'importFailed', '$error'));
      }
    }
    return DusklightImportResult(
      imported: imported,
      rejected: rejected,
      errors: errors,
      importedPaths: importedPaths,
    );
  }

  static Future<DusklightLaunchResult> launch(String gamePath, {
    Map<String, String> uiText = const {},
  }) async {
    await ensureLayout();
    final game = File(gamePath);
    if (!await game.exists() || await game.length() <= 0) {
      return const DusklightLaunchResult(
        success: false,
        message: 'The selected Dusklight game file is not readable.',
        stage: 'input',
        errorCode: 'DUSKLIGHT_GAME_UNREADABLE',
      );
    }
    final extension = path.extension(gamePath).replaceFirst('.', '').toLowerCase();
    if (!supportedGameExtensions.contains(extension)) {
      return const DusklightLaunchResult(
        success: false,
        message: 'This disc format is not supported by Dusklight.',
        stage: 'input',
        errorCode: 'DUSKLIGHT_FORMAT_UNSUPPORTED',
      );
    }

    final temporary = await getTemporaryDirectory();
    final response = await DusklightInternalBridge.launch(
      gamePath: game.path,
      supportPath: (await rootDirectory()).path,
      cachePath: path.join(temporary.path, 'Dusklight'),
      uiText: uiText,
    );
    final success = response['success'] == true;
    return DusklightLaunchResult(
      success: success,
      message: response['message']?.toString() ??
          (success
              ? 'Dusklight session started.'
              : 'The native bridge returned no launch detail.'),
      stage: response['stage']?.toString(),
      errorCode: response['errorCode']?.toString(),
      technicalDetails: <String>[
        if (response['buildNumber'] != null) 'Build: ${response['buildNumber']}',
        if (response['corePath'] != null) 'Core: ${response['corePath']}',
      ].join('\n'),
    );
  }

  static Future<bool> _hasSupportedRawDiscId(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final bytes = await handle.read(6);
      if (bytes.length != 6) return false;
      final id = String.fromCharCodes(bytes).toUpperCase();
      return supportedDiscIds.contains(id);
    } catch (_) {
      return false;
    } finally {
      await handle?.close();
    }
  }

  static Future<File> _uniqueDestination(
    Directory directory,
    String originalName,
  ) async {
    await directory.create(recursive: true);
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
