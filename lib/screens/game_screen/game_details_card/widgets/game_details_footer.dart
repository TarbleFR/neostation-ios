import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/app_themes.dart';
import '../../../../models/system_model.dart';
import '../../../../models/game_model.dart';
import '../../../../models/retro_achievements_game_info.dart';
import '../../../../sync/i_sync_provider.dart';
import 'package:neostation/themes/chrome_surface.dart';
import '../../../../themes/corner_radii.dart';
import '../../music/music_player.dart';

/// Sticky action/status footer used by the game details list view.
///
/// The selected game title is intentionally not repeated here because the list
/// panel already owns that identity. Rating and game stats are grouped directly
/// beside PLAY so the footer reads as one compact action cluster.
class GameDetailsFooter extends StatelessWidget {
  final SystemModel system;
  final GameModel game;
  final bool isMusicSystem;
  final bool hasScreenScraper;
  final bool isSecondaryScreenActive;
  final bool cloudSyncEnabled;
  final ISyncProvider syncProvider;
  final AnimationController? syncIconController;
  final VoidCallback onPlayGame;
  final VoidCallback onShowAchievements;
  final bool hasRetroAchievements;
  final bool isLoadingAchievements;
  final GameInfoAndUserProgress? currentGameInfo;

  const GameDetailsFooter({
    super.key,
    required this.system,
    required this.game,
    required this.isMusicSystem,
    required this.hasScreenScraper,
    required this.isSecondaryScreenActive,
    required this.cloudSyncEnabled,
    required this.syncProvider,
    this.syncIconController,
    required this.onPlayGame,
    required this.onShowAchievements,
    required this.hasRetroAchievements,
    required this.isLoadingAchievements,
    this.currentGameInfo,
  });

  @override
  Widget build(BuildContext context) {
    if (isMusicSystem) {
      return Positioned(
        bottom: -0.5.r,
        left: -0.5.r,
        right: -0.5.r,
        child: MusicPlayer(systemColor: system.colorAsColor),
      );
    }

    final hasPlayTime = (game.playTime ?? 0) > 0;
    final hasCombinedStats = hasRetroAchievements || hasPlayTime;

    return Positioned(
      bottom: -0.5.r,
      left: -0.5.r,
      right: -0.5.r,
      height: 61.r,
      child: ClipRRect(
        child: RepaintBoundary(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
            child: ExcludeFocus(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Spacer(),
                  if (game.rating > 0) ...[
                    _SteamStyleRating(game: game),
                    if (hasCombinedStats) SizedBox(width: 5.r),
                  ],
                  if (hasCombinedStats) ...[
                    _CombinedGameStatsPill(
                      game: game,
                      hasRetroAchievements: hasRetroAchievements,
                      isLoadingAchievements: isLoadingAchievements,
                      currentGameInfo: currentGameInfo,
                      onShowAchievements: onShowAchievements,
                    ),
                    SizedBox(width: 8.r),
                  ] else if (game.rating > 0)
                    SizedBox(width: 8.r),
                  _buildPlayButtonCompact(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayButtonCompact(BuildContext context) {
    return Builder(
      builder: (context) {
        final isFocused = Focus.of(context).hasFocus;
        final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();

        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 104.r,
          height: 45.r,
          decoration: BoxDecoration(
            color: isFocused
                ? const Color(0xFF36F184)
                : const Color(0xFF2ECC71),
            borderRadius: radii.radiusExternal,
            border: Border.all(color: const Color(0xFF36F184), width: 1.r),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.1),
                blurRadius: 4.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.white.withValues(alpha: 0.1),
              borderRadius: radii.radiusExternal,
              onTap: () {
                SfxService().playEnterSound();
                onPlayGame();
              },
              child: Padding(
                padding: EdgeInsets.only(right: 10.r),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Image.asset(
                      'assets/images/gamepad/Xbox_A_button.png',
                      width: 32.r,
                      height: 32.r,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                    SizedBox(width: 8.r),
                    Text(
                      AppLocale.playButton.getString(context),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary,
                        fontWeight: FontWeight.w900,
                        fontSize: 14.r,
                        letterSpacing: 1.5,
                        height: 1.0,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One compact surface for the RetroAchievements game avatar and accumulated
/// play time. This replaces the previous separate RA and play-time pills so the
/// avatar can never spill visually between containers.
class _CombinedGameStatsPill extends StatelessWidget {
  final GameModel game;
  final bool hasRetroAchievements;
  final bool isLoadingAchievements;
  final GameInfoAndUserProgress? currentGameInfo;
  final VoidCallback onShowAchievements;

  const _CombinedGameStatsPill({
    required this.game,
    required this.hasRetroAchievements,
    required this.isLoadingAchievements,
    required this.currentGameInfo,
    required this.onShowAchievements,
  });

  String _formatClock(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${pad(h)}:${pad(m)}:${pad(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final playTime = game.playTime ?? 0;
    final hasPlayTime = playTime > 0;

    final gameIconUrl = currentGameInfo?.imageIcon.isNotEmpty == true
        ? 'https://media.retroachievements.org${currentGameInfo!.imageIcon}'
        : null;

    final content = Container(
      height: 45.r,
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: ChromeSurface.fill(context),
        borderRadius: radii.radiusExternal,
        border: Border.all(color: theme.colorScheme.outline, width: 1.r),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.1),
            blurRadius: 4.r,
            offset: Offset(2.r, 2.r),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (hasRetroAchievements)
            ClipRRect(
              borderRadius: radii.radiusInternal,
              child: Container(
                width: 32.r,
                height: 32.r,
                color: theme.colorScheme.surface,
                alignment: Alignment.center,
                child: gameIconUrl != null
                    ? Image.network(
                        gameIconUrl,
                        fit: BoxFit.cover,
                        width: 32.r,
                        height: 32.r,
                        errorBuilder: (_, _, _) => Icon(
                          Symbols.emoji_events_rounded,
                          color: Colors.orange,
                          size: 17.r,
                        ),
                      )
                    : isLoadingAchievements
                    ? SizedBox(
                        width: 16.r,
                        height: 16.r,
                        child: const CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    : Icon(
                        Symbols.emoji_events_rounded,
                        color: Colors.orange,
                        size: 17.r,
                      ),
              ),
            ),
          if (hasRetroAchievements && hasPlayTime) ...[
            SizedBox(width: 8.r),
            Container(
              width: 1.r,
              height: 28.r,
              color: theme.colorScheme.outline.withValues(alpha: 0.45),
            ),
            SizedBox(width: 8.r),
          ],
          if (hasPlayTime)
            Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Symbols.schedule_rounded,
                  color: theme.colorScheme.onSurface,
                  size: 14.r,
                ),
                SizedBox(height: 1.r),
                Text(
                  _formatClock(playTime),
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontSize: 10.r,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
        ],
      ),
    );

    if (!hasRetroAchievements) return content;

    return Material(
      color: Colors.transparent,
      borderRadius: radii.radiusExternal,
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          onShowAchievements();
        },
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        borderRadius: radii.radiusExternal,
        child: content,
      ),
    );
  }
}

/// Steam-inspired rating badge, kept as a separate score surface.
class _SteamStyleRating extends StatelessWidget {
  final GameModel game;

  const _SteamStyleRating({required this.game});

  @override
  Widget build(BuildContext context) {
    final ratingValue = (game.rating / 2).clamp(0.0, 10.0);
    final colorRatio = (ratingValue - 1) / 9;
    final customColors = AppThemes.getCustomColors(context);
    final ratingColor = Color.lerp(
      customColors.errorColor,
      customColors.successColor,
      colorRatio,
    )!;
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();

    return Container(
      height: 45.r,
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: ChromeSurface.fill(context),
        borderRadius: radii.radiusExternal,
        border: Border.all(
          color: Theme.of(context).colorScheme.outline,
          width: 1.r,
        ),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.1),
            blurRadius: 4.r,
            offset: Offset(2.r, 2.r),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Symbols.star_rounded, color: ratingColor, size: 24.r),
          SizedBox(width: 4.r),
          Stack(
            alignment: Alignment.centerLeft,
            children: [
              Opacity(
                opacity: 0,
                child: Text(
                  '10',
                  style: TextStyle(fontSize: 22.r, fontWeight: FontWeight.w900),
                ),
              ),
              Text(
                ratingValue.toStringAsFixed(0),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 22.r,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
