import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../providers/icloud_save_provider.dart';
import '../services/game_service.dart';
import '../services/music_player_service.dart';
import '../providers/sqlite_config_provider.dart';
import 'package:provider/provider.dart';

/// Widget that detects when the app returns to the foreground and reactivates the gamepad
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

    // Register exit listener to clean up native resources (SoLoud audio threads)
    // so the process exits cleanly when the window is closed.
    _exitListener = AppLifecycleListener(
      onExitRequested: () async {
        try {
          MusicPlayerService().dispose();
        } catch (_) {}
        return AppExitResponse.exit;
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await context.read<ICloudSaveProvider>().onAppStart();
    });
  }

  @override
  void dispose() {
    _exitListener?.dispose();
    GameService.onScreenStateChanged = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      // iOS can keep the system IME visible across app switches even when
      // NeoStation has no active text field. Clear Flutter focus and explicitly
      // dismiss the text-input channel before restoring the rest of the app.
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');

      await GameService.handleAppResumed();

      if (!mounted) return;

      // Re-apply secondary display preference after display reconnection.
      if (Platform.isAndroid) {
        final configProvider = Provider.of<SqliteConfigProvider>(
          context,
          listen: false,
        );
        configProvider.reapplySecondaryDisplay();
        // Re-push accessibility (Screen Return) state to the secondary display:
        // the user may have just enabled it in system Settings (e.g. via the
        // in-game launcher's nudge), which controls the screenshot button and
        // the launcher's warning badge.
        // ignore: unawaited_futures
        configProvider.refreshSecondaryScreenshotAccess();
      }

      MusicPlayerService().appResumed();

      await _checkForDataUpdates();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (!mounted) return;
      MusicPlayerService().appPaused();
    }
  }

  Future<void> _checkForDataUpdates() async {
    if (mounted) await context.read<ICloudSaveProvider>().onAppStart();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
