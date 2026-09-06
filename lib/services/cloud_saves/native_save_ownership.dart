import 'package:path/path.dart' as path;

/// Positive native ownership proofs for automatic per-game synchronization.
/// Display metadata and a recent mtime are never evidence of the game's owner.
abstract final class NativeSaveOwnership {
  static final _serial = RegExp(
    r'(?:^|[^A-Z0-9])((?:SL|SC|PB)[A-Z]{2})[-_. ]?(\d{3})[._ ]?(\d{2})(?=$|[^0-9])',
  );

  static Set<String> ps2Serials(String value) => _serial
      .allMatches(value.toUpperCase())
      .map((m) => '${m[1]}-${m[2]}${m[3]}').toSet();

  static String _name(String value) => value.trim().toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ');

  static bool ps2StateMatches(String nativePath, {
    required String romName, required String gameName, String? titleId,
  }) {
    final native = nativePath.replaceAll('\\', '/');
    final owners = ps2Serials(native);
    final expected = {...ps2Serials(titleId ?? ''), ...ps2Serials(romName)};
    // Contradictory or unknown serials cannot be rescued by a display title.
    if (owners.isNotEmpty) {
      return owners.length == 1 && expected.length == 1 &&
          owners.single == expected.single;
    }
    var leaf = path.posix.basename(native);
    leaf = leaf.replaceFirst(RegExp(
      r'\.(?:p2s|savestate|state|ss\d+|st\d+)(?:\.gz)?$', caseSensitive: false), '');
    // Native slot/CRC suffixes only, not fuzzy title substrings (Game 1 != Game 10).
    leaf = leaf.replaceFirst(RegExp(r'\.(?:\d{1,2}|auto|resume)$', caseSensitive: false), '');
    leaf = leaf.replaceFirst(RegExp(r'\s*\([0-9a-f]{8}\)$', caseSensitive: false), '');
    final names = {
      _name(path.posix.basenameWithoutExtension(romName.replaceAll('\\', '/'))),
      _name(gameName),
    }..remove('');
    return names.contains(_name(leaf));
  }

  static bool switchTitleMatches(String? expected, String actual) {
    final id = expected?.trim().toUpperCase() ?? '';
    final candidate = actual.trim().toUpperCase();
    return RegExp(r'^01[0-9A-F]{14}$').hasMatch(id) && id == candidate;
  }

  static bool switchCloudMatches(String nativePath, {
    required String? expectedTitleId, required String? legacyOwner,
    required Set<String> expectedNames,
  }) {
    final native = nativePath.replaceAll('\\', '/');
    if (native.toLowerCase().startsWith('profiles/')) {
      final match = RegExp(
        r'^profiles/[0-9a-f]{32}/(01[0-9a-f]{14})/[0-9a-f]{16}/.+$',
        caseSensitive: false,
      ).firstMatch(native);
      return match != null && switchTitleMatches(expectedTitleId, match[1]!);
    }
    // Historical objects without native title/profile metadata retain their
    // existing key. Never use an empty name or a substring as an ownership proof.
    final owner = _name(legacyOwner ?? '');
    return owner.isNotEmpty && expectedNames.map(_name).contains(owner);
  }
}
