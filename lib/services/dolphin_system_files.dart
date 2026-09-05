import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Only extracted Dolphin Wii data belongs here. A raw encrypted nand.bin
/// cannot be installed by renaming it or treating it as a GameCube IPL.
class DolphinSystemFilesException implements Exception {
  final String code;
  const DolphinSystemFilesException(this.code);
  @override
  String toString() => code;
}

abstract final class DolphinSystemFiles {
  static const wiiFiles = {
    'clientca.pem', 'clientcakey.pem', 'rootca.pem', 'keys.bin', 'fst.bin',
  };
  static const wiiDirectories = {
    'import', 'meta', 'shared1', 'shared2', 'sys', 'ticket', 'title', 'tmp', 'wfs',
  };

  /// A Wii keys file is not a System Menu installation. Check the bounded
  /// metadata for the installed menu before requesting JIT. The
  /// native ES/TMD reader then checks the actual installed contents at launch.
  static Future<void> requireWiiMenuMetadata(Directory nand) async {
    const systemMenuId = 0x0000000100000002;
    final menu = await _readInstalledTmd(nand, systemMenuId);
    if (menu == null) {
      throw const DolphinSystemFilesException('wiiMenuMissing');
    }
    final iosId = menu.getUint64(0x184, Endian.big);
    // Dolphin supplies Wii IOS in HLE. Requiring a second installed IOS TMD
    // would incorrectly reject a usable menu extracted from the user's NAND.
    if ((iosId >> 32) != 1 || (iosId & 0xffffffff) <= 2) {
      throw const DolphinSystemFilesException('wiiMenuMissing');
    }
  }

  static Future<ByteData?> _readInstalledTmd(Directory nand, int titleId) async {
    final title = titleId.toRadixString(16).padLeft(16, '0');
    var current = nand.path;
    final components = ['title', title.substring(0, 8), title.substring(8),
      'content', 'title.tmd'];
    try {
      if (await FileSystemEntity.type(current, followLinks: false) !=
          FileSystemEntityType.directory) return null;
      for (var index = 0; index < components.length; index++) {
        current = p.join(current, components[index]);
        final expected = index == components.length - 1
            ? FileSystemEntityType.file : FileSystemEntityType.directory;
        if (await FileSystemEntity.type(current, followLinks: false) != expected) return null;
      }
      final file = File(current);
      final length = await file.length();
      // These limits and offsets match Dolphin's IOS::ES::TMDHeader.
      if (length < 0x1e4 || length > 0x49e4) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length != length) return null;
      final data = ByteData.sublistView(bytes);
      final count = data.getUint16(0x1de, Endian.big);
      if (data.getUint64(0x18c, Endian.big) != titleId || count == 0 ||
          0x1e4 + count * 36 > length) return null;
      final bootIndex = data.getUint16(0x1e0, Endian.big);
      for (var index = 0; index < count; index++) {
        if (data.getUint16(0x1e4 + index * 36 + 4, Endian.big) == bootIndex) return data;
      }
      return null;
    } on FileSystemException {
      return null;
    }
  }

  static Future<Directory> findWiiRoot(Directory selected) async {
    for (final suffix in ['', 'Wii', 'User/Wii', 'Dolphin/Wii', 'Dolphin/User/Wii']) {
      final candidate = Directory(p.join(selected.path, suffix));
      if (await Directory(p.join(candidate.path, 'title')).exists() &&
          (await Directory(p.join(candidate.path, 'shared2')).exists() ||
           await Directory(p.join(candidate.path, 'ticket')).exists() ||
           await Directory(p.join(candidate.path, 'sys')).exists())) {
        final selectedReal = await selected.resolveSymbolicLinks();
        final candidateReal = await candidate.resolveSymbolicLinks();
        if (candidateReal != selectedReal && !p.isWithin(selectedReal, candidateReal)) {
          throw const DolphinSystemFilesException('unsafePath');
        }
        return candidate;
      }
    }
    throw const DolphinSystemFilesException('invalidWii');
  }

  static Future<int> importWiiFolder(Directory selected, Directory target) async {
    final source = await findWiiRoot(selected);
    await _checkSeparate(source, target);
    return replaceSnapshot(target, (stage) async {
      var count = 0;
      await for (final entity in source.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (_isMetadata(name)) continue;
        if (!wiiFiles.contains(name) && !wiiDirectories.contains(name)) {
          throw const DolphinSystemFilesException('invalidWii');
        }
        final type = await FileSystemEntity.type(entity.path, followLinks: false);
        if ((wiiFiles.contains(name) && type != FileSystemEntityType.file) ||
            (wiiDirectories.contains(name) && type != FileSystemEntityType.directory)) {
          throw const DolphinSystemFilesException('unsafePath');
        }
        count += await copyTree(entity, p.join(stage.path, name));
      }
      if (count == 0) throw const DolphinSystemFilesException('invalidWii');
      return count;
    });
  }

  static Future<int> importWiiFiles(List<File> files, Directory target) async {
    if (files.isEmpty) return 0;
    if (files.any((file) => !wiiFiles.contains(p.basename(file.path)))) {
      throw const DolphinSystemFilesException('invalidWiiFile');
    }
    return replaceSnapshot(target, (stage) async {
      for (final file in files) {
        await copyTree(file, p.join(stage.path, p.basename(file.path)));
      }
      return files.length;
    }, merge: true);
  }

  /// Finish recovery before recreating layout directories. If the process died
  /// between the two renames, the old data is restored before the core starts.
  static Future<void> recover(Directory target) async {
    final backup = Directory('${target.path}.previous');
    final stage = Directory('${target.path}.incoming');
    if (!await target.exists() && await backup.exists()) {
      await backup.rename(target.path);
    }
    if (await stage.exists()) await stage.delete(recursive: true);
  }

  /// Build and verify a complete snapshot before touching live data. Older
  /// backups are retained, never silently overwritten by the next import.
  static Future<int> replaceSnapshot(
    Directory target,
    Future<int> Function(Directory stage) populate, {
    bool merge = false,
  }) async {
    await recover(target);
    await target.parent.create(recursive: true);
    final stage = Directory('${target.path}.incoming');
    final backup = Directory('${target.path}.previous');
    await stage.create();
    try {
      if (merge && await target.exists()) await copyTree(target, stage.path);
      final count = await populate(stage);
      if (await backup.exists()) {
        await backup.rename('${backup.path}-${DateTime.now().microsecondsSinceEpoch}');
      }
      if (await target.exists()) await target.rename(backup.path);
      try {
        await stage.rename(target.path);
      } catch (_) {
        if (!await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
      return count;
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  static Future<void> _checkSeparate(Directory source, Directory target) async {
    final sourcePath = await source.resolveSymbolicLinks();
    final targetPath = await target.exists()
        ? await target.resolveSymbolicLinks() : p.normalize(p.absolute(target.path));
    if (sourcePath == targetPath || p.isWithin(sourcePath, targetPath) ||
        p.isWithin(targetPath, sourcePath)) {
      throw const DolphinSystemFilesException('unsafePath');
    }
  }

  static bool _isMetadata(String name) =>
      name == '.DS_Store' || name.startsWith('._') || name == '__MACOSX';

  static Future<int> copyTree(FileSystemEntity source, String destination) async {
    final type = await FileSystemEntity.type(source.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(destination).create(recursive: true);
      var count = 0;
      await for (final child in Directory(source.path).list(followLinks: false)) {
        if (_isMetadata(p.basename(child.path))) continue;
        count += await copyTree(child, p.join(destination, p.basename(child.path)));
      }
      return count;
    }
    if (type != FileSystemEntityType.file) {
      throw const DolphinSystemFilesException('unsafePath');
    }
    final file = File(source.path);
    final before = await sha256.bind(file.openRead()).first;
    final output = File(destination);
    await output.parent.create(recursive: true);
    await file.copy(output.path);
    final after = await sha256.bind(output.openRead()).first;
    if (before != after) throw const DolphinSystemFilesException('copyFailed');
    return 1;
  }
}
