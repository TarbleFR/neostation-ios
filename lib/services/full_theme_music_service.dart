import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../models/full_theme_definition.dart';
import 'logger_service.dart';
import 'music_player_service.dart';
import 'sfx_service.dart';

/// Plays music supplied by the active full theme only while its home screen is
/// visible. User music always wins, and leaving the full-theme home stops the
/// theme ambience immediately.
class FullThemeMusicService with WidgetsBindingObserver {
  FullThemeMusicService._();

  static final FullThemeMusicService instance = FullThemeMusicService._();

  final LoggerService _log = LoggerService.instance;
  bool _initialized = false;
  bool _homeVisible = false;
  bool _appActive = true;
  bool _starting = false;
  String? _requestedPath;
  AudioSource? _source;
  SoundHandle? _handle;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    MusicPlayerService().addListener(_onUserMusicChanged);
  }

  Future<void> setHomeVisible(
    bool visible, {
    FullThemeDefinition? theme,
  }) async {
    await initialize();
    _homeVisible = visible;
    final nextPath = theme?.resolve(theme.musicPath);
    if (_requestedPath != nextPath) {
      await _stop();
      _requestedPath = nextPath;
    }
    await _sync();
  }

  bool get _shouldPlay =>
      _homeVisible &&
      _appActive &&
      _requestedPath != null &&
      File(_requestedPath!).existsSync() &&
      !MusicPlayerService().isPlaying;

  void _onUserMusicChanged() {
    unawaited(_sync());
  }

  Future<void> _sync() async {
    if (_shouldPlay) {
      await _start();
    } else {
      await _stop();
    }
  }

  Future<void> _start() async {
    if (_starting || _handle != null || !_shouldPlay) return;
    _starting = true;
    try {
      await SfxService().init();
      if (!_shouldPlay || _requestedPath == null) return;
      final source = await SoLoud.instance.loadFile(_requestedPath!);
      if (!_shouldPlay) {
        await SoLoud.instance.disposeSource(source);
        return;
      }
      _source = source;
      _handle = SoLoud.instance.play(source, volume: 0.28, looping: true);
      _log.i('[FullTheme] Theme ambience started.');
    } catch (e) {
      _source = null;
      _handle = null;
      _log.w('[FullTheme] Could not start theme ambience: $e');
    } finally {
      _starting = false;
    }
  }

  Future<void> _stop() async {
    final handle = _handle;
    final source = _source;
    _handle = null;
    _source = null;
    try {
      if (handle != null && SoLoud.instance.isInitialized) {
        await SoLoud.instance.stop(handle);
      }
    } catch (_) {}
    try {
      if (source != null && SoLoud.instance.isInitialized) {
        await SoLoud.instance.disposeSource(source);
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    unawaited(_sync());
  }
}
