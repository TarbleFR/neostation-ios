import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';
import 'package:neostation/models/full_theme_definition.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/full_theme_music_service.dart';
import 'package:neostation/services/full_theme_service.dart';
import 'package:neostation/services/home_music_service.dart';
import 'package:neostation/widgets/shimmering_logo.dart';
import '../full_theme/full_theme_systems_view.dart';
import 'my_systems_section/my_systems_grid.dart';
import 'my_systems_section/initial_setup_widget.dart';

/// Orchestrator for the 'Systems' tab content.
///
/// When no full theme is installed this preserves NeoStation's original
/// systems experience (including the user's grid/carousel preference). When a
/// full theme is active, that theme becomes the systems experience outright:
/// it owns the home surface and routes playlists through its own renderer. It
/// is deliberately not represented as another layout mode.
class SystemContent extends StatefulWidget {
  const SystemContent({super.key, this.selectedIndex = 0, this.onCardTapped});

  final int selectedIndex;
  final Function(int index)? onCardTapped;

  @override
  State<SystemContent> createState() => _SystemContentState();
}

class _SystemContentState extends State<SystemContent> {
  static const _minSplashDuration = Duration(milliseconds: 2500);

  DateTime? _splashShownAt;
  Timer? _releaseTimer;
  String? _lastMenuAudioKey;

  @override
  void initState() {
    super.initState();
    unawaited(FullThemeService.instance.initialize());
  }

  @override
  void dispose() {
    _releaseTimer?.cancel();
    unawaited(HomeMusicService().setMainMenuActive(false));
    unawaited(FullThemeMusicService.instance.setHomeVisible(false));
    super.dispose();
  }

  bool _holdSplash(bool isLoading) {
    if (isLoading) {
      _splashShownAt ??= DateTime.now();
      _releaseTimer?.cancel();
      _releaseTimer = null;
      return false;
    }
    final shownAt = _splashShownAt;
    if (shownAt == null) return false;

    final remaining = _minSplashDuration - DateTime.now().difference(shownAt);
    if (remaining <= Duration.zero) {
      _splashShownAt = null;
      return false;
    }
    _releaseTimer ??= Timer(remaining, () {
      if (mounted) setState(() => _splashShownAt = null);
    });
    return true;
  }

  /// Keeps menu audio side effects out of build while making the full theme
  /// authoritative. User-selected NeoStation menu music is disabled while a
  /// full theme owns the home screen; removing the full theme restores the
  /// original behaviour automatically.
  void _syncMenuAudio(bool active, FullThemeDefinition? fullTheme) {
    final key = '${active ? 1 : 0}:${fullTheme?.id ?? 'classic'}';
    if (_lastMenuAudioKey == key) return;
    _lastMenuAudioKey = key;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted && active) return;
      if (fullTheme != null) {
        unawaited(HomeMusicService().setMainMenuActive(false));
        unawaited(
          FullThemeMusicService.instance.setHomeVisible(
            active,
            theme: fullTheme,
          ),
        );
      } else {
        unawaited(FullThemeMusicService.instance.setHomeVisible(false));
        unawaited(HomeMusicService().setMainMenuActive(active));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: FullThemeService.instance.isReady,
      builder: (context, fullThemeReady, _) {
        // Do not briefly expose the classic UI while a stored full theme is
        // still being restored from disk at application start.
        if (!fullThemeReady) {
          return ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const Center(child: ShimmeringLogo()),
          );
        }

        return ValueListenableBuilder<FullThemeDefinition?>(
          valueListenable: FullThemeService.instance.activeTheme,
          builder: (context, fullTheme, _) {
            return Consumer<SqliteConfigProvider>(
              builder: (context, configProvider, child) {
                final isLoading =
                    configProvider.isLoading || configProvider.isScanning;
                final showSplash = isLoading || _holdSplash(isLoading);

                final showInitialSetup =
                    !showSplash &&
                    !configProvider.hasDetectedSystems &&
                    configProvider.scanCompleted;

                final showContent =
                    !showSplash &&
                    configProvider.scanCompleted &&
                    !showInitialSetup;

                final routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
                _syncMenuAudio(showContent && routeIsCurrent, fullTheme);
                final safePadding = MediaQuery.viewPaddingOf(context);
                final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
                final safeLeft = isIOS ? safePadding.left : 0.0;
                final safeRight = isIOS ? safePadding.right : 0.0;

                final Widget phase;
                if (showSplash) {
                  phase = KeyedSubtree(
                    key: const ValueKey('splash'),
                    child: _buildSplash(context, configProvider),
                  );
                } else if (showInitialSetup) {
                  phase = const KeyedSubtree(
                    key: ValueKey('setup'),
                    child: InitialSetupWidget(),
                  );
                } else if (showContent) {
                  if (fullTheme != null) {
                    phase = KeyedSubtree(
                      key: ValueKey('full-theme-${fullTheme.id}'),
                      child: FullThemeSystemsView(
                        theme: fullTheme,
                        selectedIndex: widget.selectedIndex,
                        onCardTapped: widget.onCardTapped,
                      ),
                    );
                  } else {
                    phase = KeyedSubtree(
                      key: const ValueKey('content'),
                      child: MySystems(
                        selectedIndex: widget.selectedIndex,
                        onCardTapped: widget.onCardTapped,
                      ),
                    );
                  }
                } else {
                  phase = const SizedBox.shrink(key: ValueKey('empty'));
                }

                final content = AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: phase,
                );

                // AppScreen owns the classic custom background. A full theme's
                // overlay paints above it and above the global chrome, so this
                // backing surface intentionally remains cheap and inert.
                if (showContent) {
                  return Padding(
                    padding: EdgeInsets.only(left: safeLeft, right: safeRight),
                    child: content,
                  );
                }
                return ColoredBox(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: content,
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildSplash(
    BuildContext context,
    SqliteConfigProvider configProvider,
  ) {
    return Stack(
      children: [
        Center(
          child: ShimmeringLogo(
            progress:
                configProvider.isScanning && configProvider.scanProgress > 0
                ? configProvider.scanProgress
                : null,
          ),
        ),
        if (configProvider.isScanning)
          Align(
            alignment: const Alignment(0, 0.55),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 480),
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 220,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: configProvider.scanProgress,
                        minHeight: 3,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    configProvider.scanStatus.isNotEmpty
                        ? configProvider.scanStatus
                        : AppLocale.scanningSystemsRoms.getString(context),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 17,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
