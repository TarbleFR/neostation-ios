import 'package:path/path.dart' as path;

/// Product names for native Ports entries, separate from source-game metadata.
class PortsDisplayTitle {
  PortsDisplayTitle._();

  static const kartPad = 'Mario Kart Pad';
  static const kartPadSourceGame = 'Mario Kart Wii';

  /// Resolves old/imported/scraped rows at read time without changing their
  /// filename, source disc identity, metadata, or native launch/save paths.
  static String? forLibraryEntry({
    required String? systemFolderName,
    required String gamePath,
  }) {
    if (systemFolderName?.toLowerCase() != 'ports') return null;
    final parts = path.posix.split(path.posix.normalize(gamePath));
    for (var i = 0; i + 3 < parts.length; i++) {
      if (parts[i] == 'Ports' &&
          parts[i + 1] == 'KartPad' &&
          parts[i + 2] == 'Games') {
        return kartPad;
      }
    }
    return null;
  }
}
