import 'dart:io';

import 'package:path/path.dart' as path;

/// Resolves the public ROM storage layout used by Manic EMU on iOS.
///
/// Manic EMU keeps ordinary imported games in a flat `Documents/Datas`
/// directory. Nintendo 3DS CIA titles are installed separately under its
/// public `Documents/3DS` tree. NeoStation's regular scanner already handles
/// the latter; this service exposes the flat `Datas` directory as an
/// additional scan target.
class ManicEmuLibraryService {
  ManicEmuLibraryService._();

  static const Set<String> nintendo3dsExtensions = {
    '3ds',
    '3dsx',
    'cia',
    'app',
    'axf',
    'cci',
    'cxi',
    'elf',
    'zcci',
    'zcxi',
  };

  /// Accepts either Manic EMU's Documents root or the `Datas` directory
  /// itself, since both are reasonable choices in the iOS folder picker.
  static Future<String?> resolveDataFolder(String? linkedPath) async {
    final value = linkedPath?.trim();
    if (value == null || value.isEmpty) return null;

    final selected = Directory(value);
    if (path.basename(value).toLowerCase() == 'datas' &&
        await selected.exists()) {
      return value;
    }

    final child = Directory(path.join(value, 'Datas'));
    return await child.exists() ? child.path : null;
  }

  /// Returns whether a ROM represented by [romPath] is actually present in the
  /// linked Manic EMU library.
  ///
  /// A row originating from Manic itself is identified by folder ownership.
  /// For a row originating from RetroArch, compare the filename stem against
  /// Manic's public Documents/Datas folder. This also handles RetroArch ZIP
  /// containers because Manic imports/extracts the contained ROM using the same
  /// title stem before computing its launch identifier.
  static Future<bool> hasGameForRomPath(
    String? linkedPath,
    String romPath,
  ) async {
    final root = linkedPath?.trim();
    final rom = romPath.trim();
    if (root == null || root.isEmpty || rom.isEmpty) return false;

    final normalizedRoot = path.normalize(root);
    final normalizedRom = path.normalize(rom);
    if (path.equals(normalizedRoot, normalizedRom) ||
        path.isWithin(normalizedRoot, normalizedRom)) {
      return true;
    }

    final targetStem = path
        .basenameWithoutExtension(normalizedRom)
        .toLowerCase();
    if (targetStem.isEmpty) return false;

    final dataFolder = await resolveDataFolder(normalizedRoot);
    if (dataFolder != null) {
      try {
        await for (final entity in Directory(
          dataFolder,
        ).list(recursive: false, followLinks: false)) {
          if (entity is! File) continue;
          if (path.basenameWithoutExtension(entity.path).toLowerCase() ==
              targetStem) {
            return true;
          }
        }
      } catch (_) {
        // An unavailable security-scoped bookmark means the game cannot be
        // considered launchable from Manic for this session.
      }
    }

    // 3DS installs live outside Datas. Only inspect that tree for 3DS-family
    // extensions so ordinary ROM launches never pay for a recursive walk.
    final extension = path
        .extension(normalizedRom)
        .toLowerCase()
        .replaceFirst('.', '');
    if (!nintendo3dsExtensions.contains(extension)) return false;

    final documentsRoot = path.basename(normalizedRoot).toLowerCase() == 'datas'
        ? path.dirname(normalizedRoot)
        : normalizedRoot;
    final threeDsRoot = Directory(path.join(documentsRoot, '3DS'));
    if (!await threeDsRoot.exists()) return false;
    try {
      await for (final entity in threeDsRoot.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        if (path.basenameWithoutExtension(entity.path).toLowerCase() ==
            targetStem) {
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  static Future<bool> containsNintendo3dsGames(String dataFolder) async {
    final extensions = await extensionsInDataFolder(dataFolder);
    return extensions.any(nintendo3dsExtensions.contains);
  }

  /// Reads only directory entries and their extensions. It never opens ROM
  /// contents, computes hashes, or loads archives into memory, so linking a
  /// large Manic EMU library remains a cheap and bounded operation.
  static Future<Set<String>> extensionsInDataFolder(String dataFolder) async {
    final extensions = <String>{};
    try {
      await for (final entity in Directory(
        dataFolder,
      ).list(recursive: false, followLinks: false)) {
        if (entity is! File) continue;
        final extension = path
            .extension(entity.path)
            .toLowerCase()
            .replaceFirst('.', '');
        if (extension.isNotEmpty) extensions.add(extension);
      }
    } catch (_) {
      return const {};
    }
    return extensions;
  }
}
