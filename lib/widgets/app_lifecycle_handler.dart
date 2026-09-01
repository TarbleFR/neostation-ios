import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';
import '../services/notification_service.dart';
import '../services/neosync/auth_service.dart';
import '../services/game_session_persistence.dart';
import '../sync/sync_manager.dart';
import '../sync/providers/neo_sync_adapter.dart';
import '../widgets/plan_welcome_modal.dart';
import '../widgets/plan_farewell_modal.dart';
import '../services/game_service.dart';
import '../services/music_player_service.dart';
import '../providers/sqlite_config_provider.dart';
import '../repositories/system_repository.dart';
import 'package:provider/provider.dart';

/// Widget that detects when the app returns to the foreground and reactivates the gamepad
class AppLifecycleHandler extends StatefulWidget {
  final Widget child;

  const AppLifecycleHandler({super.key, required this.child});

  @override
  State<AppLifecycleHandler> createState() => _AppLifecycleHandlerState();
}

class _AppLifecycleHandlerState extends State<AppLifecycleHandler>
    with WidgetsBindingObserver {
  String? _lastKnownPlan;
  AppLifecycleListener? _exitListener;

  // iOS external emulators can suspend NeoStation for a long time or cause the
  // process to be reclaimed entirely. Track a real background transition so a
  // transient foreground event during launch cannot be mistaken for game exit.
  bool _iosGameWasBackgrounded = false;
  bool _iosGameRecoveryInProgress = false;

  static final _log = LoggerService.instance;

  /// Determines the level of a plan (higher number = better plan)
  int _getPlanLevel(String planName) {
    switch (planName.toLowerCase()) {
      case 'free':
        return 0;
      case 'micro':
        return 1;
      case 'mini':
        return 2;
      case 'mega':
        return 3;
      case 'ultra':
        return 4;
      default:
        return 0;
    }
  }

  /// Determines whether the plan change is an upgrade or downgrade
  bool _isUpgrade(String oldPlan, String newPlan) {
    return _getPlanLevel(newPlan) > _getPlanLevel(oldPlan);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Register exit listener to clean up native resources (SoLoud audio threads)
    // so the process exits cleanly when the window is closed.
    _exitListener = AppLifecycleListener(
      onExitRequested: () async {
        try {
          MusicPlayerService().dispose();
        } catch (_) {}
        return AppExitResponse.exit;
      },
    );

    // A HOME launcher is not paused on screen-off, so lifecycle `paused` never
    // fires on lock. Bridge the native screen on/off signal to the websocket:
    // suspend it while locked, reconnect on wake (music/audio is handled in
    // GameService's channel handler). Screen-on only fires here when NeoStation
    // is foreground (gated on !isGameLaunched at the call site).
    GameService.onScreenStateChanged = (screenOn) {
      if (!mounted) return;
      final notificationService = Provider.of<NotificationService>(
        context,
        listen: false,
      );
      if (screenOn) {
        notificationService.connect().catchError((error) {
          _log.e('Failed to reconnect notifications on screen-on: $error');
        });
      } else {
        notificationService.suspend();
      }
    };

    // Initialize with current plan after a delay to ensure auth is loaded.
    // The same post-frame point is also the safest place to recover an iOS game
    // session after the OS killed NeoStation behind ARMSX2: SQLite, bookmarks,
    // AuthService and SyncManager are all already initialized by main.dart.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final authService = Provider.of<AuthService>(context, listen: false);
      if (authService.isLoggedIn) {
        _lastKnownPlan = authService.currentUser?.plan;
      }

      if (Platform.isIOS) {
        await _recoverPendingIosGameSync(reason: 'cold-start');
      }
    });
  }

  @override
  void dispose() {
    _exitListener?.dispose();
    GameService.onScreenStateChanged = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Uploads the save for the persisted iOS game session.
  ///
  /// This covers both:
  /// - a warm return where NeoStation survived behind the emulator; and
  /// - a cold return where iOS reclaimed NeoStation and reconstructed the app.
  ///
  /// The active-game identity is cleared only after a successful provider call.
  /// The startup-scan guard is deliberately preserved here; AppScreen owns and
  /// consumes that one-shot flag so the existing #71 no-rescan behavior remains
  /// untouched.
  Future<void> _recoverPendingIosGameSync({
    required String reason,
    bool requireMinimumElapsed = false,
  }) async {
    if (!Platform.isIOS || !mounted || _iosGameRecoveryInProgress) return;

    final session = await GameSessionPersistence.getActiveGameSession();
    if (session == null) return;

    final systemFolderName = session['systemFolderName']?.toString();
    final filename = session['filename']?.toString();
    final startTimestamp =
        int.tryParse(session['startTimestamp']?.toString() ?? '0') ?? 0;

    if (systemFolderName == null ||
        systemFolderName.isEmpty ||
        filename == null ||
        filename.isEmpty) {
      _log.w(
        'iOS NeoSync recovery skipped: incomplete persisted game session.',
      );
      return;
    }

    if (requireMinimumElapsed && startTimestamp > 0) {
      final elapsedMs =
          DateTime.now().millisecondsSinceEpoch - startTimestamp;
      if (elapsedMs < 4000) {
        _log.i(
          'iOS NeoSync recovery deferred during launch handoff '
          '(elapsed=${elapsedMs}ms, reason=$reason).',
        );
        return;
      }
    }

    final syncProvider = Provider.of<SyncManager>(
      context,
      listen: false,
    ).active;
    if (syncProvider == null || !syncProvider.isAuthenticated) {
      _log.i(
        'iOS NeoSync recovery retained for retry: provider unavailable or '
        'not authenticated (reason=$reason).',
      );
      return;
    }

    _iosGameRecoveryInProgress = true;
    try {
      final system = await SystemRepository.getSystemByFolderName(
        systemFolderName,
      );
      if (system?.id == null) {
        _log.w(
          'iOS NeoSync recovery retained: system "$systemFolderName" '
          'is not ready yet (reason=$reason).',
        );
        return;
      }

      final game = await GameService.getGameDetails(system!, filename);
      if (game == null) {
        _log.w(
          'iOS NeoSync recovery retained: game "$filename" was not found '
          'in "$systemFolderName" yet (reason=$reason).',
        );
        return;
      }

      _log.i(
        'iOS NeoSync recovery: syncing "${game.name}" after emulator return '
        '(reason=$reason).',
      );
      final result = await syncProvider.syncGameSavesAfterClose(game);
      if (result.success) {
        await GameSessionPersistence.clearActiveGameSession();
        _log.i(
          'iOS NeoSync recovery complete for "${game.name}" '
          '(reason=$reason).',
        );
      } else {
        _log.w(
          'iOS NeoSync recovery failed for "${game.name}": '
          '${result.message ?? result.error?.name ?? 'unknown error'}',
        );
      }
    } catch (e) {
      _log.e('iOS NeoSync recovery error (reason=$reason): $e');
    } finally {
      _iosGameRecoveryInProgress = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      // iOS can keep the system IME visible across app switches even when
      // NeoStation has no active text field. Clear Flutter focus and explicitly
      // dismiss the text-input channel before restoring the rest of the app.
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');

      if (Platform.isIOS && _iosGameWasBackgrounded) {
        _iosGameWasBackgrounded = false;
        // syncGameSavesAfterClose already waits briefly for the emulator to
        // finish flushing its save file before it uploads.
        await _recoverPendingIosGameSync(
          reason: 'warm-return',
          requireMinimumElapsed: true,
        );
      }

      await GameService.handleAppResumed();

      if (!mounted) return;

      // Re-apply secondary display preference after display reconnection.
      if (Platform.isAndroid) {
        final configProvider = Provider.of<SqliteConfigProvider>(
          context,
          listen: false,
        );
        configProvider.reapplySecondaryDisplay();
        // Re-push accessibility (Screen Return) state to the secondary display:
        // the user may have just enabled it in system Settings (e.g. via the
        // in-game launcher's nudge), which controls the screenshot button and
        // the launcher's warning badge.
        // ignore: unawaited_futures
        configProvider.refreshSecondaryScreenshotAccess();
      }

      final notificationService = Provider.of<NotificationService>(
        context,
        listen: false,
      );
      notificationService.connect().catchError((error) {
        _log.e('Failed to reconnect notifications on app resume: $error');
      });

      MusicPlayerService().appResumed();

      await _checkForDataUpdates();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (Platform.isIOS && GameService.isGameLaunched) {
        _iosGameWasBackgrounded = true;
      }

      if (!mounted) return;
      Provider.of<NotificationService>(context, listen: false).suspend();
      MusicPlayerService().appPaused();
    }
  }

  Future<void> _checkForDataUpdates() async {
    final syncManager = Provider.of<SyncManager>(context, listen: false);
    final syncProvider = syncManager.active;

    // Only check if we have an authenticated provider
    if (syncProvider == null || !syncProvider.isAuthenticated) {
      return;
    }

    // Plan tracking is NeoSync-specific; gate behind provider id.
    if (syncProvider.providerId != NeoSyncAdapter.kProviderId) {
      return;
    }

    final authService = Provider.of<AuthService>(context, listen: false);

    // Only check if the user is logged in
    if (!authService.isLoggedIn) {
      return;
    }

    try {
      // Check whether the profile changed (possible plan upgrade)
      final profileResult = await authService.getProfile();
      if (profileResult['success'] == true) {
        final currentUser = authService.currentUser;
        final currentPlan = currentUser?.plan;

        // Additional check: verify authentication by attempting a simple API call
        try {
          final quota = await syncProvider.getQuota();
          if (quota == null) {
            _log.e('NeoSync authentication failed');
          }
        } catch (e) {
          _log.e('Error refreshing sync data: $e');
          // Silently handle authentication errors to prevent unauthorized API calls
        }

        // If _lastKnownPlan is null, initialize it with the current plan
        if (_lastKnownPlan == null && currentPlan != null) {
          _lastKnownPlan = currentPlan;

          return; // Do not show modal on first initialization
        }

        // Detect plan change and show appropriate modal
        if (_lastKnownPlan != null &&
            currentPlan != null &&
            _lastKnownPlan != currentPlan) {
          final isUpgrade = _isUpgrade(_lastKnownPlan!, currentPlan);

          // Delay to ensure the UI updates first
          Future.delayed(const Duration(milliseconds: 1000), () {
            if (mounted) {
              if (isUpgrade) {
                // Show welcome modal for upgrades
                PlanWelcomeModal.show(context, currentPlan);
              } else {
                // Show farewell modal for downgrades
                PlanFarewellModal.show(context, _lastKnownPlan!, currentPlan);
              }
            }
          });
        }

        // Update the known plan
        _lastKnownPlan = currentPlan;
      }
    } catch (e) {
      _log.e('Error checking for data updates: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
