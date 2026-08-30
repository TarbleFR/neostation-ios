import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class PairingFileService {
  PairingFileService._();

  static const String _directoryName = 'StikJIT';
  static const String _storedFileName = 'pairing.mobiledevicepairing';
  static const int _minimumPairingBytes = 128;
  static const int _maximumPairingBytes = 5 * 1024 * 1024;

  static Future<Directory> _privateDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(path.join(support.path, _directoryName));
    await directory.create(recursive: true);
    return directory;
  }

  static Future<File> storedFile() async {
    final directory = await _privateDirectory();
    return File(path.join(directory.path, _storedFileName));
  }

  static Future<bool> hasStoredPairingFile() async {
    final file = await storedFile();
    if (!await file.exists()) return false;
    final length = await file.length();
    return length >= _minimumPairingBytes && length <= _maximumPairingBytes;
  }

  /// Opens the document picker and atomically imports/replaces the pairing file.
  ///
  /// The existing file is not removed until the newly selected file has passed
  /// basic validation and has been written successfully to a temporary file.
  static Future<PairingFileImportResult?> importFromPicker({
    String? dialogTitle,
  }) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      allowMultiple: false,
      type: FileType.any,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return null;

    final selected = picked.files.single;
    final lowerName = selected.name.toLowerCase();
    if (!lowerName.endsWith('.mobiledevicepairing') &&
        !lowerName.endsWith('.plist')) {
      throw const PairingFileException(PairingFileError.invalidExtension);
    }

    final bytes = await _readSelectedBytes(selected);
    if (!_isPlausiblePairingFile(bytes)) {
      throw const PairingFileException(PairingFileError.invalidFile);
    }

    final target = await storedFile();
    final directory = target.parent;
    final temporary = File(path.join(directory.path, 'pairing.import.tmp'));
    final backup = File(path.join(directory.path, 'pairing.backup.tmp'));

    if (await temporary.exists()) await temporary.delete();
    if (await backup.exists()) await backup.delete();

    await temporary.writeAsBytes(bytes, flush: true);
    if (!await temporary.exists() ||
        !_isPlausiblePairingFile(await temporary.readAsBytes())) {
      if (await temporary.exists()) await temporary.delete();
      throw const PairingFileException(PairingFileError.invalidFile);
    }

    final replacing = await target.exists();
    if (replacing) {
      await target.copy(backup.path);
    }

    try {
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);

      if (!await hasStoredPairingFile()) {
        throw const PairingFileException(PairingFileError.invalidFile);
      }

      if (await backup.exists()) await backup.delete();
      return PairingFileImportResult(file: target, replacedExisting: replacing);
    } catch (_) {
      if (await target.exists()) {
        try {
          await target.delete();
        } catch (_) {}
      }
      if (await backup.exists()) {
        try {
          await backup.rename(target.path);
        } catch (_) {}
      }
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  static Future<List<int>> _readSelectedBytes(PlatformFile selected) async {
    final sourcePath = selected.path;
    if (sourcePath != null) {
      final source = File(sourcePath);
      if (await source.exists()) {
        return source.readAsBytes();
      }
    }

    final bytes = selected.bytes;
    if (bytes != null) return bytes;

    throw const PairingFileException(PairingFileError.unreadable);
  }

  static bool _isPlausiblePairingFile(List<int> bytes) {
    return bytes.length >= _minimumPairingBytes &&
        bytes.length <= _maximumPairingBytes;
  }
}

class PairingFileImportResult {
  const PairingFileImportResult({
    required this.file,
    required this.replacedExisting,
  });

  final File file;
  final bool replacedExisting;
}

enum PairingFileError { invalidExtension, invalidFile, unreadable }

class PairingFileException implements Exception {
  const PairingFileException(this.error);

  final PairingFileError error;

  @override
  String toString() => 'PairingFileException(${error.name})';
}
