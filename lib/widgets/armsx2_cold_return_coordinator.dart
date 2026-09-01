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
/// Normal behavior is still a warm return, just like the other emulators. This
/// widget exists only as a safety net when iOS actually reconstructs NeoStation:
/// it restores the PS2 library and performs an ARMSX2-only NeoSync upload pass.
/// It must never scan or upload RetroArch, MeloNX or RPCS3 data.
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

    // The persisted game identity is only used here to prove that this is a
    // genuine emulator cold return. ARMSX2 NeoSync itself does not need to
    // reconstruct a GameModel because PS2 memory cards are shared storage.
    if (hadActiveGameSession) {
      await GameSessionPersistence.clearActiveGameSession();
    }

    if (pendingReturn && hadActiveGameSession) {
      unawaited(_restorePs2Library());
    } else if (pendingReturn && !hadActiveGameSession) {
      // A warm return already kept the normal navigation stack alive. Do not
      // force PS2 during an unrelated future launch.
      await Armsx2ReturnStateService.clearPendingLibraryReturn();
    }

    if (pendingSync && hadActiveGameSession) {
      unawaited(_syncPendingArmsx2Saves());
    } else if (pendingSync && !hadActiveGameSession) {
      // The normal warm-return pipeline owns the save in this case. Avoid a
      // stale marker firing a standalone-emulator scan on a later cold launch.
      await Armsx2ReturnStateService.clearPendingSync();
    }
  }

  Future<void> _restorePs2Library() async {
    if (_ps2RoutePushed || !mounted) return;

    // Cold startup can still be restoring SQLite/config providers. Give the PS2
    // system up to ten seconds to become available instead of falling back to
    // the main menu after a short fixed delay.
    var system = await SystemRepository.getSystemByFolderName('ps2');
    for (var attempt = 0; system == null && attempt < 40; attempt++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
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

      await Armsx2ReturnStateService.clearPendingLibraryReturn();
      unawaited(routeFuture);
      _log.i('ARMSX2 cold return: restored PS2 game library.');
    } catch (e) {
      _ps2RoutePushed = false;
      _log.e('ARMSX2 cold return: failed to restore PS2 library: $e');
    }
  }

  Future<void> _syncPendingArmsx2Saves() async {
    if (!mounted || !await Armsx2ReturnStateService.hasPendingSync()) {
      return;
    }

    // Authentication and SyncManager are rebuilt during a cold start. Wait for
    // them instead of trying once at ~500 ms and silently retaining the marker.
    var ready = false;
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!mounted) return;
      final provider = Provider.of<SyncManager>(context, listen: false).active;
      if (provider != null &&
          provider.providerId == NeoSyncAdapter.kProviderId &&
          provider.isAuthenticated) {
        ready = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (!ready || !mounted) {
      _log.i(
        'ARMSX2 cold return: NeoSync not ready/authenticated; sync marker retained.',
      );
      return;
    }

    // The security-scoped bookmark can also finish restoring after the first
    // frame. Wait briefly for the dedicated ARMSX2 root to become reachable.
    String? armsx2Root;
    for (var attempt = 0; attempt < 20; attempt++) {
      armsx2Root = ConfigService.linkedArmsx2SaveFolderPath;
      if (armsx2Root != null &&
          armsx2Root.isNotEmpty &&
          Directory(armsx2Root).existsSync()) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }

    if (armsx2Root == null ||
        armsx2Root.isEmpty ||
        !Directory(armsx2Root).existsSync()) {
      _log.w(
        'ARMSX2 cold return: dedicated NeoSync folder unavailable; marker retained.',
      );
      return;
    }

    final neoSync = Provider.of<NeoSyncProvider>(context, listen: false);

    // Avoid colliding with the provider's startup work.
    for (var attempt = 0; neoSync.isSyncing && attempt < 20; attempt++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (neoSync.isSyncing) {
      _log.i('ARMSX2 cold return: NeoSync busy; marker retained for retry.');
      return;
    }

    try {
      // Critical isolation rule: NEVER call autoSyncUploads() here. That global
      // method also enumerates MeloNX/RetroArch/RPCS3 and caused a Switch save to
      // be uploaded after playing The Hobbit. This call sees ARMSX2 only.
      final completed = await neoSync.autoSyncArmsx2UploadsOnly();

      if (completed) {
        await Armsx2ReturnStateService.clearPendingSync();
        _log.i(
          'ARMSX2 cold return: ARMSX2-only NeoSync pass completed.',
        );
      } else {
        _log.w(
          'ARMSX2 cold return: ARMSX2-only NeoSync did not complete; marker retained.',
        );
      }
    } catch (e) {
      _log.e('ARMSX2 cold return: NeoSync pass failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
