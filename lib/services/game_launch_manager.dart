import 'dart:async';
import 'dart:io';
import 'package:armsx2_internal_bridge/armsx2_internal_bridge.dart';
import 'package:dusklight_internal_bridge/dusklight_internal_bridge.dart';
import 'package:kartpad_internal_bridge/kartpad_internal_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:neostation/services/logger_service.dart';
import 'audio_policy_service.dart';
import 'game_service.dart';
import 'music_player_service.dart';
import 'sfx_service.dart';

/// Defines the operational phases of a game execution session.
enum GameLaunchPhase {
  /// Preparing to launch the emulator (pausing music, etc.).
  launching,

  /// The game is currently running.
  playing,

  /// The game process has exited and final cleanup is running.
  closing,

  /// The session has fully terminated.
  closed,
}

/// Controller responsible for managing the lifecycle of a game session and its associated UI state.
///
/// Acts as the single source of truth for platform process monitoring, audio management
/// (music and SFX), and state transitions between launching, playing, and closing.
/// Implements [WidgetsBindingObserver] to track app lifecycle changes on Android.
class GameLaunchManager extends ChangeNotifier with WidgetsBindingObserver {
  static final GameLaunchManager _instance = GameLaunchManager._internal();
  factory GameLaunchManager() => _instance;
  GameLaunchManager._internal();

  static final _log = LoggerService.instance;

  /// Current operational phase. Null if no session is active.
  GameLaunchPhase? _phase;

  /// Whether the session dialog can be dismissed by the user.
  ///
  /// On Android, this is only allowed after the user physically returns from the emulator.
  bool _canDismiss = false;

  /// Whether the session termination flow has been initiated.
  bool _isClosing = false;

  /// Stores the user's SFX preference before starting the session.
  bool _sfxWasEnabled = true;

  // A rapid new launch must wait until the previous audio handoff finishes;
  // otherwise its delayed activation can interrupt the new native core.
  Future<void>? _finalization;

  /// Periodic timer for monitoring the emulator process on desktop platforms.
  Timer? _monitoringTimer;

  /// Embedded iOS runtimes live inside NeoStation's process. They must report
  /// their own teardown rather than being mistaken for a missing external
  /// executable by the desktop process poller.
  StreamSubscription<Map<String, dynamic>>? _embeddedSessionSubscription;

  static const Set<String> _embeddedIOSSessionExecutables = <String>{
    'ios_dusklight_internal',
    'ios_kartpad_internal',
    'ios_armsx2_internal',
  };
  String? _activeEmulatorExe;

  bool get _isEmbeddedIOSSession =>
      Platform.isIOS &&
      _embeddedIOSSessionExecutables.contains(_activeEmulatorExe);

  /// Flag for Android to detect if the app was resumed before monitoring started
  /// (indicating an immediate emulator failure).
  bool _resumedBeforeMonitoring = false;

  GameLaunchPhase? get phase => _phase;
  bool get isActive => _phase != null;

  /// Whether the session management dialog can be manually closed.
  bool get canDismiss {
    if (_phase != GameLaunchPhase.playing) return false;
    // In-process iOS runtimes keep receiving controller input while Flutter
    // remains alive behind their native window. Never let A/B/Enter leak into
    // the launch dialog and close the frontend session underneath gameplay.
    // Their explicit native "Return to NeoStation" event owns teardown.
    if (_isEmbeddedIOSSession) return false;
    if (Platform.isAndroid) return _canDismiss;
    return true;
  }

  /// Initiates a new game session lifecycle.
  ///
  /// Pauses background music, disables UI SFX, and registers lifecycle observers.
  Future<void> beginSession() async {
    await _finalization;
    _finalization = null;
    _phase = GameLaunchPhase.launching;
    _canDismiss = false;
    _isClosing = false;
    _activeEmulatorExe = null;
    unawaited(_embeddedSessionSubscription?.cancel());
    _embeddedSessionSubscription = null;
    WidgetsBinding.instance.addObserver(this);
    _sfxWasEnabled = SfxService().isEnabled;
    SfxService().setEnabled(false);
    await MusicPlayerService().pauseForGame();
    notifyListeners();
    _log.i('[GameLaunchManager] Session started — SFX disabled, music paused.');
  }

  /// Transitions the session to the playing phase and starts platform monitoring.
  ///
  /// Should be called after the emulator process has been successfully created.
  void onGameStarted({String? emulatorExe}) {
    if (_phase == null || _isClosing) return;

    if (Platform.isAndroid && _resumedBeforeMonitoring) {
      _log.w(
        '[GameLaunchManager] Android: resumed during launch phase — emulator likely failed. Triggering close.',
      );
      _triggerClose();
      return;
    }

    _activeEmulatorExe = emulatorExe;
    _phase = GameLaunchPhase.playing;
    notifyListeners();
    _startPlatformMonitoring(emulatorExe);
    _log.i('[GameLaunchManager] Game started — monitoring active.');
  }

  /// Handles an explicit user request to dismiss the session dialog.
  void userDismiss() {
    if (!canDismiss) {
      _log.d(
        '[GameLaunchManager] userDismiss ignored — canDismiss=$_canDismiss phase=$_phase',
      );
      return;
    }
    _log.i('[GameLaunchManager] User dismissed dialog.');
    _triggerClose();
  }

  /// Internal trigger to begin the termination flow.
  void _triggerClose() {
    if (_isClosing) return;
    _isClosing = true;
    _monitoringTimer?.cancel();
    _monitoringTimer = null;
    _phase = GameLaunchPhase.closing;
    notifyListeners();
    _log.i('[GameLaunchManager] Close triggered — entering closing phase.');
  }

  /// Marks the post-game cleanup as finished.
  void completeClose() {
    _phase = GameLaunchPhase.closed;
    notifyListeners();
    _log.i('[GameLaunchManager] Close complete.');
  }

  /// Cleanup hook for when the session dialog is disposed.
  void onDialogDisposed() {
    if (!isActive || _finalization != null) return;
    if (_phase != GameLaunchPhase.closed) {
      _log.w(
        '[GameLaunchManager] Dialog disposed before session ended — forcing cleanup.',
      );
    }
    unawaited(_finalization = _finalize());
  }

  /// Resets the controller state and restores audio preferences.
  Future<void> _finalize() async {
    if (!isActive) return;
    _monitoringTimer?.cancel();
    _monitoringTimer = null;
    unawaited(_embeddedSessionSubscription?.cancel());
    _embeddedSessionSubscription = null;
    GameService.clearOnGameReturnedCallback();
    GameService.clearOnProcessExitCallback();
    WidgetsBinding.instance.removeObserver(this);
    try {
      // The native session has ended before this route is disposed. Restore
      // audio ownership before resuming any menu voices, including on failure.
      await AudioPolicyService().restoreAfterGameSession();
      await MusicPlayerService().resumeAfterGame();
    } catch (error, stack) {
      _log.e(
        '[GameLaunchManager] Could not resume menu audio.',
        error: error,
        stackTrace: stack,
      );
    }
    SfxService().setEnabled(_sfxWasEnabled);
    _phase = null;
    _canDismiss = false;
    _isClosing = false;
    _activeEmulatorExe = null;
    _sfxWasEnabled = true;
    _resumedBeforeMonitoring = false;
    notifyListeners();
    _log.i(
      '[GameLaunchManager] Session finalized — music resumed, SFX re-enabled.',
    );
  }

  /// Monitors Android app lifecycle states to detect user return from the emulator.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    if (state == AppLifecycleState.resumed && !_isClosing) {
      if (_phase == GameLaunchPhase.launching) {
        _resumedBeforeMonitoring = true;
        _log.w(
          '[GameLaunchManager] Android: resumed during launching phase — flagging for close.',
        );
      } else if (_phase == GameLaunchPhase.playing) {
        Future.delayed(const Duration(milliseconds: 800), () {
          if (_phase == GameLaunchPhase.playing && !_isClosing) {
            _canDismiss = true;
            notifyListeners();
            _log.i(
              '[GameLaunchManager] Android: user returned — canDismiss=true.',
            );
            _triggerClose();
          }
        });
      }
    }
  }

  /// Internal logic to start process monitoring based on the current platform.
  void _startPlatformMonitoring(String? emulatorExe) {
    if (Platform.isAndroid) {
      GameService.setOnGameReturnedCallback((_) => _triggerClose());
      return;
    }

    if (Platform.isIOS && emulatorExe == 'ios_dusklight_internal') {
      _embeddedSessionSubscription = DusklightInternalBridge.sessionEvents.listen(
        (event) {
          if (_phase == GameLaunchPhase.playing && !_isClosing) {
            _log.i(
              '[GameLaunchManager] Dusklight returned to NeoStation: '
              '${event['reason']} (runtimeReleased=${event['runtimeReleased']})',
            );
            // A normal return now retains the suspended Dusklight runtime so
            // the same disc can reopen instantly. Build 321's early RPCS3 JIT
            // escrow remains reserved before Dusklight can allocate memory.
            _triggerClose();
          }
        },
      );
      if (DusklightInternalBridge.didEndSession && !_isClosing) {
        _triggerClose();
      }
      return;
    }

    if (Platform.isIOS && emulatorExe == 'ios_kartpad_internal') {
      _embeddedSessionSubscription = KartPadInternalBridge.sessionEvents.listen(
        (event) {
          final exitReason = event['exitReason']?.toString() ?? 'unknown';
          _log.i(
            '[GameLaunchManager] KartPad host result=$exitReason '
            'message=${event['reason'] ?? 'unknown'} '
            '(success=${event['success']}, runtimeReleased=${event['runtimeReleased']})',
          );
          if (_phase != GameLaunchPhase.playing || _isClosing) return;

          // A language restart is owned by the native bridge and must never
          // unwind NeoStation's game-launch UI. The plugin normally suppresses
          // sessionEnded for it; this guard makes a stale/duplicate callback
          // harmless as well.
          if (exitReason == 'languageRestart') return;

          if (exitReason == 'userReturn' ||
              exitReason == 'normalTermination' ||
              exitReason == 'runtimeFailure' ||
              exitReason == 'crash' ||
              exitReason == 'launchFailure') {
            _triggerClose();
          }
        },
      );
      if (KartPadInternalBridge.didEndSession && !_isClosing) {
        _triggerClose();
      }
      return;
    }

    if (Platform.isIOS && emulatorExe == 'ios_armsx2_internal') {
      _embeddedSessionSubscription = Armsx2InternalBridge.sessionEvents.listen((
        event,
      ) {
        if (_phase == GameLaunchPhase.playing && !_isClosing) {
          _log.i(
            '[GameLaunchManager] ARMSX2 native session ended: '
            '${event['reason'] ?? 'unknown'}',
          );
          _triggerClose();
        }
      });
      _log.i(
        '[GameLaunchManager] ARMSX2 uses native session-end monitoring.',
      );
      return;
    }

    GameService.setOnProcessExitCallback(_triggerClose);
    _startDesktopPolling(emulatorExe);
  }

  /// Periodically polls the OS process list on desktop platforms to detect emulator exit.
  void _startDesktopPolling(String? emulatorExe) {
    Future.delayed(const Duration(seconds: 2), () {
      if (_phase != GameLaunchPhase.playing) return;
      _monitoringTimer = Timer.periodic(const Duration(seconds: 2), (
        timer,
      ) async {
        if (_phase != GameLaunchPhase.playing) {
          timer.cancel();
          return;
        }
        try {
          final running = await GameService.isEmulatorRunning(emulatorExe);
          if (!running) {
            timer.cancel();
            _triggerClose();
          }
        } catch (e) {
          _log.e(
            '[GameLaunchManager] Desktop polling error (${Platform.operatingSystem}): $e',
          );
          timer.cancel();
          _triggerClose();
        }
      });
    });
  }
}
