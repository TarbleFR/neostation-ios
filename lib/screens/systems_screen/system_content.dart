import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/home_music_service.dart';
import 'package:neostation/widgets/shimmering_logo.dart';
import 'my_systems_section/my_systems_grid.dart';
import 'my_systems_section/initial_setup_widget.dart';

/// Orchestrator for the 'Systems' tab content.
///
/// The optional user-selected custom background is deliberately rendered only
/// behind the primary systems grid/carousel. Game playlists are pushed as new
/// routes and therefore keep their existing backgrounds unchanged.
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
  Timer? _startupPhaseProbeTimer;
  bool? _lastHomeMusicActive;

  @override
  void dispose() {
    _releaseTimer?.cancel();
    _startupPhaseProbeTimer?.cancel();
    unawaited(HomeMusicService().setMainMenuActive(false));
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

  /// The deferred startup-scan flag is consumed by AppScreen without notifying
  /// this provider listener. Normally scanSystems() immediately follows and
  /// emits its own notification, but an iOS emulator return intentionally skips
  /// that scan. Re-check the phase shortly after the first frame so a cached
  /// library can be revealed instead of remaining on an empty phase forever.
  void _scheduleStartupPhaseProbe(bool needed) {
    if (!needed) {
      _startupPhaseProbeTimer?.cancel();
      _startupPhaseProbeTimer = null;
      return;
    }
    if (_startupPhaseProbeTimer != null) return;

    _startupPhaseProbeTimer = Timer(const Duration(milliseconds: 120), () {
      _startupPhaseProbeTimer = null;
      if (mounted) setState(() {});
    });
  }

  /// Keeps audio side effects outside build while still following route
  /// visibility. A pushed game library leaves this widget mounted underneath,
  /// so checking [ModalRoute.isCurrent] is what prevents ambience from leaking
  /// beyond the main console-selection screen.
  void _syncHomeMusic(bool active) {
    if (_lastHomeMusicActive == active) return;
    _lastHomeMusicActive = active;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted && active) return;
      unawaited(HomeMusicService().setMainMenuActive(active));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SqliteConfigProvider>(
      builder: (context, configProvider, child) {
        final isIOS = defaultTargetPlatform == TargetPlatform.iOS;

        // On a normal startup this probe is superseded immediately by the
        // scan's provider notification. On an iOS return where AppScreen skips
        // scanning, it supplies the one rebuild needed after consumeStartupScan.
        _scheduleStartupPhaseProbe(
          isIOS && configProvider.pendingStartupScan,
        );

        final isLoading = configProvider.isLoading || configProvider.isScanning;
        final showSplash = isLoading || _holdSplash(isLoading);

        final showInitialSetup =
            !showSplash &&
            !configProvider.hasDetectedSystems &&
            configProvider.scanCompleted;

        // A cached iOS library is authoritative after returning from an
        // external emulator. AppScreen consumes the one-shot return marker and
        // intentionally does not call scanSystems(); in that path scanCompleted
        // remains false because no scan ran. If systems already exist in SQLite,
        // show them directly rather than interpreting "no scan" as "no UI".
        final canReuseCachedIosLibrary =
            isIOS &&
            !showSplash &&
            configProvider.hasDetectedSystems &&
            !configProvider.pendingStartupScan &&
            !configProvider.isScanningRoms &&
            !configProvider.isSilentScanning;

        final showContent =
            !showSplash &&
            !showInitialSetup &&
            (configProvider.scanCompleted || canReuseCachedIosLibrary);

        final routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
        _syncHomeMusic(showContent && routeIsCurrent);
        final safePadding = MediaQuery.viewPaddingOf(context);
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
          phase = KeyedSubtree(
            key: const ValueKey('content'),
            child: MySystems(
              selectedIndex: widget.selectedIndex,
              onCardTapped: widget.onCardTapped,
            ),
          );
        } else {
          phase = const SizedBox.shrink(key: ValueKey('empty'));
        }

        final content = AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: phase,
        );

        // AppScreen owns the custom background so it stays mounted across
        // top-level tab changes. During splash/setup phases, cover that
        // persistent layer with the normal theme background. The actual
        // Systems content remains transparent so the custom image shows through.
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
