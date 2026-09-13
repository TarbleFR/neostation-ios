import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import '../models/full_theme_definition.dart';
import 'config_service.dart';
import 'logger_service.dart';

/// Imports and owns NeoStation's single active "full theme".
///
/// A full theme is not another grid/carousel preference. Once installed it is
/// the presentation layer for the Systems home and every game playlist until it
/// is removed or replaced. The original NeoStation layouts stay intact as the
/// fallback when no full theme is installed.
class FullThemeService {
  FullThemeService._();

  static final FullThemeService instance = FullThemeService._();

  static const _activeThemePreference = 'neostation_full_theme_active_id';
  static const _directoryName = 'full_themes';
  static const _manifestFileName = 'neostation_full_theme.json';

  final LoggerService _log = LoggerService.instance;
  final ValueNotifier<FullThemeDefinition?> activeTheme = ValueNotifier(null);
  final ValueNotifier<bool> isReady = ValueNotifier(false);

  bool _initializing = false;
  bool _initialized = false;
  Future<void>? _initializationFuture;

  bool get hasActiveTheme => activeTheme.value != null;

  Future<Directory> _themesDirectory() async {
    final userDataPath = await ConfigService.getUserDataPath();
    final directory = Directory(p.join(userDataPath, _directoryName));
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> initialize() {
    if (_initialized) return Future.value();
    if (_initializationFuture != null) return _initializationFuture!;
    _initializationFuture = _initializeInternal();
    return _initializationFuture!;
  }

  Future<void> _initializeInternal() async {
    if (_initializing) return;
    _initializing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final activeId = prefs.getString(_activeThemePreference);
      if (activeId == null || activeId.trim().isEmpty) {
        activeTheme.value = null;
        return;
      }

      final base = await _themesDirectory();
      final themeDir = Directory(p.join(base.path, activeId));
      final manifest = File(p.join(themeDir.path, _manifestFileName));
      if (!await themeDir.exists() || !await manifest.exists()) {
        await prefs.remove(_activeThemePreference);
        activeTheme.value = null;
        return;
      }

      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid full-theme manifest');
      }

      final stored = FullThemeDefinition.fromJson(decoded);
      final definition = FullThemeDefinition(
        id: stored.id,
        name: stored.name,
        rootPath: themeDir.path,
        formatVersion: stored.formatVersion,
        engine: stored.engine,
        author: stored.author,
        license: stored.license,
        backgroundPath: stored.backgroundPath,
        musicPath: stored.musicPath,
        regularFontPath: stored.regularFontPath,
        boldFontPath: stored.boldFontPath,
        accentHex: stored.accentHex,
      );

      if (!File(p.join(definition.rootPath, 'theme.xml')).existsSync()) {
        throw const FormatException('theme.xml missing from installed full theme');
      }

      await _registerThemeFonts(definition);
      activeTheme.value = definition;
      _log.i('[FullTheme] Loaded ${definition.name}.');
    } catch (e, st) {
      _log.e(
        '[FullTheme] Could not load active full theme',
        error: e,
        stackTrace: st,
      );
      activeTheme.value = null;
    } finally {
      _initialized = true;
      _initializing = false;
      isReady.value = true;
    }
  }

  /// Imports a .zip containing an EmulationStation theme and makes it the only
  /// active full theme immediately. Existing full themes are removed only after
  /// the new package has fully extracted and validated.
  Future<FullThemeDefinition> importZip(File source) async {
    if (!await source.exists()) {
      throw FileSystemException('Full theme archive not found', source.path);
    }
    if (p.extension(source.path).toLowerCase() != '.zip') {
      throw const FormatException('A full theme must be supplied as a .zip file');
    }

    final base = await _themesDirectory();
    final staging = Directory(
      p.join(base.path, '.importing_${DateTime.now().microsecondsSinceEpoch}'),
    );
    await staging.create(recursive: true);

    try {
      // archive's disk extractor guards against paths escaping outputPath.
      await extractFileToDisk(source.path, staging.path);

      final themeXml = await _findThemeXml(staging);
      if (themeXml == null) {
        throw const FormatException(
          'No EmulationStation theme.xml found in archive',
        );
      }

      final parsed = await _parseTheme(themeXml);
      final id = _safeId(parsed.name);
      final destination = Directory(p.join(base.path, id));

      // theme.xml may sit inside a GitHub-style wrapper directory. Move the
      // actual theme root, not that arbitrary wrapper, into NeoStation storage.
      final extractedRoot = themeXml.parent;
      final prepared = Directory(p.join(base.path, '.prepared_$id'));
      if (await prepared.exists()) await prepared.delete(recursive: true);
      await _copyDirectory(extractedRoot, prepared);

      final installed = FullThemeDefinition(
        id: id,
        name: parsed.name,
        rootPath: destination.path,
        formatVersion: parsed.formatVersion,
        engine: parsed.engine,
        author: parsed.author,
        license: parsed.license,
        backgroundPath: parsed.backgroundPath,
        musicPath: parsed.musicPath,
        regularFontPath: parsed.regularFontPath,
        boldFontPath: parsed.boldFontPath,
        accentHex: parsed.accentHex,
      );

      // The user requested a single comfortable full-theme experience rather
      // than another selectable layout. Keep only the newly imported package.
      await _removeInstalledThemes(
        base,
        exceptPaths: {prepared.path, staging.path},
      );
      if (await destination.exists()) await destination.delete(recursive: true);
      await prepared.rename(destination.path);

      final manifest = File(p.join(destination.path, _manifestFileName));
      await manifest.writeAsString(
        const JsonEncoder.withIndent('  ').convert(installed.toJson()),
        flush: true,
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_activeThemePreference, id);
      await _registerThemeFonts(installed);
      activeTheme.value = installed;
      _initialized = true;
      isReady.value = true;
      _log.i('[FullTheme] Imported and activated ${installed.name}.');
      return installed;
    } finally {
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> removeActiveTheme() async {
    final base = await _themesDirectory();
    await _removeInstalledThemes(base);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeThemePreference);
    activeTheme.value = null;
    _initialized = true;
    isReady.value = true;
    _log.i('[FullTheme] Full theme removed; classic NeoStation UI restored.');
  }

  Future<File?> _findThemeXml(Directory root) async {
    File? fallback;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File ||
          p.basename(entity.path).toLowerCase() != 'theme.xml') {
        continue;
      }
      fallback ??= entity;
      try {
        final prefix = await entity
            .openRead(0, 4096)
            .transform(utf8.decoder)
            .join();
        if (prefix.contains('<formatVersion>') || prefix.contains('<theme')) {
          return entity;
        }
      } catch (_) {}
    }
    return fallback;
  }

  Future<FullThemeDefinition> _parseTheme(File themeXml) async {
    final raw = await themeXml.readAsString();
    final document = XmlDocument.parse(raw);
    final formatText = _firstElementText(document, 'formatVersion');
    final formatVersion = int.tryParse(formatText ?? '') ?? 0;
    if (formatVersion < 6) {
      throw FormatException(
        'Unsupported EmulationStation theme format $formatVersion',
      );
    }

    final commentName = RegExp(
      r'Theme\s*:\s*([^\r\n]+)',
      caseSensitive: false,
    ).firstMatch(raw)?.group(1)?.trim();
    final name = (commentName == null || commentName.isEmpty)
        ? p.basename(themeXml.parent.path)
        : commentName;

    final author = RegExp(
      r'author\s*:\s*([^\r\n]+)',
      caseSensitive: false,
    ).firstMatch(raw)?.group(1)?.trim();
    final license = RegExp(
      r'license\s*:\s*([^\r\n]+)',
      caseSensitive: false,
    ).firstMatch(raw)?.group(1)?.trim();

    String? background;
    String? music;
    String? regularFont;
    String? boldFont;
    var accent = '565296';

    for (final view in document.findAllElements('view')) {
      final viewName = view.getAttribute('name') ?? '';
      final viewNames = viewName.split(',').map((value) => value.trim()).toSet();
      if (viewNames.contains('system')) {
        for (final image in view.findAllElements('image')) {
          final imageName = image.getAttribute('name') ?? '';
          final path = image.getElement('path')?.innerText.trim();
          if (path != null &&
              path.isNotEmpty &&
              (imageName == 'bgsky' ||
                  imageName.toLowerCase().contains('background'))) {
            background ??= _normalizeThemePath(path);
          }
        }
        for (final sound in view.findAllElements('sound')) {
          final path = sound.getElement('path')?.innerText.trim();
          if (path != null && path.isNotEmpty) {
            music ??= _normalizeThemePath(path);
          }
        }
        final iconColor = view
            .findAllElements('iconColor')
            .firstOrNull
            ?.innerText
            .trim();
        if (iconColor != null && iconColor.isNotEmpty) accent = iconColor;
      }

      if (viewNames.contains('menu')) {
        for (final node in view.descendants.whereType<XmlElement>()) {
          final font = node.getElement('fontPath')?.innerText.trim();
          if (font == null || font.isEmpty) continue;
          final normalized = _normalizeThemePath(font);
          final nodeName = node.getAttribute('name')?.toLowerCase() ?? '';
          if (nodeName.contains('title') ||
              font.toLowerCase().contains('bold')) {
            boldFont ??= normalized;
          } else {
            regularFont ??= normalized;
          }
        }
      }
    }

    final root = themeXml.parent.path;
    background ??= _firstExistingRelative(root, const [
      '_art/backgrounds/bgsky.jpg',
      '_art/backgrounds/bgsky.png',
      '_art/backgrounds/background.jpg',
      '_art/backgrounds/background.png',
    ]);
    music ??= _firstExistingRelative(root, const [
      '_art/music/ArcadePlanetBGMusic.mp3',
      '_art/music/background.mp3',
    ]);
    regularFont ??= _firstExistingRelative(root, const [
      '_art/fonts/SairaCondensed-Regular.ttf',
      '_art/fonts/Saira_ExtraCondensed-Regular.ttf',
    ]);
    boldFont ??= _firstExistingRelative(root, const [
      '_art/fonts/SairaCondensed-Bold.ttf',
      '_art/fonts/SairaCondensed-SemiBold.ttf',
    ]);

    final cleanedAccent = accent.replaceAll('#', '').trim();
    final normalizedAccent = cleanedAccent.isEmpty
        ? '565296'
        : (cleanedAccent.length > 8
              ? cleanedAccent.substring(0, 8)
              : cleanedAccent);

    return FullThemeDefinition(
      id: _safeId(name),
      name: name,
      rootPath: root,
      formatVersion: formatVersion,
      engine: 'emulationstation',
      author: author,
      license: license,
      backgroundPath: background,
      musicPath: music,
      regularFontPath: regularFont,
      boldFontPath: boldFont,
      accentHex: normalizedAccent,
    );
  }

  String? _firstElementText(XmlDocument document, String name) {
    for (final element in document.findAllElements(name)) {
      final value = element.innerText.trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  static String _normalizeThemePath(String value) =>
      value.replaceAll('\\', '/').replaceFirst(RegExp(r'^\./'), '');

  String? _firstExistingRelative(String root, List<String> candidates) {
    for (final candidate in candidates) {
      if (File(p.join(root, candidate)).existsSync()) return candidate;
    }
    return null;
  }

  String _safeId(String name) {
    final normalized = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return normalized.isEmpty ? 'full-theme' : normalized;
  }

  Future<void> _copyDirectory(
    Directory source,
    Directory destination,
  ) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(recursive: false, followLinks: false)) {
      final targetPath = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(targetPath));
      } else if (entity is File) {
        await entity.copy(targetPath);
      }
    }
  }

  Future<void> _removeInstalledThemes(
    Directory base, {
    Set<String> exceptPaths = const {},
  }) async {
    final excluded = exceptPaths.map((value) => p.normalize(value)).toSet();
    if (!await base.exists()) return;
    await for (final entity in base.list(followLinks: false)) {
      final normalized = p.normalize(entity.path);
      if (excluded.contains(normalized)) continue;
      try {
        await entity.delete(recursive: true);
      } catch (e) {
        _log.w(
          '[FullTheme] Could not remove old theme entry ${entity.path}: $e',
        );
      }
    }
  }

  Future<void> _registerThemeFonts(FullThemeDefinition definition) async {
    await _loadFont(
      definition.resolve(definition.regularFontPath),
      'NeoStationFullTheme',
    );
    await _loadFont(
      definition.resolve(definition.boldFontPath),
      'NeoStationFullThemeBold',
    );
  }

  Future<void> _loadFont(String? fontPath, String family) async {
    if (fontPath == null) return;
    try {
      final bytes = await File(fontPath).readAsBytes();
      final data = ByteData.view(
        bytes.buffer,
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );
      final loader = FontLoader(family)..addFont(Future.value(data));
      await loader.load();
    } catch (e) {
      _log.w('[FullTheme] Could not load font $fontPath: $e');
    }
  }
}

extension _FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
