import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/widgets/setting_row.dart';
import 'package:neostation/services/dolphin_internal_v2_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/enabled_index_nav.dart';
import 'package:neostation/utils/game_utils.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/delete_game_dialog.dart';
import 'package:provider/provider.dart';

/// Manage tab for play-time reset and permanent game deletion.
class GameSettingsManageTab extends StatefulWidget {
  final GameModel game;
  final SystemModel system;
  final FileProvider fileProvider;
  final bool isAllMode;
  final VoidCallback? onGameUpdated;
  final void Function(String romname)? onGameDeleted;

  const GameSettingsManageTab({
    super.key,
    required this.game,
    required this.system,
    required this.fileProvider,
    required this.isAllMode,
    this.onGameUpdated,
    this.onGameDeleted,
  });

  @override
  State<GameSettingsManageTab> createState() => GameSettingsManageTabState();
}

class GameSettingsManageTabState extends State<GameSettingsManageTab> {
  static final _log = LoggerService.instance;

  int _selectedIndex = 0;
  bool _isResettingPlayTime = false;
  bool _isDeleting = false;

  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _itemKeys = {};

  GlobalKey _itemKey(int navIndex) =>
      _itemKeys.putIfAbsent(navIndex, () => GlobalKey());

  int get _playTimeIdx => 0;
  int get _deleteIdx => 1;
  int get _totalItems => 2;

  String get _targetSystemFolder =>
      widget.isAllMode && widget.game.systemFolderName != null
          ? widget.game.systemFolderName!
          : widget.system.folderName;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  bool _isEnabledIndex(int idx) => idx >= 0 && idx < _totalItems;

  void moveUp() {
    setState(() {
      _selectedIndex = previousEnabledIndex(
        _selectedIndex,
        _totalItems,
        _isEnabledIndex,
      );
    });
    _scrollToSelectedItem();
  }

  void moveDown() {
    setState(() {
      _selectedIndex = nextEnabledIndex(
        _selectedIndex,
        _totalItems,
        _isEnabledIndex,
      );
    });
    _scrollToSelectedItem();
  }

  void trigger() {
    if (_selectedIndex == _playTimeIdx) {
      if ((widget.game.playTime ?? 0) > 0 && !_isResettingPlayTime) {
        _confirmResetPlayTime();
      }
    } else if (_selectedIndex == _deleteIdx) {
      _confirmDeleteGame();
    }
  }

  void _scrollToSelectedItem() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _itemKeys[_selectedIndex];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: 0.5,
        );
      }
    });
  }

  Future<void> _confirmResetPlayTime() async {
    SfxService().playNavSound();
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.resetPlayTimeConfirm.getString(context),
      body: AppLocale.resetPlayTimeConfirmBody.getString(context),
      confirmLabel: AppLocale.reset.getString(context),
      icon: Symbols.timer_off_rounded,
    );
    if (confirmed == true && mounted) _resetPlayTime();
  }

  Future<void> _resetPlayTime() async {
    if (_isResettingPlayTime) return;
    setState(() => _isResettingPlayTime = true);
    try {
      await GameRepository.resetPlayTime(
        _targetSystemFolder,
        widget.game.romname,
      );
      widget.onGameUpdated?.call();
      if (mounted) {
        AppNotification.showNotification(
          context,
          'Play time reset',
          type: NotificationType.success,
        );
      }
    } catch (e) {
      _log.e('Play-time reset operation failed: $e');
    } finally {
      if (mounted) setState(() => _isResettingPlayTime = false);
    }
  }

  Future<void> _confirmDeleteGame() async {
    SfxService().playNavSound();
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DeleteGameDialog(
        gameName: widget.game.name,
        romName: widget.game.romname,
      ),
    );
    if (confirmed == true && mounted) _deleteGame();
  }

  Future<void> _deleteGame() async {
    if (_isDeleting) return;
    setState(() => _isDeleting = true);

    final targetSystemId = widget.game.systemId ?? widget.system.id;
    final deletedRomname = widget.game.romname;
    final isDolphinInternal =
        Platform.isIOS &&
        DolphinInternalV2Service.isDolphinSystem(_targetSystemFolder);
    var deleted = false;

    try {
      await GameRepository.deleteGame(
        appSystemId: targetSystemId,
        filename: deletedRomname,
        systemFolderName: _targetSystemFolder,
        romBaseName: deletedRomname,
        romPath: widget.game.romPath,
        fileProvider: widget.fileProvider,
      );

      // GameCube/Wii use NeoStation's private Dolphin playlists rather than a
      // user-selected global ROM root. Refresh that one playlist immediately
      // after the physical image and DB row are removed so no ghost entry is
      // left until the next app scan/restart.
      if (isDolphinInternal && mounted) {
        await context
            .read<SqliteConfigProvider>()
            .refreshDolphinInternalLibrary(_targetSystemFolder);
      }
      deleted = true;
    } catch (e) {
      _log.e('Game deletion failed: $e');
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }

    // Do not remove the card from the visible list when disk/DB deletion did
    // not actually complete. Dolphin refresh above has already synchronized
    // the authoritative playlist before this local UI callback runs.
    if (mounted && deleted) widget.onGameDeleted?.call(deletedRomname);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canReset = (widget.game.playTime ?? 0) > 0 && !_isResettingPlayTime;

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.only(bottom: 24.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              SfxService().playNavSound();
              setState(() => _selectedIndex = _playTimeIdx);
              if (canReset) _confirmResetPlayTime();
            },
            child: SettingRow(
              key: _itemKey(_playTimeIdx),
              focused: _selectedIndex == _playTimeIdx,
              title: AppLocale.playTime.getString(context),
              subtitle: GameUtils.formatPlayTime(widget.game.playTime ?? 0),
              trailing: _isResettingPlayTime
                  ? SizedBox(
                      width: 20.r,
                      height: 20.r,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.onSurface,
                      ),
                    )
                  : Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 8.r,
                        vertical: 3.r,
                      ),
                      decoration: BoxDecoration(
                        color: canReset
                            ? theme.colorScheme.error.withValues(alpha: 0.15)
                            : theme.colorScheme.onSurface.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(4.r),
                        border: Border.all(
                          color: canReset
                              ? theme.colorScheme.error.withValues(alpha: 0.4)
                              : theme.colorScheme.onSurface.withValues(alpha: 0.1),
                          width: 1.r,
                        ),
                      ),
                      child: Text(
                        AppLocale.reset.getString(context),
                        style: TextStyle(
                          fontSize: 11.r,
                          fontWeight: FontWeight.w600,
                          color: canReset
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurface.withValues(alpha: 0.3),
                        ),
                      ),
                    ),
            ),
          ),
          SizedBox(height: 12.r),
          GestureDetector(
            onTap: () {
              SfxService().playNavSound();
              setState(() => _selectedIndex = _deleteIdx);
              _confirmDeleteGame();
            },
            child: SettingRow(
              key: _itemKey(_deleteIdx),
              focused: _selectedIndex == _deleteIdx,
              title: AppLocale.deleteGame.getString(context),
              subtitle: AppLocale.deleteGameSubtitle.getString(context),
              trailing: _isDeleting
                  ? SizedBox(
                      width: 20.r,
                      height: 20.r,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.error,
                      ),
                    )
                  : Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 8.r,
                        vertical: 3.r,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.error.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4.r),
                        border: Border.all(
                          color: theme.colorScheme.error.withValues(alpha: 0.4),
                          width: 1.r,
                        ),
                      ),
                      child: Text(
                        AppLocale.delete.getString(context),
                        style: TextStyle(
                          fontSize: 11.r,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
