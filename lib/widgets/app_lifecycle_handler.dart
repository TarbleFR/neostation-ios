import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/services/local_jit_tunnel_service.dart';
import 'package:neostation/services/music_player_service.dart';
import 'package:provider/provider.dart';

/// Restores input, audio, and secondary-display state when NeoStation resumes.
/// On iOS it also enforces the session-only lifetime of NeoStationLocalTunnel.
class AppLifecycleHandler extends StatefulWidget {
  final Widget child;

  const AppLifecycleHandler({super.key, required this.child});

  @override
  State<AppLifecycleHandler> createState() => _AppLifecycleHandlerState();
}

class _AppLifecycleHandlerState extends State<AppLifecycleHandler>
    with WidgetsBindingObserver {
  AppLifecycleListener? _exitListener;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _exitListener = AppLifecycleListener(
      onExitRequested: () async {
        if (Platform.isIOS) {
          await LocalJitTunnelService.stopForLifecycle(
            reason: 'normal app exit',
          );
        }
        try {
          MusicPlayerService().dispose();
        } catch (_) {}
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _exitListener?.dispose();
    if (Platform.isIOS) {
      unawaited(
        LocalJitTunnelService.stopForLifecycle(reason: 'lifecycle disposed'),
      );
    }
    GameService.onScreenStateChanged = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      // Begin route selection immediately. This probes an existing external
      // LocalDevVPN route before deciding whether NeoStationLocalTunnel is
      // needed, while the rest of resume housekeeping proceeds normally.
      if (Platform.isIOS) {
        unawaited(
          LocalJitTunnelService.refreshInBackground(reason: 'app resume'),
        );
      }

      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await GameService.handleAppResumed();
      if (!mounted) return;

      if (Platform.isAndroid) {
        final configProvider = Provider.of<SqliteConfigProvider>(
          context,
          listen: false,
        );
        configProvider.reapplySecondaryDisplay();
        // ignore: unawaited_futures
        configProvider.refreshSecondaryScreenshotAccess();
      }

      MusicPlayerService().appResumed();
      return;
    }

    // NeoStationLocalTunnel is strictly foreground-session scoped. Inactive is
    // intentionally included (not only paused/hidden) so a scene losing active
    // status invalidates an in-flight activation before it can reconnect late.
    if (Platform.isIOS &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached)) {
      unawaited(
        LocalJitTunnelService.stopForLifecycle(
          reason: 'app lifecycle ${state.name}',
        ),
      );
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      MusicPlayerService().appPaused();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
