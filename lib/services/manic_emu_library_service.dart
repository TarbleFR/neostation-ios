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
      await for (final entity in Directory(dataFolder).list(
        recursive: false,
        followLinks: false,
      )) {
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
