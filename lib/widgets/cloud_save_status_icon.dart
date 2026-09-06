import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/game_model.dart';
import '../models/cloud_save_models.dart';
import '../models/system_model.dart';
import '../sync/i_sync_provider.dart';
import '../themes/corner_radii.dart';

/// Compact icon-only iCloud Saves status indicator.
///
/// Renders a small descriptive icon whose color reflects the current cloud
/// synchronization state for the selected game. No text is shown, making it
/// suitable for tight spaces such as the left action column in the game list.
class CloudSaveStatusIcon extends StatefulWidget {
  final SystemModel system;
  final GameModel? game;
  final ISyncProvider syncProvider;
  final double size;

  const CloudSaveStatusIcon({
    super.key,
    required this.system,
    required this.game,
    required this.syncProvider,
    this.size = 24.0,
  });

  @override
  State<CloudSaveStatusIcon> createState() => _CloudSaveStatusIconState();
}

class _CloudSaveStatusIconState extends State<CloudSaveStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.system.folderName == 'android') return const SizedBox.shrink();
    if (!widget.syncProvider.isAuthenticated) return const SizedBox.shrink();

    final game = widget.game;
    if (game == null) return const SizedBox.shrink();

    final status = _resolveStatus();
    if (status.isSyncing && !_rotationController.isAnimating) {
      _rotationController.repeat();
    } else if (!status.isSyncing && _rotationController.isAnimating) {
      _rotationController.stop();
    }

    final theme = Theme.of(context);
    final cornerRadius =
        theme.extension<CornerRadii>()?.radiusInternal ??
        BorderRadius.circular(8.r);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: widget.size.r,
      height: widget.size.r,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: cornerRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 2.r,
            offset: Offset(2.0.r, 2.0.r),
          ),
        ],
      ),
      child: Center(
        child: AnimatedBuilder(
          animation: _rotationController,
          builder: (context, child) {
            return Transform.rotate(
              angle: status.icon == Symbols.sync_rounded
                  ? _rotationController.value * 2 * 3.14159
                  : 0,
              child: child,
            );
          },
          child: Icon(
            status.icon,
            color: status.color,
            size: (widget.size * 0.6).r,
          ),
        ),
      ),
    );
  }

  _CloudSaveStatus _resolveStatus() {
    final game = widget.game!;
    final cloudSyncEnabled = game.cloudSyncEnabled ?? true;
    final gameState = widget.syncProvider.getGameSyncState('${widget.system.folderName}/${game.romname}');
    final isSyncing = gameState?.status == GameSyncStatus.syncing;

    if (!cloudSyncEnabled) {
      return _CloudSaveStatus(
        icon: Symbols.cloud_off_rounded,
        color: Theme.of(context).colorScheme.onSurface,
        isSyncing: false,
      );
    }
    if (isSyncing) {
      return _CloudSaveStatus(
        icon: Symbols.sync_rounded,
        color: Colors.lightBlue,
        isSyncing: true,
      );
    }
    // An account-level audit or another game must not override this game
    // whose own save comparison/transfer has already produced a result.

    if (gameState != null) {
      switch (gameState.status) {
        case GameSyncStatus.upToDate:
          return _CloudSaveStatus(
            icon: Symbols.check_circle_outline_rounded,
            color: const Color(0xFF79AA41),
            isSyncing: false,
          );
        case GameSyncStatus.localOnly:
          return _CloudSaveStatus(
            icon: Symbols.cloud_upload_rounded,
            color: Colors.orange,
            isSyncing: false,
          );
        case GameSyncStatus.cloudOnly:
          return _CloudSaveStatus(
            icon: Symbols.cloud_download_rounded,
            color: Colors.lightBlue,
            isSyncing: false,
          );
        case GameSyncStatus.syncing:
          return _CloudSaveStatus(
            icon: Symbols.sync_rounded,
            color: Colors.lightBlue,
            isSyncing: true,
          );
        case GameSyncStatus.pending:
          return _CloudSaveStatus(
            icon: Symbols.schedule_rounded, color: Colors.orange, isSyncing: false,
          );
        case GameSyncStatus.disabled:
          return _CloudSaveStatus(
            icon: Symbols.cloud_off_rounded,
            color: Colors.grey,
            isSyncing: false,
          );
        case GameSyncStatus.quotaExceeded:
          return _CloudSaveStatus(
            icon: Symbols.storage_rounded,
            color: Colors.redAccent,
            isSyncing: false,
          );
        case GameSyncStatus.noSaveFound:
          return _CloudSaveStatus(
            icon: Symbols.save_alt_rounded,
            color: Colors.grey,
            isSyncing: false,
          );
        case GameSyncStatus.missingEmulator:
          return _CloudSaveStatus(
            icon: Symbols.videogame_asset_off_rounded,
            color: Colors.orange,
            isSyncing: false,
          );
        case GameSyncStatus.error:
          return _CloudSaveStatus(
            icon: Symbols.error_outline_rounded,
            color: Colors.red,
            isSyncing: false,
          );
      }
    }



    return _CloudSaveStatus(
      icon: Symbols.schedule_rounded,
      color: Colors.grey,
      isSyncing: false,
    );
  }
}

class _CloudSaveStatus {
  final IconData icon;
  final Color color;
  final bool isSyncing;

  const _CloudSaveStatus({
    required this.icon,
    required this.color,
    required this.isSyncing,
  });
}
