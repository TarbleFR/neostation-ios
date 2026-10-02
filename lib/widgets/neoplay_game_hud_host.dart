import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:neoplay_bridge/neoplay_bridge.dart';
import 'package:neostation/l10n/neoplay_companion_locale.dart';
import 'package:neostation/services/game_launch_manager.dart';

/// Observes the existing game lifecycle; never drives it or starts streaming.
class NeoPlayGameHUDHost extends StatefulWidget {
  const NeoPlayGameHUDHost({super.key, required this.child, this.stateSource, this.isGameActive});
  final Widget child;
  final Listenable? stateSource;
  final bool Function()? isGameActive;
  @override
  State<NeoPlayGameHUDHost> createState() => _NeoPlayGameHUDHostState();
}
class _NeoPlayGameHUDHostState extends State<NeoPlayGameHUDHost> {
  late final Listenable source;
  Future<void> pending = Future<void>.value();
  Map<String,String>? labels;
  Map<String,String>? lastLabels;
  bool? lastActive;
  bool get enabled => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  @override
  void initState() { super.initState(); source = widget.stateSource ?? GameLaunchManager(); if (enabled) source.addListener(update); }
  @override
  void didChangeDependencies() { super.didChangeDependencies(); labels = NeoPlayCompanionLocale.forLocale(Localizations.localeOf(context)); update(); }
  void update() {
    if (!enabled || labels == null) return;
    final manager = GameLaunchManager();
    final active = widget.isGameActive?.call() ?? (manager.phase == GameLaunchPhase.playing && manager.closeRouteImmediately);
    if (active == lastActive && identical(labels,lastLabels)) return;
    lastActive = active; lastLabels = labels; send(active,labels!);
  }
  void send(bool active, Map<String,String> strings) {
    pending = pending.then((_) => NeoPlayBridge.configureGameHUD(active:active,labels:strings)).catchError((Object error) {
      debugPrint('NeoPlay game HUD unavailable: ${error.runtimeType}');
    });
    unawaited(pending); // Optional UI must not delay launch, audio handoff or shutdown.
  }
  @override
  void dispose() { if (enabled) { source.removeListener(update); if (labels != null) send(false,labels!); } super.dispose(); }
  @override
  Widget build(BuildContext context) => widget.child;
}
