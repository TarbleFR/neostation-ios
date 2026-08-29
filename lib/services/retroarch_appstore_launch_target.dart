/// Pure helpers for RetroArch App Store deep-link targets.
///
/// RetroArch's iOS shortcut handler first treats `retroarch://game/<value>`
/// as a playlist filename. Archive playlist entries are recorded as
/// `archive.zip#member.ext`, while `path_basename()` exposes only the member.
/// When a playlist/core is still set to DETECT, launching that member name can
/// enter the playlist branch without a usable concrete core. Passing the
/// playlist's archive *container* path instead makes RetroArch use its fallback
/// content path, validate the ZIP and inspect its members for compatible cores.
class RetroArchAppStoreLaunchTarget {
  RetroArchAppStoreLaunchTarget._();

  static const Set<String> archiveExtensions = <String>{
    '.zip',
    '.7z',
    '.zst',
    '.apk',
  };

  /// Returns `(physical container/path, RetroArch playlist filename)`.
  ///
  /// For an archive entry such as `game.zip#game.32x`, RetroArch's
  /// `path_basename()` semantics expose `game.32x` as the playlist filename.
  static (String, String)? mappingFromPlaylistPath(String value) {
    if (value.isEmpty) return null;
    final normalized = value.replaceAll('\\', '/');
    final archiveHash = archiveDelimiterIndex(normalized);

    if (archiveHash >= 0 && archiveHash < normalized.length - 1) {
      final container = normalized.substring(0, archiveHash);
      final member = normalized.substring(archiveHash + 1);
      if (container.isEmpty || member.isEmpty) return null;
      return (container, member);
    }

    final slash = normalized.lastIndexOf('/');
    final filename = slash >= 0 ? normalized.substring(slash + 1) : normalized;
    if (filename.isEmpty) return null;
    return (normalized, filename);
  }

  /// Mirrors RetroArch's archive delimiter rule: `#` is an archive delimiter
  /// only when the preceding container ends in a supported archive extension.
  static int archiveDelimiterIndex(String value) {
    var searchFrom = 0;
    while (true) {
      final hash = value.indexOf('#', searchFrom);
      if (hash < 0) return -1;
      final before = value.substring(0, hash).toLowerCase();
      if (archiveExtensions.any(before.endsWith)) return hash;
      searchFrom = hash + 1;
    }
  }

  /// Returns RetroArch's own archive container path, preserving it byte-for-
  /// byte apart from slash normalization. In particular, spaces, accents and
  /// a literal trailing space in a directory name must not be trimmed.
  static String? archiveContainerPath(String? playlistPath) {
    if (playlistPath == null || playlistPath.isEmpty) return null;
    final normalized = playlistPath.replaceAll('\\', '/');
    final archiveHash = archiveDelimiterIndex(normalized);
    if (archiveHash <= 0) return null;
    final container = normalized.substring(0, archiveHash);
    return container.isEmpty ? null : container;
  }

  /// Selects the argument sent after `retroarch://game/`.
  ///
  /// Non-archive entries keep the exact playlist filename behavior. Archive
  /// entries deliberately use the container path so RetroArch bypasses a
  /// possibly unresolved playlist DETECT core and enters automatic archive
  /// core detection using a filesystem path that actually exists.
  static String select({
    required String launchId,
    String? fullPlaylistPath,
  }) {
    return archiveContainerPath(fullPlaylistPath) ?? launchId;
  }

  /// Builds the iOS URL without manual string concatenation or double encoding.
  /// Slashes, spaces, accents, apostrophes and other reserved characters inside
  /// the target are encoded as one URL path segment, then decoded by NSURL.path
  /// in RetroArch's iOS handler.
  static Uri buildUri(String launchTarget) {
    return Uri(
      scheme: 'retroarch',
      host: 'game',
      pathSegments: <String>[launchTarget],
    );
  }
}
