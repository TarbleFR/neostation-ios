import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:neostation/services/logger_service.dart';

class IosRomLibraryRootResolver {
  IosRomLibraryRootResolver._();

  static final _log = LoggerService.instance;

  static const Set<String> _retroArchInfrastructureFolders = <String>{
    'assets',
    'autoconfig',
    'cheats',
    'config',
    'cores',
    'database',
    'filters',
    'logs',
    'overlays',
    'playlists',
    'saves',
    'screenshots',
    'shaders',
    'states',
    'system',
    'thumbnails',
  };

  static Future<String> resolveRetroArchScanRoot({
    required String linkedRoot,
    required Iterable<String> systemFolderNames,
    int maxDepth = 2,
  }) async {
    final rootPath = path.normalize(linkedRoot.trim());
    if (rootPath.isEmpty) return linkedRoot;

    final aliases = systemFolderNames
        .map((name) => name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet()
      ..removeAll(<String>{'all', 'android', 'favorites', 'recent'});

    if (aliases.isEmpty) return rootPath;

    final root = Directory(rootPath);
    if (!await root.exists()) return rootPath;

    _LibraryCandidate? best;
    final visited = <String>{};

    Future<void> inspect(Directory directory, int depth) async {
      if (depth > maxDepth) return;
      final normalizedPath = path.normalize(directory.path);
      if (!visited.add(normalizedPath)) return;

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

      final systemMatches = children.where((child) {
        return aliases.contains(path.basename(child.path).toLowerCase());
      }).length;

      if (systemMatches > 0) {
        final candidate = _LibraryCandidate(
          path: normalizedPath,
          matches: systemMatches,
          depth: depth,
        );
        final currentBest = best;
        if (currentBest == null || candidate.isBetterThan(currentBest)) {
          best = candidate;
        }
      }

      if (depth >= maxDepth) return;
      for (final child in children) {
        final name = path.basename(child.path).toLowerCase();
        if (_retroArchInfrastructureFolders.contains(name)) continue;
        if (aliases.contains(name)) continue;
        await inspect(child, depth + 1);
      }
    }

    await inspect(root, 0);
    final resolved = best?.path ?? rootPath;
    _log.i(
      'RetroArch folder resolver: linkedRoot=$rootPath scanRoot=$resolved '
      'matches=${best?.matches ?? 0}',
    );
    return resolved;
  }
}

class _LibraryCandidate {
  final String path;
  final int matches;
  final int depth;

  const _LibraryCandidate({
    required this.path,
    required this.matches,
    required this.depth,
  });

  bool isBetterThan(_LibraryCandidate other) {
    if (matches != other.matches) return matches > other.matches;
    return depth < other.depth;
  }
}
