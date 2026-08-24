import 'dart:io';

import 'package:flutter/material.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/custom_theme_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/startup_theme_cache.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:neostation/utils/image_utils.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

/// Provider responsible for managing the application's visual theme.
///
/// The color theme and the optional main-menu custom background are persisted
/// independently. The background is rendered only by the Systems main menu;
/// playlists and other top-level screens keep their normal theme background.
class ThemeProvider extends ChangeNotifier with WidgetsBindingObserver {
  static final _log = LoggerService.instance;
  static const String _customBackgroundPreferenceKey =
      'neostation_custom_background_path';
  static const String _customBackgroundDirectoryName = 'custom_background';

  ThemeData _currentTheme =
      (WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark)
      ? AppThemes.darkTheme
      : AppThemes.lightTheme;

  String _currentThemeName = 'system';
  String? _customBackgroundPath;

  ThemeData get currentTheme {
    if (_currentThemeName == 'system') {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      return brightness == Brightness.dark
          ? availableThemes['dark']!
          : availableThemes['light']!;
    }
    return _currentTheme;
  }

  String get currentThemeName => _currentThemeName;

  String? get customBackgroundPath {
    final value = _customBackgroundPath;
    if (value == null || value.isEmpty) return null;
    return File(value).existsSync() ? value : null;
  }

  bool get hasCustomBackground => customBackgroundPath != null;

  bool get isOled => _currentThemeName == 'oled';

  static final Map<String, ThemeData> availableThemes = {
    'dark': AppThemes.darkTheme,
    'light': AppThemes.lightTheme,
    'oled': AppThemes.oledTheme,
    'valentine': AppThemes.valentineTheme,
    'dracula': AppThemes.draculaTheme,
    'nord': AppThemes.nordTheme,
    'coffee': AppThemes.coffeeTheme,
    'tokyo_night': AppThemes.tokyoNightTheme,
    'retro': AppThemes.retroTheme,
    'abyss': AppThemes.abyssTheme,
    'cyberpunk': AppThemes.cyberpunkTheme,
    'aqua': AppThemes.aquaTheme,
    'palenight': AppThemes.palenightTheme,
    'horizon': AppThemes.horizonTheme,
  };

  static const Map<String, String> themeDisplayNames = {
    'system': 'System',
    'dark': 'Dark',
    'light': 'Light',
    'oled': 'OLED',
    'valentine': 'Valentine',
    'dracula': 'Dracula',
    'nord': 'Nord',
    'coffee': 'Coffee',
    'tokyo_night': 'Tokyo Night',
    'retro': 'Retro',
    'abyss': 'Abyss',
    'cyberpunk': 'Cyberpunk',
    'aqua': 'Aqua',
    'palenight': 'Palenight',
    'horizon': 'Horizon',
  };

  ThemeProvider._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static Future<ThemeProvider> create() async {
    final provider = ThemeProvider._();
    await provider._loadSavedTheme();
    return provider;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    if (_currentThemeName == 'system') {
      _log.i('Platform brightness changed, updating system theme...');
      _updateSystemTheme();
      _notifyThemeChanged();
    }
  }

  void _notifyThemeChanged() {
    StartupThemeCache.save(currentTheme);
    notifyListeners();
  }

  void _updateSystemTheme() {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    _currentTheme = brightness == Brightness.dark
        ? availableThemes['dark']!
        : availableThemes['light']!;
  }

  Future<void> _loadCustomThemes() async {
    try {
      final themes = await CustomThemeService.loadAll();
      AppThemes.customThemes
        ..clear()
        ..addEntries(themes.map((t) => MapEntry(t.id, t)));
    } catch (e) {
      _log.e('Error loading custom themes: $e');
    }
  }

  Future<Directory> _customBackgroundDirectory() async {
    final userDataPath = await ConfigService.getUserDataPath();
    final directory = Directory(
      path.join(userDataPath, _customBackgroundDirectoryName),
    );
    await directory.create(recursive: true);
    return directory;
  }

  /// Resolves the selected custom background against the *current* user-data
  /// root rather than trusting an old absolute sandbox path.
  ///
  /// iOS can change the app-container UUID when an IPA is updated/re-signed.
  /// The Documents contents survive, but an absolute path stored by the old
  /// build then points at the previous container. Menu music already recovers
  /// by rediscovering its app-owned file; custom backgrounds now do the same.
  static Future<File?> _resolvePersistedCustomBackground({
    required Directory targetDirectory,
    String? savedPreference,
  }) async {
    await targetDirectory.create(recursive: true);

    final candidates = <File>[];
    final seen = <String>{};

    void addCandidate(File file) {
      final normalized = path.normalize(file.absolute.path);
      if (seen.add(normalized)) candidates.add(file);
    }

    final saved = savedPreference?.trim() ?? '';
    if (saved.isNotEmpty) {
      // Build 133 and older stored an absolute path. New builds store only the
      // app-owned basename so a changed iOS container root cannot invalidate it.
      if (path.isAbsolute(saved)) addCandidate(File(saved));
      addCandidate(File(path.join(targetDirectory.path, path.basename(saved))));
    }

    final discovered = <File>[];
    try {
      await for (final entity in targetDirectory.list(followLinks: false)) {
        if (entity is File && ImageUtils.isSupportedBackground(entity.path)) {
          discovered.add(entity);
        }
      }
    } catch (_) {}

    discovered.sort((a, b) {
      final aName = path.basename(a.path).toLowerCase();
      final bName = path.basename(b.path).toLowerCase();
      final aCanonical = aName.startsWith('background.') ? 0 : 1;
      final bCanonical = bName.startsWith('background.') ? 0 : 1;
      if (aCanonical != bCanonical) return aCanonical.compareTo(bCanonical);
      return aName.compareTo(bName);
    });
    for (final file in discovered) {
      addCandidate(file);
    }

    for (final candidate in candidates) {
      if (!await candidate.exists() ||
          !ImageUtils.isSupportedBackground(candidate.path)) {
        continue;
      }

      final currentDirectory = path.normalize(targetDirectory.absolute.path);
      final candidateDirectory = path.normalize(candidate.parent.absolute.path);
      if (path.equals(currentDirectory, candidateDirectory)) {
        return candidate;
      }

      // Migrate a valid legacy/background file from another app-owned location
      // into the canonical user-data directory without deleting the source.
      final extension = path.extension(candidate.path).toLowerCase();
      final destination = File(
        path.join(targetDirectory.path, 'background$extension'),
      );
      final temporary = File(
        path.join(targetDirectory.path, 'background.importing$extension'),
      );
      try {
        if (await temporary.exists()) await temporary.delete();
        await candidate.copy(temporary.path);
        await _removeOtherBackgroundFiles(
          targetDirectory,
          exceptPaths: <String>[temporary.path],
        );
        if (await destination.exists()) await destination.delete();
        await temporary.rename(destination.path);
        return destination;
      } catch (_) {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {}
      }
    }

    return null;
  }

  @visibleForTesting
  static Future<String?> resolvePersistedCustomBackgroundForTesting({
    required String userDataPath,
    String? savedPreference,
  }) async {
    final resolved = await _resolvePersistedCustomBackground(
      targetDirectory: Directory(
        path.join(userDataPath, _customBackgroundDirectoryName),
      ),
      savedPreference: savedPreference,
    );
    return resolved?.path;
  }

  static Future<void> _removeOtherBackgroundFiles(
    Directory directory, {
    Iterable<String> exceptPaths = const <String>[],
  }) async {
    final excluded = exceptPaths
        .map((value) => path.normalize(File(value).absolute.path))
        .toSet();
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final normalized = path.normalize(entity.absolute.path);
        if (excluded.contains(normalized)) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _loadCustomBackground() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPreference = prefs.getString(_customBackgroundPreferenceKey);
      final targetDirectory = await _customBackgroundDirectory();
      final resolved = await _resolvePersistedCustomBackground(
        targetDirectory: targetDirectory,
        savedPreference: savedPreference,
      );

      if (resolved == null) {
        _customBackgroundPath = null;
        await prefs.remove(_customBackgroundPreferenceKey);
        return;
      }

      _customBackgroundPath = resolved.path;
      // Store a container-independent value from now on. The actual absolute
      // path is rebuilt from ConfigService.getUserDataPath() at every startup.
      await prefs.setString(
        _customBackgroundPreferenceKey,
        path.basename(resolved.path),
      );
    } catch (e) {
      _log.e('Error loading custom background: $e');
    }
  }

  Future<void> _loadSavedTheme() async {
    try {
      await _loadCustomThemes();
      await _loadCustomBackground();

      final savedThemeName = await ConfigRepository.getThemeName();
      if (savedThemeName == 'system') {
        _currentThemeName = 'system';
        _updateSystemTheme();
        _notifyThemeChanged();
      } else if (availableThemes.containsKey(savedThemeName)) {
        _currentTheme = availableThemes[savedThemeName]!;
        _currentThemeName = savedThemeName;
        _notifyThemeChanged();
      } else if (AppThemes.customThemes.containsKey(savedThemeName)) {
        _currentTheme = AppThemes.customThemes[savedThemeName]!.themeData;
        _currentThemeName = savedThemeName;
        _notifyThemeChanged();
      } else {
        _log.w(
          'Saved theme "$savedThemeName" is no longer available, falling back to system.',
        );
        _currentThemeName = 'system';
        _updateSystemTheme();
        await ConfigRepository.updateThemeName('system');
        _notifyThemeChanged();
      }
    } catch (e) {
      _log.e('Error loading saved theme: $e');
    }
  }

  Future<void> setTheme(String themeName) async {
    if (themeName == 'system') {
      _currentThemeName = 'system';
      _updateSystemTheme();
      try {
        await ConfigRepository.updateThemeName('system');
      } catch (e) {
        _log.e('Error saving theme: $e');
      }
      _notifyThemeChanged();
      return;
    }

    ThemeData? resolved = availableThemes[themeName];
    resolved ??= AppThemes.customThemes[themeName]?.themeData;

    if (resolved != null) {
      _currentTheme = resolved;
      _currentThemeName = themeName;
      try {
        await ConfigRepository.updateThemeName(themeName);
      } catch (e) {
        _log.e('Error saving theme: $e');
      }
      _notifyThemeChanged();
    }
  }

  /// Copies a selected image/GIF/video into NeoStation's user-data directory.
  /// It is intentionally not part of ThemeData: only the main Systems menu
  /// renders it, so game playlists and the rest of the app remain unchanged.
  Future<String> setCustomBackground(File sourceFile) async {
    if (!await sourceFile.exists()) {
      throw FileSystemException(
        'Custom background file was not found',
        sourceFile.path,
      );
    }
    if (!ImageUtils.isSupportedBackground(sourceFile.path)) {
      throw const FormatException('Unsupported custom background format');
    }

    final targetDir = await _customBackgroundDirectory();
    final extension = path.extension(sourceFile.path).toLowerCase();
    final destination = File(path.join(targetDir.path, 'background$extension'));
    final temporary = File(
      path.join(targetDir.path, 'background.importing$extension'),
    );
    final normalizedSource = path.normalize(sourceFile.absolute.path);
    final normalizedDestination = path.normalize(destination.absolute.path);

    if (!path.equals(normalizedSource, normalizedDestination)) {
      if (await temporary.exists()) await temporary.delete();
      await sourceFile.copy(temporary.path);

      // Replace only after the complete copy exists, so a failed import never
      // destroys the currently selected background.
      await _removeOtherBackgroundFiles(
        targetDir,
        exceptPaths: <String>[temporary.path],
      );
      if (await destination.exists()) await destination.delete();
      await temporary.rename(destination.path);
    } else {
      await _removeOtherBackgroundFiles(
        targetDir,
        exceptPaths: <String>[destination.path],
      );
    }

    _customBackgroundPath = destination.path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _customBackgroundPreferenceKey,
      path.basename(destination.path),
    );
    notifyListeners();
    return destination.path;
  }

  Future<void> clearCustomBackground() async {
    final oldPath = _customBackgroundPath;
    _customBackgroundPath = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_customBackgroundPreferenceKey);

    try {
      final targetDir = await _customBackgroundDirectory();
      await _removeOtherBackgroundFiles(targetDir);
    } catch (_) {}

    if (oldPath != null && oldPath.isNotEmpty) {
      try {
        final file = File(oldPath);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    notifyListeners();
  }

  List<Map<String, String>> getThemeList() {
    final list = availableThemes.keys.map((key) {
      return {'name': key, 'displayName': themeDisplayNames[key] ?? key};
    }).toList();

    for (final custom in AppThemes.customThemes.values) {
      list.add({'name': custom.id, 'displayName': custom.name});
    }

    return list;
  }

  bool isCustomTheme(String themeName) =>
      AppThemes.customThemes.containsKey(themeName);

  Future<ThemeImportResult> importTheme(File file) async {
    final reserved = {...availableThemes.keys, 'system'};
    final result = await CustomThemeService.importFromFile(
      file.path,
      reservedIds: reserved,
      existing: AppThemes.customThemes.values.toList(),
    );
    AppThemes.customThemes[result.theme.id] = result.theme;
    notifyListeners();
    await setTheme(result.theme.id);
    return result;
  }

  Future<void> deleteTheme(String themeName) async {
    if (!AppThemes.customThemes.containsKey(themeName)) return;

    await CustomThemeService.delete(themeName);
    AppThemes.customThemes.remove(themeName);

    if (_currentThemeName == themeName) {
      await setTheme('system');
    } else {
      notifyListeners();
    }
  }
}
