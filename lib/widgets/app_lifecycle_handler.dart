import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/services/music_player_service.dart';
import 'package:provider/provider.dart';

/// Restores input, audio, and secondary-display state when NeoStation resumes.
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
    GameService.onScreenStateChanged = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
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
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      MusicPlayerService().appPaused();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
