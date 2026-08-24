import 'dart:io';
import 'package:flutter/foundation.dart';
import '../services/neo_assets_service.dart';
import '../repositories/config_repository.dart';
import '../services/logger_service.dart';

final _log = LoggerService.instance;

/// Provider responsible for managing remote and local theme assets (logos, backgrounds).
///
/// Handles theme discovery, batch downloading of assets, and persistence of the
/// active theme selection. Uses [NeoAssetsService] for network and cache I/O.
class NeoAssetsProvider extends ChangeNotifier {
  static const List<String> _videoBackgroundExtensions = ['mp4', 'm4v', 'mov'];

  /// List of available themes fetched from the remote repository.
  List<NeoAssetsTheme> _themes = [];

  /// Folder name of the currently selected theme.
  String _activeThemeFolder = '';

  /// Whether a network request to fetch themes is in progress.
  bool _loading = false;

  /// Whether a background download of theme assets is active.
  bool _downloading = false;

  /// Normalized download progress (0.0 to 1.0).
  double _downloadProgress = 0.0;

  /// Internal flag to ensure initialization logic runs only once.
  bool _initialized = false;

  List<NeoAssetsTheme> get themes => _themes;
  String get activeThemeFolder => _activeThemeFolder;
  bool get loading => _loading;
  bool get downloading => _downloading;
  double get downloadProgress => _downloadProgress;
  bool get hasActiveTheme => _activeThemeFolder.isNotEmpty;

  /// Returns the currently active [NeoAssetsTheme] metadata.
  NeoAssetsTheme? get activeTheme => _themes.isEmpty
      ? null
      : _themes.where((t) => t.folder == _activeThemeFolder).firstOrNull;

  /// Initializes the theme cache directory and loads the active theme from the database.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await NeoAssetsService.ensureCacheDirInitialized();
    _activeThemeFolder = await ConfigRepository.getActiveTheme();
    notifyListeners();
    await loadThemes();
  }

  /// Fetches the list of available themes from the remote server.
  Future<void> loadThemes() async {
    _loading = true;
    notifyListeners();
    try {
      _themes = await NeoAssetsService.fetchThemes();
    } catch (e) {
      _log.e('Error loading themes: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Sets a new active theme and persists the choice to the local database.
  Future<void> setActiveTheme(String themeFolder) async {
    if (_activeThemeFolder == themeFolder) return;
    _activeThemeFolder = themeFolder;
    await ConfigRepository.updateActiveTheme(themeFolder);
    notifyListeners();
  }

  /// Deselects the current theme and resets the active selection.
  Future<void> clearTheme() async {
    _activeThemeFolder = '';
    await ConfigRepository.updateActiveTheme('');
    notifyListeners();
  }

  /// Downloads all required assets for the specified theme and applies it.
  ///
  /// Existing WebP/GIF packs keep the normal bulk path. Video backgrounds stay
  /// supported as an on-demand fallback through [getBackgroundForSystem], but
  /// are deliberately not probed here after the bulk download reaches 100%.
  /// Eagerly probing mp4/m4v/mov for every system made the first-run art-pack
  /// screen appear frozen at 100% while sequential 404/network requests were
  /// still running in the background.
  Future<void> downloadAndApplyTheme(
    String themeFolder,
    List<String> systemFolderNames,
  ) async {
    try {
      final plan = await NeoAssetsService.buildThemeDownloadPlan(
        themeFolder,
        systemFolderNames,
      );

      if (plan.totalAssetsToDownload > 0) {
        _downloading = true;
        _downloadProgress = 0.0;
        notifyListeners();

        if (plan.forceRedownload) {
          await NeoAssetsService.downloadAllThemeAssets(
            themeFolder,
            plan.systemsToDownload,
            forceRedownload: true,
            onProgress: (done, t) {
              _downloadProgress = t == 0 ? 1.0 : done / t;
              notifyListeners();
            },
          );
        } else {
          await NeoAssetsService.downloadMissingThemeAssets(
            themeFolder,
            plan.systemsToDownload,
            missingTotal: plan.totalAssetsToDownload,
            onProgress: (done, t) {
              _downloadProgress = t == 0 ? 1.0 : done / t;
              notifyListeners();
            },
          );
        }
      }

      if (plan.remoteMetadata != null) {
        await NeoAssetsService.writeLocalThemeMetadata(
          themeFolder,
          plan.remoteMetadata!,
        );
      }

      _activeThemeFolder = themeFolder;
      await ConfigRepository.updateActiveTheme(themeFolder);
    } catch (e) {
      _log.e('Error downloading theme: $e');
    } finally {
      _downloading = false;
      _downloadProgress = 0.0;
      notifyListeners();
    }
  }

  Future<String?> _getCachedVideoBackground(
    String themeFolder,
    String systemFolderName,
  ) async {
    for (final ext in _videoBackgroundExtensions) {
      final localPath = await NeoAssetsService.backgroundCachePath(
        themeFolder,
        systemFolderName,
        ext: ext,
      );
      if (await File(localPath).exists()) return localPath;

      final url = NeoAssetsService.getBackgroundUrl(
        themeFolder,
        systemFolderName,
        ext: ext,
      );
      final result = await NeoAssetsService.downloadAndCacheAsset(url, localPath);
      if (result != null) return result;
    }
    return null;
  }

  String? _resolveCachedVideoBackgroundSync(
    String themeFolder,
    String systemFolderName,
  ) {
    for (final ext in _videoBackgroundExtensions) {
      final localPath = NeoAssetsService.backgroundCachePathSync(
        themeFolder,
        systemFolderName,
        ext: ext,
      );
      if (localPath != null && File(localPath).existsSync()) return localPath;
    }
    return null;
  }

  /// Resolves the absolute path to a system background within the active theme.
  Future<String?> getBackgroundForSystem(String systemFolderName) async {
    if (!hasActiveTheme) return null;
    final image = await NeoAssetsService.getCachedBackground(
      _activeThemeFolder,
      systemFolderName,
    );
    if (image != null) return image;
    return _getCachedVideoBackground(_activeThemeFolder, systemFolderName);
  }

  /// Synchronous variant for resolving background paths.
  /// Preserves WebP/GIF precedence, then falls back to cached video media.
  String? getBackgroundForSystemSync(String systemFolderName) {
    if (!hasActiveTheme) return null;
    final image = NeoAssetsService.resolveBackgroundPathSync(
      _activeThemeFolder,
      systemFolderName,
    );
    if (image != null && File(image).existsSync()) return image;

    return _resolveCachedVideoBackgroundSync(
          _activeThemeFolder,
          systemFolderName,
        ) ??
        image;
  }

  /// Logos are no longer loaded from remote themes.
  /// Returns null to fall through to bundled local assets.
  Future<String?> getLogoForSystem(String systemFolderName) async {
    return null;
  }

  /// Synchronous variant — always returns null.
  String? getLogoForSystemSync(String systemFolderName) {
    return null;
  }
}
