import 'dart:io';

import 'package:path/path.dart' as path;

/// Filesystem-only resolver for the ARMSX2 iOS container.
///
/// ARMSX2 owns one security-scoped root bookmark. The PS2 library and native
/// save directories are derived from that root without consulting RetroArch,
/// MeloNX, RPCS3, or any other emulator.
class Armsx2FolderService {
  Armsx2FolderService._();

  static const String bookmarkKey = 'armsx2';
  static const String legacySaveBookmarkKey = 'armsx2-save-folder';

  static const List<String> gameDirectoryNames = <String>[
    'iso',
    'isos',
    'games',
    'roms',
  ];

  static const List<String> saveDirectoryNames = <String>[
    'memcards',
    'sstates',
    'savestates',
  ];

  static const Set<String> ps2GameExtensions = <String>{
    '.iso',
    '.chd',
    '.gz',
    '.mdf',
    '.bin',
    '.ciso',
    '.img',
    '.cso',
    '.elf',
    '.isz',
  };

  static const Set<String> _knownRootChildren = <String>{
    'iso',
    'isos',
    'games',
    'roms',
    'memcards',
    'sstates',
    'savestates',
  };

  static const Set<String> _ignoredGameFolders = <String>{
    'memcards',
    'sstates',
    'savestates',
    'bios',
    'cache',
    'caches',
    'cheats',
    'config',
    'covers',
    'logs',
    'screenshots',
    'textures',
  };

  /// Promotes old direct links (`iso`, `memcards`, `sstates`, etc.) back to the
  /// ARMSX2 root. Otherwise it walks upward until an ARMSX2-like layout exists.
  static Future<String> resolveRoot(String linkedPath, {int maxParents = 6}) async {
    final original = path.normalize(linkedPath.trim());
    if (original.isEmpty) return linkedPath;

    var current = Directory(original);
    final selectedName = path.basename(current.path).toLowerCase();
    if (_knownRootChildren.contains(selectedName)) {
      current = current.parent;
    }

    for (var depth = 0; depth <= maxParents; depth++) {
      if (await _looksLikeRoot(current)) return path.normalize(current.path);
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }

    if (_knownRootChildren.contains(selectedName)) {
      return path.normalize(Directory(original).parent.path);
    }
    return original;
  }

  static Future<bool> _looksLikeRoot(Directory directory) async {
    if (!await directory.exists()) return false;
    try {
      final names = await directory
          .list(recursive: false, followLinks: false)
          .where((entry) => entry is Directory)
          .map((entry) => path.basename(entry.path).toLowerCase())
          .toSet();
      return names.any(_knownRootChildren.contains);
    } on FileSystemException {
      return false;
    }
  }

  /// Returns the physical PS2 library below the ARMSX2 root.
  ///
  /// Named folders win (`iso`, `isos`, `games`, `roms`). Otherwise a custom
  /// library is selected when it contains supported PS2 images in its own
  /// subdirectories. Save/config folders are never candidates.
  static Future<String?> resolveGameDirectory(
    String rootPath, {
    int maxDepth = 3,
  }) async {
    final normalizedRoot = path.normalize(rootPath.trim());
    if (normalizedRoot.isEmpty) return null;
    final root = Directory(normalizedRoot);
    if (!await root.exists()) return null;

    for (final name in gameDirectoryNames) {
      final direct = Directory(path.join(normalizedRoot, name));
      if (await direct.exists()) return path.normalize(direct.path);
    }

    _GameCandidate? best;

    Future<int> countImages(Directory directory, int remainingDepth) async {
      var count = 0;
      List<FileSystemEntity> entries;
      try {
        entries = await directory
            .list(recursive: false, followLinks: false)
            .toList();
      } on FileSystemException {
        return 0;
      }
      for (final entry in entries) {
        if (entry is File) {
          if (ps2GameExtensions.contains(path.extension(entry.path).toLowerCase())) {
            count++;
          }
        } else if (entry is Directory && remainingDepth > 0) {
          final name = path.basename(entry.path).toLowerCase();
          if (_ignoredGameFolders.contains(name)) continue;
          count += await countImages(entry, remainingDepth - 1);
        }
      }
      return count;
    }

    Future<void> inspect(Directory directory, int depth) async {
      if (depth > maxDepth) return;
      final name = path.basename(directory.path).toLowerCase();
      if (depth > 0 && _ignoredGameFolders.contains(name)) return;

      final count = await countImages(directory, maxDepth - depth);
      if (count > 0) {
        final candidate = _GameCandidate(
          directory: path.normalize(directory.path),
          depth: depth,
          fileCount: count,
        );
        if (best == null || candidate.isBetterThan(best!)) best = candidate;
      }

      if (depth >= maxDepth) return;
      List<Directory> children;
      try {
        children = await directory
            .list(recursive: false, followLinks: false)
            .where((entry) => entry is Directory)
            .cast<Directory>()
            .toList();
      } on FileSystemException {
        return;
      }
      for (final child in children) {
        await inspect(child, depth + 1);
      }
    }

    await inspect(root, 0);
    return best?.directory;
  }

  /// Returns only ARMSX2 save folders below the ARMSX2 root.
  static Future<List<String>> resolveSaveDirectories(String rootPath) async {
    final normalizedRoot = path.normalize(rootPath.trim());
    if (normalizedRoot.isEmpty) return const <String>[];
    final result = <String>[];
    for (final name in saveDirectoryNames) {
      final candidate = Directory(path.join(normalizedRoot, name));
      if (await candidate.exists()) result.add(path.normalize(candidate.path));
    }
    return result;
  }

  /// True only when [romPath] belongs to ARMSX2's own linked root (or is an
  /// ARMSX2 virtual launch URL). This is the ownership boundary used by both
  /// game launching and iCloud Saves routing.
  static bool ownsRomPath(String? romPath, String? rootPath) {
    if (romPath == null || romPath.trim().isEmpty) return false;
    final uri = Uri.tryParse(romPath);
    if (uri != null && uri.scheme.toLowerCase() == 'armsx2') return true;
    if (rootPath == null || rootPath.trim().isEmpty) return false;

    final root = path.normalize(rootPath);
    final rom = path.normalize(romPath);
    return path.equals(root, rom) || path.isWithin(root, rom);
  }
}

class _GameCandidate {
  const _GameCandidate({
    required this.directory,
    required this.depth,
    required this.fileCount,
  });

  final String directory;
  final int depth;
  final int fileCount;

  bool isBetterThan(_GameCandidate other) {
    if (fileCount != other.fileCount) return fileCount > other.fileCount;
    // Prefer a real child library over the app root, then the shallowest child.
    if (depth == 0 && other.depth > 0) return false;
    if (depth > 0 && other.depth == 0) return true;
    return depth < other.depth;
  }
}
