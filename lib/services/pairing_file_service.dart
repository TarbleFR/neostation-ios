import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

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
    try {
      final file = await storedFile();
      if (!await file.exists()) return false;
      return inspectData(await file.readAsBytes()) ==
          PairingFileValidation.validRemotePairing;
    } catch (_) {
      return false;
    }
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
    _requireCompatiblePairingFile(bytes);

    final target = await storedFile();
    final directory = target.parent;
    final temporary = File(path.join(directory.path, 'pairing.import.tmp'));
    final backup = File(path.join(directory.path, 'pairing.backup.tmp'));

    if (await temporary.exists()) await temporary.delete();
    if (await backup.exists()) await backup.delete();

    await temporary.writeAsBytes(bytes, flush: true);
    if (!await temporary.exists()) {
      throw const PairingFileException(PairingFileError.invalidFile);
    }
    try {
      _requireCompatiblePairingFile(await temporary.readAsBytes());
    } on PairingFileException {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
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

  static void _requireCompatiblePairingFile(List<int> bytes) {
    switch (inspectData(bytes)) {
      case PairingFileValidation.validRemotePairing:
        return;
      case PairingFileValidation.missingRemotePairingCredentials:
        throw const PairingFileException(
          PairingFileError.remotePairingRequired,
        );
      case PairingFileValidation.invalid:
        throw const PairingFileException(PairingFileError.invalidFile);
    }
  }

  /// Checks the exact credentials consumed by StikJIT's
  /// `rp_pairing_file_read`, rather than treating file size as validity.
  static PairingFileValidation inspectData(List<int> bytes) {
    if (bytes.length < _minimumPairingBytes ||
        bytes.length > _maximumPairingBytes) {
      return PairingFileValidation.invalid;
    }

    const binaryMagic = <int>[0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30];
    if (_startsWith(bytes, binaryMagic)) {
      return _containsAscii(bytes, 'identifier') &&
              _containsAscii(bytes, 'public_key') &&
              _containsAscii(bytes, 'private_key')
          ? PairingFileValidation.validRemotePairing
          : PairingFileValidation.missingRemotePairingCredentials;
    }

    try {
      final document = XmlDocument.parse(utf8.decode(bytes));
      final plist = document.rootElement;
      if (plist.name.local != 'plist') return PairingFileValidation.invalid;
      final dictionary = plist.childElements
          .where((element) => element.name.local == 'dict')
          .firstOrNull;
      if (dictionary == null) return PairingFileValidation.invalid;

      final entries = <String, XmlElement>{};
      final elements = dictionary.childElements.toList(growable: false);
      if (elements.length.isOdd) return PairingFileValidation.invalid;
      for (var index = 0; index + 1 < elements.length; index += 2) {
        final key = elements[index];
        if (key.name.local != 'key') return PairingFileValidation.invalid;
        entries[key.innerText.trim()] = elements[index + 1];
      }

      final identifier = entries['identifier'];
      final publicKey = entries['public_key'];
      final privateKey = entries['private_key'];
      if (identifier == null || publicKey == null || privateKey == null) {
        return PairingFileValidation.missingRemotePairingCredentials;
      }
      if (identifier.name.local != 'string' ||
          identifier.innerText.trim().isEmpty ||
          !_isThirtyTwoByteData(publicKey) ||
          !_isThirtyTwoByteData(privateKey)) {
        return PairingFileValidation.invalid;
      }
      return PairingFileValidation.validRemotePairing;
    } catch (_) {
      return PairingFileValidation.invalid;
    }
  }

  static bool _isThirtyTwoByteData(XmlElement element) {
    if (element.name.local != 'data') return false;
    try {
      final compact = element.innerText.replaceAll(RegExp(r'\s+'), '');
      return base64Decode(compact).length == 32;
    } on FormatException {
      return false;
    }
  }

  static bool _startsWith(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index++) {
      if (bytes[index] != prefix[index]) return false;
    }
    return true;
  }

  static bool _containsAscii(List<int> bytes, String value) {
    final pattern = ascii.encode(value);
    if (bytes.length < pattern.length) return false;
    for (var start = 0; start <= bytes.length - pattern.length; start++) {
      var matches = true;
      for (var offset = 0; offset < pattern.length; offset++) {
        if (bytes[start + offset] != pattern[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
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

enum PairingFileValidation {
  validRemotePairing,
  missingRemotePairingCredentials,
  invalid,
}

enum PairingFileError {
  invalidExtension,
  invalidFile,
  remotePairingRequired,
  unreadable,
}

class PairingFileException implements Exception {
  const PairingFileException(this.error);

  final PairingFileError error;

  @override
  String toString() => 'PairingFileException(${error.name})';
}
