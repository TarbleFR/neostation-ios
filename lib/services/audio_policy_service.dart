import 'dart:async';
import 'dart:io';

import 'package:external_folder_access/external_folder_access.dart';
import 'package:flutter/widgets.dart';

import 'logger_service.dart';

/// Owns NeoStation's single iOS audio-session policy.
///
/// Playback clients do not call this service when they play, pause,
/// change volume, or dispose. SoLoud and AVPlayer manage their playback
/// lifecycles independently. This service restores the app-wide
/// `.ambient` category only at structural boundaries:
///
/// - application startup;
/// - application resume;
/// - after the shared SoLoud engine is created or recreated.
///
/// The native plugin also restores the same category after iOS
/// interruption and route-change notifications.
class AudioPolicyService with WidgetsBindingObserver {
  AudioPolicyService._internal();

  static final AudioPolicyService _instance = AudioPolicyService._internal();
  factory AudioPolicyService() => _instance;

  final LoggerService _log = LoggerService.instance;

  bool _initialized = false;
  Future<void> _serial = Future<void>.value();
  int _applicationCount = 0;

  bool get isInitialized => _initialized;
  int get applicationCountForTesting => _applicationCount;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    await _apply(reason: 'application-start');
  }

  /// Restores `.ambient` after a shared native audio engine is created.
  /// This is intentionally an engine-lifecycle hook, not a per-track or
  /// per-sound hook.
  Future<void> restoreAfterSharedAudioEngineInitialization({
    required String reason,
  }) {
    return _apply(reason: 'shared-engine-initialized:$reason');
  }

  Future<void> _apply({required String reason}) {
    if (!Platform.isIOS) return Future<void>.value();

    final completer = Completer<void>();
    _serial = _serial.catchError((Object _) {}).then((_) async {
      try {
        final applied =
            await ExternalFolderAccess.configureAudioSessionForSilentMode();
        if (applied == true) {
          _applicationCount++;
        } else {
          _log.w(
            '[AudioPolicy] Native ambient session was not applied: '
            '$reason',
          );
        }
      } catch (error, stack) {
        _log.e(
          '[AudioPolicy] Failed to apply ambient session: $reason',
          error: error,
          stackTrace: stack,
        );
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    });
    return completer.future;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_apply(reason: 'application-resumed'));
    }
  }
}
