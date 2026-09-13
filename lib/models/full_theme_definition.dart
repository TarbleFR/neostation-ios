import 'dart:io';

import 'package:path/path.dart' as p;

/// Runtime description of an imported EmulationStation-style full theme.
///
/// Full themes are intentionally separate from NeoStation's color ThemeData.
/// When present they own the systems home and game playlists as one coherent
/// experience; the legacy grid/carousel preferences are not consulted.
class FullThemeDefinition {
  const FullThemeDefinition({
    required this.id,
    required this.name,
    required this.rootPath,
    required this.formatVersion,
    required this.engine,
    this.author,
    this.license,
    this.backgroundPath,
    this.musicPath,
    this.regularFontPath,
    this.boldFontPath,
    this.accentHex = '565296',
  });

  final String id;
  final String name;
  final String rootPath;
  final int formatVersion;
  final String engine;
  final String? author;
  final String? license;
  final String? backgroundPath;
  final String? musicPath;
  final String? regularFontPath;
  final String? boldFontPath;
  final String accentHex;

  bool get isArcadePlanet =>
      name.toLowerCase().contains('arcade planet') ||
      id.toLowerCase().contains('arcadeplanet');

  String? resolve(String? relativeOrAbsolute) {
    if (relativeOrAbsolute == null || relativeOrAbsolute.trim().isEmpty) {
      return null;
    }
    final raw = relativeOrAbsolute.trim();
    final candidate = p.isAbsolute(raw)
        ? File(raw)
        : File(
            p.normalize(
              p.join(rootPath, raw.replaceFirst(RegExp(r'^\./'), '')),
            ),
          );
    return candidate.existsSync() ? candidate.path : null;
  }

  String? firstExisting(Iterable<String> candidates) {
    for (final candidate in candidates) {
      final resolved = resolve(candidate);
      if (resolved != null) return resolved;
    }
    return null;
  }

  /// Returns a raster logo shipped by the imported theme when one exists.
  ///
  /// Arcade Planet often ships an SVG ColorLogo but also has PNG wheel assets.
  /// NeoStation prefers the ColorLogo and transparently falls back to the wheel
  /// so the full theme remains useful without introducing an SVG dependency.
  String? rasterSystemLogo(String folderName) {
    final key = folderName.toLowerCase();
    return firstExisting([
      '_art/Colorlogos/$key.webp',
      '_art/Colorlogos/$key.png',
      '_art/Colorlogos/$key.jpg',
      '_art/Colorlogos/US/$key.webp',
      '_art/Colorlogos/US/$key.png',
      '_art/wheel/$key.png',
      '_art/wheel/US/$key.png',
      '_art/wheelv/$key.png',
      '_art/wheelv/US/$key.png',
    ]);
  }

  /// Small horizontal-system-carousel logo used by Arcade Planet's 16:9 view.
  String? carouselSystemLogo(String folderName) {
    final key = folderName.toLowerCase();
    return firstExisting([
      '_art/wheel/$key.png',
      '_art/wheel/US/$key.png',
      '_art/Colorlogos/$key.png',
      '_art/Colorlogos/US/$key.png',
    ]);
  }

  /// System-specific foreground artwork used by Arcade Planet.
  String? systemSprite(String folderName, {int layer = 1}) {
    final key = folderName.toLowerCase();
    final directory = layer <= 1 ? 'sprites' : 'sprites$layer';
    return firstExisting([
      '_art/$directory/$key.png',
      '_art/$directory/US/$key.png',
      '_art/$directory/$key.webp',
    ]);
  }

  String? systemController(String folderName) {
    final key = folderName.toLowerCase();
    return firstExisting([
      '_art/controllers/$key.png',
      '_art/controllers/US/$key.png',
      '_art/controllers/$key.webp',
    ]);
  }

  /// Static layers defined by Arcade Planet's `_art/systemview/169H.xml`.
  String? get arcadePlanetLandscapeBackground => firstExisting(const [
    '_art/backgrounds/169/bghlandscape.png',
    '_art/backgrounds/169/bghlandscape.webp',
  ]);

  String? get arcadePlanetGlowBackground => firstExisting(const [
    '_art/backgrounds/169/bgh2.png',
    '_art/backgrounds/169/bgh2.webp',
  ]);

  String? get arcadePlanetForegroundBackground => firstExisting(const [
    '_art/backgrounds/169/bgh3.png',
    '_art/backgrounds/169/bgh3.webp',
  ]);

  String? systemBackdrop(String folderName) {
    final key = folderName.toLowerCase();
    return firstExisting([
      '_art/backgrounds/$key.webp',
      '_art/backgrounds/$key.png',
      '_art/backgrounds/$key.jpg',
      '_art/backgrounds/$key.jpeg',
      if (isArcadePlanet) '_art/backgrounds/169/bghlandscape.png',
      backgroundPath ?? '',
      '_art/backgrounds/bgsky.jpg',
      '_art/backgrounds/bgsky.png',
    ]);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'rootPath': rootPath,
    'formatVersion': formatVersion,
    'engine': engine,
    'author': author,
    'license': license,
    'backgroundPath': backgroundPath,
    'musicPath': musicPath,
    'regularFontPath': regularFontPath,
    'boldFontPath': boldFontPath,
    'accentHex': accentHex,
  };

  factory FullThemeDefinition.fromJson(Map<String, dynamic> json) {
    return FullThemeDefinition(
      id: json['id'] as String,
      name: json['name'] as String,
      rootPath: json['rootPath'] as String,
      formatVersion: (json['formatVersion'] as num?)?.toInt() ?? 7,
      engine: json['engine'] as String? ?? 'emulationstation',
      author: json['author'] as String?,
      license: json['license'] as String?,
      backgroundPath: json['backgroundPath'] as String?,
      musicPath: json['musicPath'] as String?,
      regularFontPath: json['regularFontPath'] as String?,
      boldFontPath: json['boldFontPath'] as String?,
      accentHex: json['accentHex'] as String? ?? '565296',
    );
  }
}
