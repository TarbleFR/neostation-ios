import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'config_service.dart';
import 'logger_service.dart';
import 'music_player_service.dart';
import 'sfx_service.dart';

/// Plays user-selected ambience only while the primary Systems menu is visible.
///
/// The user manages the audio file from Theme settings. NeoStation copies it
/// into `<user-data>/menu_music` so it lives alongside the user's other visual
/// customizations and survives file-provider/security-scoped access changes.
/// Playback shares NeoStation's existing SoLoud engine, yields to the Music
/// player, and stops outside the main menu or while the app is backgrounded.
class HomeMusicService extends ChangeNotifier with WidgetsBindingObserver {
  HomeMusicService._internal();

  static final HomeMusicService _instance = HomeMusicService._internal();
  factory HomeMusicService() => _instance;

  static const String _preferenceKey = 'neostation_home_music_enabled';
  static const String _pathPreferenceKey = 'neostation_home_music_path';
  static const String _namePreferenceKey = 'neostation_home_music_name';
  static const String _directoryName = 'menu_music';
  static const double _volume = 0.28;
  static const List<String> _allowedExtensions = ['mp3', 'wav', 'ogg', 'flac'];

  final LoggerService _log = LoggerService.instance;

  bool _initialized = false;
  bool _enabled = false;
  bool _mainMenuActive = false;
  bool _appActive = true;
  bool _starting = false;

  String? _musicPath;
  String? _musicName;
  AudioSource? _source;
  SoundHandle? _handle;

  bool get enabled => _enabled;
  bool get hasMusic =>
      _musicPath != null &&
      _musicPath!.isNotEmpty &&
      File(_musicPath!).existsSync();
  String? get selectedFileName => _musicName;

  Future<void> init() async {
    if (_initialized) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      _musicPath = prefs.getString(_pathPreferenceKey);
      _musicName = prefs.getString(_namePreferenceKey);
      _enabled = prefs.getBool(_preferenceKey) ?? false;

      await _migrateOrDiscoverMusic();

      if (!hasMusic) {
        _musicPath = null;
        _musicName = null;
        _enabled = false;
        await prefs.remove(_pathPreferenceKey);
        await prefs.remove(_namePreferenceKey);
        await prefs.setBool(_preferenceKey, false);
      } else {
        await _persistPreference();
      }
    } catch (e) {
      _enabled = false;
      _musicPath = null;
      _musicName = null;
      _log.w('[HomeMusic] Could not load preference: $e');
    }

    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    MusicPlayerService().addListener(_onUserMusicChanged);
    notifyListeners();

    await _syncPlayback();
  }

  /// Opens the platform file picker, imports one supported audio file into
  /// NeoStation's user-data directory, and enables it immediately.
  Future<bool> chooseMusic() async {
    if (!_initialized) await init();

    final imported = await _pickAndStoreMusic();
    if (!imported) return false;

    _enabled = true;
    await _persistPreference();
    notifyListeners();
    await _syncPlayback();
    return true;
  }

  /// Enables/disables the selected main-menu music.
  ///
  /// Enabling with no stored track opens the picker once. Re-enabling an
  /// existing track never forces the user to select it again.
  Future<void> setEnabled(bool value) async {
    if (!_initialized) await init();

    if (value && !hasMusic) {
      await chooseMusic();
      return;
    }

    _enabled = value && hasMusic;
    await _persistPreference();
    notifyListeners();
    await _syncPlayback();
  }

  Future<void> setMainMenuActive(bool value) async {
    final changed = _mainMenuActive != value;
    // Assign before initialization. Theme settings can be created while the
    // Systems widget is being disposed; initializing first used the stale true
    // value and briefly restarted menu music under SoLoud's audio category.
    _mainMenuActive = value;

    if (!_initialized) {
      await init();
      return;
    }
    if (!changed) return;
    await _syncPlayback();
  }

  bool get mainMenuActiveForTesting => _mainMenuActive;

  /// Removes the stored custom music file and disables menu music.
  Future<void> clearMusic() async {
    if (!_initialized) await init();
    await _stopPlayback();

    final oldPath = _musicPath;
    _musicPath = null;
    _musicName = null;
    _enabled = false;

    if (oldPath != null) {
      try {
        final file = File(oldPath);
        if (await file.exists()) await file.delete();
      } catch (e) {
        _log.w('[HomeMusic] Could not delete old music file: $e');
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pathPreferenceKey);
      await prefs.remove(_namePreferenceKey);
      await prefs.setBool(_preferenceKey, false);
    } catch (e) {
      _log.w('[HomeMusic] Could not clear preference: $e');
    }

    notifyListeners();
  }

  Future<Directory> _musicDirectory() async {
    final userDataPath = await ConfigService.getUserDataPath();
    final directory = Directory(p.join(userDataPath, _directoryName));
    await directory.create(recursive: true);
    return directory;
  }

  bool _isSupportedPath(String value) {
    final extension = p.extension(value).toLowerCase().replaceFirst('.', '');
    return _allowedExtensions.contains(extension);
  }

  String _safeExtension(String value) {
    final extension = p.extension(value).toLowerCase();
    return _allowedExtensions.contains(extension.replaceFirst('.', ''))
        ? extension
        : '.mp3';
  }

  /// Migrates tracks selected by older builds from Application Support into
  /// the new user-data directory. If no preference exists, a supported file
  /// manually placed in `menu_music` is discovered automatically.
  Future<void> _migrateOrDiscoverMusic() async {
    final directory = await _musicDirectory();
    final existingPath = _musicPath;

    if (existingPath != null) {
      final source = File(existingPath);
      if (await source.exists() && _isSupportedPath(source.path)) {
        final normalizedDirectory = p.normalize(directory.absolute.path);
        final normalizedSource = p.normalize(source.absolute.path);
        final alreadyInDirectory = p.equals(
          normalizedDirectory,
          p.dirname(normalizedSource),
        );

        if (!alreadyInDirectory) {
          final oldPath = source.path;
          final oldParentName = p.basename(p.dirname(oldPath));
          await _storeFile(source, _musicName ?? p.basename(oldPath));

          // Older fork builds owned files inside an Application Support
          // `home_music` directory. Remove only that known legacy copy after a
          // successful migration; never delete arbitrary external source files.
          if (oldParentName == 'home_music') {
            try {
              final legacy = File(oldPath);
              if (await legacy.exists()) await legacy.delete();
            } catch (e) {
              _log.w('[HomeMusic] Could not remove legacy music copy: $e');
            }
          }
        }
        return;
      }
    }

    File? discovered;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !_isSupportedPath(entity.path)) continue;
      if (discovered == null ||
          p.basename(entity.path).startsWith('main_menu_music.')) {
        discovered = entity;
      }
      if (p.basename(entity.path).startsWith('main_menu_music.')) break;
    }

    if (discovered != null) {
      _musicPath = discovered.path;
      _musicName = p.basename(discovered.path);
      _log.i('[HomeMusic] Discovered menu music in user-data directory.');
    }
  }

  Future<bool> _pickAndStoreMusic() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: _allowedExtensions,
        allowMultiple: false,
      );
      final picked = result?.files.single;
      final sourcePath = picked?.path;
      if (picked == null || sourcePath == null || sourcePath.isEmpty) {
        return false;
      }

      final source = File(sourcePath);
      if (!await source.exists() || !_isSupportedPath(picked.name)) {
        return false;
      }

      await _storeFile(source, picked.name);
      _log.i('[HomeMusic] Selected main-menu music: ${picked.name}');
      return true;
    } catch (e) {
      _log.w('[HomeMusic] Could not import selected music: $e');
      return false;
    }
  }

  /// Copies [source] transactionally so a failed replacement never destroys
  /// the currently selected track.
  Future<void> _storeFile(File source, String displayName) async {
    final directory = await _musicDirectory();
    final extension = _safeExtension(
      displayName.isEmpty ? source.path : displayName,
    );
    final temporary = File(
      p.join(directory.path, 'main_menu_music.importing$extension'),
    );
    final destination = File(
      p.join(directory.path, 'main_menu_music$extension'),
    );

    if (await temporary.exists()) await temporary.delete();
    await source.copy(temporary.path);

    await _stopPlayback();

    // Keep one app-owned track only. The completed temporary copy is excluded
    // until it is atomically renamed to the canonical destination.
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      if (p.equals(entity.absolute.path, temporary.absolute.path)) continue;
      try {
        await entity.delete();
      } catch (_) {}
    }

    await temporary.rename(destination.path);
    _musicPath = destination.path;
    _musicName = displayName.isEmpty ? p.basename(source.path) : displayName;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pathPreferenceKey, destination.path);
    await prefs.setString(_namePreferenceKey, _musicName!);
  }

  Future<void> _persistPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_preferenceKey, _enabled);
      if (_musicPath != null) {
        await prefs.setString(_pathPreferenceKey, _musicPath!);
      }
      if (_musicName != null) {
        await prefs.setString(_namePreferenceKey, _musicName!);
      }
    } catch (e) {
      _log.w('[HomeMusic] Could not save preference: $e');
    }
  }

  void _onUserMusicChanged() {
    unawaited(_syncPlayback());
  }

  bool get _shouldPlay =>
      _enabled &&
      hasMusic &&
      _mainMenuActive &&
      _appActive &&
      !MusicPlayerService().isPlaying;

  Future<void> _syncPlayback() async {
    if (_shouldPlay) {
      await _startPlayback();
    } else {
      await _stopPlayback();
    }
  }

  Future<void> _startPlayback() async {
    if (_starting || _handle != null || !_shouldPlay || _musicPath == null) {
      return;
    }
    _starting = true;

    try {
      // SFX owns the shared SoLoud initialization path. Once the
      // engine is ready, this reader manages only its own source,
      // handle and volume.
      await SfxService().init();
      if (!_shouldPlay || _musicPath == null) return;

      final source = await SoLoud.instance.loadFile(_musicPath!);
      if (!_shouldPlay) {
        await SoLoud.instance.disposeSource(source);
        return;
      }

      _source = source;
      _handle = SoLoud.instance.play(source, volume: _volume, looping: true);
      _log.i('[HomeMusic] Main-menu music started.');
    } catch (e) {
      _source = null;
      _handle = null;
      _log.w('[HomeMusic] Could not start selected music: $e');
    } finally {
      _starting = false;
    }
  }

  Future<void> _stopPlayback() async {
    final handle = _handle;
    final source = _source;
    _handle = null;
    _source = null;

    if (!SoLoud.instance.isInitialized) return;

    if (handle != null) {
      try {
        await SoLoud.instance.stop(handle);
      } catch (_) {}
    }

    if (source != null) {
      try {
        await SoLoud.instance.disposeSource(source);
      } catch (_) {}
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appActive = true;
      unawaited(_syncPlayback());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _appActive = false;
      unawaited(_stopPlayback());
    }
  }
}
