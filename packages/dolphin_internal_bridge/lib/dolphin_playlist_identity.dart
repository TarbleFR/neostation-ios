/// Identifies the built-in engine in the per-game settings UI.
///
/// These aliases come from the existing gc/wii system definitions. This is
/// presentation-only: it does not rewrite playlist names, stored overrides,
/// file associations, or the native launch service's strict gc/wii contract.
abstract final class DolphinPlaylistIdentity {
  static const Map<String, String> _systems = {
    'gc': 'gc',
    'gamecube': 'gc',
    'nintendo gamecube': 'gc',
    'ngc': 'gc',
    'wii': 'wii',
    'nintendo wii': 'wii',
  };

  /// Returns the canonical GameCube/Wii identity, or null for any other system.
  /// In All/Favorites, only the game's own system determines its identity.
  static String? forGameSettings({
    required String systemFolderName,
    required bool isAllMode,
    String? gameSystemFolderName,
  }) {
    final folderName = isAllMode
        ? gameSystemFolderName
        : systemFolderName;
    if (folderName == null) return null;
    return _systems[folderName.trim().toLowerCase()];
  }
}
