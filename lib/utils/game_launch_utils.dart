import 'package:flutter/material.dart';
import '../models/game_model.dart';
import '../models/system_model.dart';
import '../providers/file_provider.dart';
import '../services/game_service.dart';
import '../services/game_launch_manager.dart';
import '../widgets/game_launch_dialog.dart';

/// Standardizes the game launch workflow: Session initialization -> Progress Dialog -> Delay -> Execution -> Monitoring.
///
/// Workflow details:
/// 1. Initializes a new session via [GameLaunchManager].
/// 2. Displays the [GameLaunchDialog] to show loading progress and metadata.
/// 3. Gives the launch route time to paint before execution. Internal Ports use
///    only a short handoff delay; external emulator launches keep the legacy 2s.
///
/// 4. Executes the emulator/game via [GameService.launchGame].
///
/// Responsibility requirements for the caller:
/// - Deactivate gamepad/keyboard navigation BEFORE calling this function.
/// - Implement [onGameClosed] to reactive navigation and refresh application state.
/// - Handle [onLaunchFailed] to display error messages and perform state cleanup.
///
/// Throws:
/// - Exceptions from [GameService.launchGame] are propagated to the caller.
Future<void> launchGameWithDialog({
  required BuildContext context,
  required GameModel game,
  required SystemModel system,
  required FileProvider fileProvider,
  required VoidCallback onGameClosed,
  Future<void> Function(BuildContext context, GameLaunchResult result)?
  onLaunchFailed,
}) async {
  // Open the launch-pending window immediately so a transient app resume during
  // the dialog/handoff can't clear the Now Playing state (see
  // GameService.isGameLaunchInProgress). Closed by _registerGameLaunch on
  // success, or below on failure.
  GameService.beginLaunchPending();
  await GameLaunchManager().beginSession();
  if (!context.mounted) {
    GameService.clearLaunchPending();
    return;
  }

  // Keep ownership of this route across every asynchronous launch step.
  // Touch/back requests go through the manager, which ignores them while
  // launching; they must not dispose the session behind a pending native call.
  final navigator = Navigator.of(context, rootNavigator: true);
  final dialogRoute = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) GameLaunchManager().userDismiss();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => GameLaunchManager().userDismiss(),
        child: SizedBox.expand(
          child: GameLaunchDialog(
            game: game,
            system: system,
            fileProvider: fileProvider,
            onGameClosed: onGameClosed,
          ),
        ),
      ),
    ),
  );
  navigator.push<void>(dialogRoute);

  void closeLaunchDialog() {
    if (dialogRoute.isActive) {
      dialogRoute.navigator?.removeRoute(dialogRoute);
    }
  }

  try {
    // KartPad/DuskLight are in-process native Ports. The old unconditional
    // two-second presentation delay was pure startup latency for them. Keep a
    // single short paint/handoff window, while preserving the legacy delay for
    // external emulator launches.
    final launchPresentationDelay =
        system.folderName.toLowerCase() == 'ports'
            ? const Duration(milliseconds: 150)
            : const Duration(seconds: 2);
    await Future.delayed(launchPresentationDelay);
    if (!context.mounted || !dialogRoute.isActive) {
      GameService.clearLaunchPending();
      closeLaunchDialog();
      return;
    }

    final result = await GameService.launchGame(context, system, game);
    // A late result cannot close another route or update a replacement session.
    if (!dialogRoute.isActive) return;

    if (result.success) {
      GameLaunchManager().onGameStarted(
        emulatorExe: GameService.launchedEmulatorExe,
      );
    } else {
      GameService.clearLaunchPending();
      closeLaunchDialog();
      if (onLaunchFailed != null && context.mounted) {
        await onLaunchFailed(context, result);
      }
    }
  } catch (_) {
    GameService.clearLaunchPending();
    closeLaunchDialog();
    rethrow;
  }
}
