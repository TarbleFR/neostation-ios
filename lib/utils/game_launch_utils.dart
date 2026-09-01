import 'dart:io';

import 'package:flutter/material.dart';
import '../models/game_model.dart';
import '../models/system_model.dart';
import '../providers/file_provider.dart';
import '../sync/i_sync_provider.dart';
import '../services/game_service.dart';
import '../services/game_launch_manager.dart';
import '../services/game_session_persistence.dart';
import '../widgets/game_launch_dialog.dart';

/// Standardizes the game launch workflow: Session initialization -> Progress Dialog -> Delay -> Execution -> Monitoring.
///
/// Workflow details:
/// 1. Initializes a new session via [GameLaunchManager].
/// 2. Displays the [GameLaunchDialog] to show loading progress and metadata.
/// 3. Introduces a brief delay (2s) to ensure the UI has settled and provide feedback.
/// 4. Executes the emulator/game via [GameService.launchGame].
///
/// Responsibility requirements for the caller:
/// - Deactivate gamepad/keyboard navigation BEFORE calling this function.
/// - Implement [onGameClosed] to reactive navigation and refresh application state (DB, sync status, etc.).
/// - Handle [onLaunchFailed] to display error messages and perform state cleanup.
///
/// Throws:
/// - Exceptions from [GameService.launchGame] are propagated to the caller.
Future<void> launchGameWithDialog({
  required BuildContext context,
  required GameModel game,
  required SystemModel system,
  required FileProvider fileProvider,
  required ISyncProvider syncProvider,
  required VoidCallback onGameClosed,
  Future<void> Function(BuildContext context, GameLaunchResult result)?
  onLaunchFailed,
}) async {
  // iOS keeps NeoStation suspended behind external emulators. Release decoded
  // artwork before the handoff so memory-heavy apps such as ARMSX2 have more
  // headroom and iOS is less likely to reclaim NeoStation.
  if (Platform.isIOS) {
    imageCache.clear();
    imageCache.clearLiveImages();
  }

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

  // Display the launch overlay.
  showDialog(
    context: context,
    barrierDismissible: true,
    builder: (_) => GameLaunchDialog(
      game: game,
      system: system,
      fileProvider: fileProvider,
      syncProvider: syncProvider,
      onGameClosed: onGameClosed,
    ),
  );

  // Artificial delay for UX consistency and asset loading.
  await Future.delayed(const Duration(seconds: 2));
  if (!context.mounted) {
    GameService.clearLaunchPending();
    return;
  }

  // Persist the full iOS game identity BEFORE native ARMSX2/StikJIT can move
  // NeoStation to the background. This write is intentionally awaited: if iOS
  // jetsams NeoStation while the emulator is running, the new process must know
  // exactly which game's save NeoSync has to upload.
  if (Platform.isIOS) {
    await GameSessionPersistence.saveGameSession(
      systemFolderName: system.folderName,
      filename: game.romname,
      startTimestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  late final GameLaunchResult result;
  try {
    result = await GameService.launchGame(context, system, game);
  } catch (_) {
    if (Platform.isIOS) {
      await GameSessionPersistence.clearGameSession();
    }
    rethrow;
  }

  if (result.success) {
    // Notify manager to begin background process monitoring. On success
    // _registerGameLaunch has already closed the launch-pending window
    // (isGameLaunched now covers it).
    GameLaunchManager().onGameStarted(
      emulatorExe: GameService.launchedEmulatorExe,
    );
  } else {
    // A failed iOS handoff must not leave a stale cold-return recovery record.
    if (Platform.isIOS) {
      await GameSessionPersistence.clearGameSession();
    }

    // Clean up session and close dialog on failure.
    GameService.clearLaunchPending();
    GameLaunchManager().onDialogDisposed();
    if (context.mounted) Navigator.of(context).pop();
    if (onLaunchFailed != null && context.mounted) {
      await onLaunchFailed(context, result);
    }
  }
}
