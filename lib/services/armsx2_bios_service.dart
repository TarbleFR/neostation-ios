import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import 'armsx2_internal_service.dart';

class Armsx2BiosFile {
  const Armsx2BiosFile(this.filename, this.bytes);
  final String filename;
  final int bytes;
}

/// The selected filename is relative to the owned BIOS directory, so an iOS
/// container relocation cannot silently select a different firmware. IsBIOS in
/// the native core remains the authoritative firmware validation.
class Armsx2BiosStore {
  Armsx2BiosStore(this.directory, this.preferences);

  static const preferenceKey = 'armsx2.selectedBiosFilename.v1';
  final Directory directory;
  final SharedPreferences preferences;

  static Future<Armsx2BiosStore> open() async => Armsx2BiosStore(
        await Armsx2InternalService.biosDirectory(),
        await SharedPreferences.getInstance(),
      );

  String? get selectedFilename => preferences.getString(preferenceKey);

  static bool isCandidate(String filename) {
    if (filename.isEmpty || filename.startsWith('.') ||
        filename.contains('/') || filename.contains('\\') ||
        filename.contains('\u0000') || path.basename(filename) != filename) {
      return false;
    }
    // NVRAM, companion ROMs and settings are not selectable boot firmware.
    return !const {'.nvm', '.mec', '.rom1', '.rom2', '.erom', '.json', '.ini', '.txt'}
        .contains(path.extension(filename).toLowerCase());
  }

  Future<List<Armsx2BiosFile>> list() async {
    if (!await directory.exists()) return const [];
    final result = <Armsx2BiosFile>[];
    await for (final entity in directory.list(followLinks: false)) {
      final filename = path.basename(entity.path);
      if (!isCandidate(filename) ||
          await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file) {
        continue;
      }
      final size = await File(entity.path).length();
      if (size > 0) result.add(Armsx2BiosFile(filename, size));
    }
    result.sort((a, b) => a.filename.toLowerCase().compareTo(b.filename.toLowerCase()));
    return result;
  }

  Future<String> validate(String filename) async {
    if (!isCandidate(filename)) {
      throw const FormatException('Invalid PS2 BIOS filename.');
    }
    final file = File(path.join(directory.path, filename));
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('Selected BIOS is missing; choose a BIOS again.', filename);
    }
    final handle = await file.open();
    try {
      if (await handle.length() == 0) {
        throw FileSystemException('Selected BIOS is empty.', filename);
      }
      await handle.read(1); // Detect an unreadable file before attaching JIT.
    } finally {
      await handle.close();
    }
    return filename;
  }

  Future<void> select(String filename) async {
    await validate(filename);
    if (!await preferences.setString(preferenceKey, filename)) {
      throw StateError('Could not save the selected PS2 BIOS.');
    }
  }

  Future<String?> resolve() async {
    final filename = selectedFilename;
    if (filename == null) return null; // Never guess the first alphabetical BIOS.
    return validate(filename); // A missing selection must not fall back to Japan.
  }
}
