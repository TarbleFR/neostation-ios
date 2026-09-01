import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/file_provider.dart';
import '../providers/neo_sync_provider.dart';
import '../repositories/system_repository.dart';
import '../screens/game_screen/my_games_list.dart';
import '../services/armsx2_return_state_service.dart';
import '../services/config_service.dart';
import '../services/game_session_persistence.dart';
import '../services/logger_service.dart';
import '../sync/providers/neo_sync_adapter.dart';
import '../sync/sync_manager.dart';

/// iOS-only recovery layer for ARMSX2.
///
/// ARMSX2 can cause iOS to reclaim NeoStation while gameplay is in the
/// foreground. When that happens, the normal Flutter navigation stack and
/// per-game NeoSync state no longer exist. This coordinator restores the user
/// directly into the PS2 library and replays NeoSync from ARMSX2's dedicated
/// save root instead of depending on the previous in-memory game object.
class Armsx2ColdReturnCoordinator extends StatefulWidget {
  const Armsx2ColdReturnCoordinator({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  State<Armsx2ColdReturnCoordinator> createState() =>
      _Armsx2ColdReturnCoordinatorState();
}

class _Armsx2ColdReturnCoordinatorState
    extends State<Armsx2ColdReturnCoordinator> {
  static final _log = LoggerService.instance;

  bool _started = false;
  bool _ps2RoutePushed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_recoverColdReturn());
    });
  }

  Future<void> _recoverColdReturn() async {
    if (_started || !Platform.isIOS || !mounted) return;
    _started = true;

    final pendingReturn =
        await Armsx2ReturnStateService.hasPendingLibraryReturn();
    final pendingSync = await Armsx2ReturnStateService.hasPendingSync();
    if (!pendingReturn && !pendingSync) return;

    final hadActiveGameSession = await GameSessionPersistence.hasActiveSession();

    // A persisted active session plus the ARMSX2 marker means this process was
    // reconstructed after the emulator handoff. Clear the old per-game record
    // before AppLifecycleHandler's delayed generic recovery can consume it: the
    // ARMSX2 path below does not need a GameModel and therefore survives library
    // reinitialization much more reliably.
    if (hadActiveGameSession) {
      await GameSessionPersistence.clearActiveGameSession();
    }

    if (pendingReturn && hadActiveGameSession) {
      await _restorePs2Library();
    } else if (pendingReturn && !hadActiveGameSession) {
      // This is a stale marker left by a warm return whose normal lifecycle
      // already completed. Never force PS2 on an unrelated later app launch.
      await Armsx2ReturnStateService.clearPendingLibraryReturn();
    }

    if (pendingSync) {
      unawaited(_syncPendingArmsx2Saves());
    }
  }

  Future<void> _restorePs2Library() async {
    if (_ps2RoutePushed || !mounted) return;

    var system = await SystemRepository.getSystemByFolderName('ps2');
    for (var attempt = 0; system == null && attempt < 12; attempt++) {
      await Future.delayed(const Duration(milliseconds: 150));
      system = await SystemRepository.getSystemByFolderName('ps2');
    }

    if (!mounted || system == null) {
      _log.w(
        'ARMSX2 cold return: PS2 system is not ready; keeping return marker.',
      );
      return;
    }

    final fileProvider = Provider.of<FileProvider>(context, listen: false);
    _ps2RoutePushed = true;

    try {
      final routeFuture = Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => SystemGamesList(
            system: system!,
            fileProvider: fileProvider,
          ),
        ),
      );

      // The route has been accepted by Navigator. Consume only the navigation
      // marker; NeoSync owns its own independent pending flag.
      await Armsx2ReturnStateService.clearPendingLibraryReturn();
      unawaited(routeFuture);
      _log.i('ARMSX2 cold return: restored PS2 game library.');
    } catch (e) {
      _ps2RoutePushed = false;
      _log.e('ARMSX2 cold return: failed to restore PS2 library: $e');
    }
  }

  Future<void> _syncPendingArmsx2Saves() async {
    if (!mounted ||
        !await Armsx2ReturnStateService.hasPendingSync()) {
      return;
    }

    final syncProvider = Provider.of<SyncManager>(context, listen: false).active;
    if (syncProvider == null ||
        syncProvider.providerId != NeoSyncAdapter.kProviderId ||
        !syncProvider.isAuthenticated) {
      _log.i(
        'ARMSX2 cold return: NeoSync not ready/authenticated; sync marker retained.',
      );
      return;
    }

    final armsx2Root = ConfigService.linkedArmsx2SaveFolderPath;
    if (armsx2Root == null ||
        armsx2Root.isEmpty ||
        !Directory(armsx2Root).existsSync()) {
      _log.w(
        'ARMSX2 cold return: dedicated NeoSync folder unavailable; marker retained.',
      );
      return;
    }

    final neoSync = Provider.of<NeoSyncProvider>(context, listen: false);

    // Avoid colliding with an initialization sync. Retry for a few seconds; if
    // another task is still active, leave the marker for the next resume/start.
    for (var attempt = 0; neoSync.isSyncing && attempt < 8; attempt++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (neoSync.isSyncing) {
      _log.i('ARMSX2 cold return: NeoSync busy; marker retained for retry.');
      return;
    }

    try {
      // autoSyncUploads already has an iOS-native ARMSX2 branch: it enumerates
      // the linked memcards/savestates/sstates root and routes each file through
      // _uploadArmsx2File with system=ps2, emulator=armsx2, scope=shared.
      await neoSync.autoSyncUploads();

      if (neoSync.error == null) {
        await Armsx2ReturnStateService.clearPendingSync();
        _log.i(
          'ARMSX2 cold return: dedicated save-root NeoSync pass completed.',
        );
      } else {
        _log.w(
          'ARMSX2 cold return: NeoSync reported ${neoSync.error}; marker retained.',
        );
      }
    } catch (e) {
      _log.e('ARMSX2 cold return: NeoSync pass failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
