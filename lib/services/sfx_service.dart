import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:neostation/services/audio_policy_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:path_provider/path_provider.dart';

/// Independent service for managing user-interface sound effects.
///
/// Playback mirrors NeoStation's official implementation: preloaded
/// sources are played directly through SoLoud with a short debounce.
/// Individual navigation, confirm and back sounds never touch
/// AVAudioSession.
class SfxService {
  static final SfxService _instance = SfxService._internal();
  factory SfxService() => _instance;
  SfxService._internal();

  static const List<String> _navSounds = [
    'assets/sounds/nav1.wav',
    'assets/sounds/nav2.wav',
    'assets/sounds/nav3.wav',
  ];
  static const String _enterSound = 'assets/sounds/enter.wav';
  static const String _backSound = 'assets/sounds/back.wav';
  static const int _debounceMs = 60;

  final LoggerService _log = LoggerService.instance;
  final Random _random = Random();
  final Map<String, AudioSource> _sources = <String, AudioSource>{};

  bool _isInitialized = false;
  bool _isInitializing = false;
  int _lastNavIndex = -1;
  DateTime? _lastPlayTime;
  bool _enabled = true;
  double _volume = 0.75;
  Completer<void>? _initCompleter;

  double get volume => _volume;
  bool get isInitialized => _isInitialized;
  bool get isEnabled => _enabled;

  Future<void> init() async {
    if (_isInitialized) return;
    if (_isInitializing) return _initCompleter?.future;

    _isInitializing = true;
    _initCompleter = Completer<void>();

    try {
      _log.i('[SfxService] Initializing...');

      var createdSharedEngine = false;
      if (!SoLoud.instance.isInitialized) {
        try {
          final tempDir = await getTemporaryDirectory();
          await Directory(
            '${tempDir.path}/SoLoudLoader-Temp-Files',
          ).create(recursive: true);
        } catch (_) {}

        await SoLoud.instance.init();
        createdSharedEngine = true;
      }

      if (createdSharedEngine) {
        await AudioPolicyService().restoreAfterSharedAudioEngineInitialization(
          reason: 'soloud-sfx',
        );
      }

      final allPaths = <String>[..._navSounds, _enterSound, _backSound];
      for (final soundPath in allPaths) {
        try {
          AudioSource? source;
          var retries = 0;
          while (source == null && retries < 2) {
            try {
              source = await SoLoud.instance.loadAsset(soundPath);
            } catch (error) {
              retries++;
              if (retries < 2) {
                _log.w(
                  '[SfxService] Retrying load for $soundPath '
                  '($retries/2)...',
                );
                await Future<void>.delayed(const Duration(milliseconds: 200));
              } else {
                rethrow;
              }
            }
          }

          if (source != null) {
            _sources[soundPath] = source;
            _log.d('[SfxService] Loaded: $soundPath');
          }
        } catch (error) {
          _log.w('[SfxService] Could not load $soundPath: $error');
        }
      }

      _isInitialized = true;
      _log.i(
        '[SfxService] Ready. ${_sources.length}/'
        '${allPaths.length} sounds loaded.',
      );
      _initCompleter?.complete();
    } catch (error, stack) {
      _log.e(
        '[SfxService] Init error: $error',
        error: error,
        stackTrace: stack,
      );
      _initCompleter?.completeError(error, stack);
    } finally {
      _isInitializing = false;
    }
  }

  void handleEngineTornDown() {
    _sources.clear();
    _isInitialized = false;
    _isInitializing = false;
    _initCompleter = null;
    _log.i('[SfxService] Engine released; SFX will reload on resume.');
  }

  Future<void> reinitializeAfterEngineRestart() async {
    if (_isInitialized) return;
    await init();
  }

  Future<void> dispose() async {
    if (SoLoud.instance.isInitialized) {
      for (final source in _sources.values) {
        try {
          await SoLoud.instance.disposeSource(source);
        } catch (_) {}
      }
    }
    _sources.clear();
    _isInitialized = false;
    _log.i('[SfxService] Disposed.');
  }

  Future<void> playNavSound() async {
    if (!_enabled || !_debounce()) return;
    await _ensureInitialized();
    if (!_isInitialized || _sources.isEmpty) return;

    final index = _pickRandomNavIndex();
    final soundPath = _navSounds[index];
    await _play(soundPath);
    _log.d('[SfxService] nav[$index]: $soundPath');
  }

  Future<void> playEnterSound() async {
    if (!_enabled || !_debounce()) return;
    await _ensureInitialized();
    if (!_isInitialized) return;
    await _play(_enterSound);
    _log.d('[SfxService] enter');
  }

  Future<void> playBackSound() async {
    if (!_enabled || !_debounce()) return;
    await _ensureInitialized();
    if (!_isInitialized) return;
    await _play(_backSound);
    _log.d('[SfxService] back');
  }

  void setVolume(double value) {
    _volume = value.clamp(0.0, 0.75);
    _log.d('[SfxService] Volume set to $_volume');
  }

  void setEnabled(bool value) {
    _enabled = value;
    _log.d('[SfxService] SFX ${value ? 'enabled' : 'disabled'}');
  }

  bool _debounce() {
    final now = DateTime.now();
    if (_lastPlayTime != null &&
        now.difference(_lastPlayTime!).inMilliseconds < _debounceMs) {
      return false;
    }
    _lastPlayTime = now;
    return true;
  }

  Future<void> _ensureInitialized() async {
    if (!_isInitialized) await init();
  }

  Future<void> _play(String soundPath) async {
    final source = _sources[soundPath];
    if (source == null) {
      _log.w('[SfxService] Source not found for: $soundPath');
      return;
    }
    if (!_enabled || !SoLoud.instance.isInitialized) return;

    try {
      SoLoud.instance.play(source, volume: _volume);
    } catch (error) {
      _log.w('[SfxService] Playback error for $soundPath: $error');
    }
  }

  int _pickRandomNavIndex() {
    if (_navSounds.length == 1) return 0;

    int index;
    do {
      index = _random.nextInt(_navSounds.length);
    } while (index == _lastNavIndex);

    _lastNavIndex = index;
    return index;
  }
}
