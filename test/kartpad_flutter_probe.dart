import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const channel = MethodChannel('probe');
int frames = 0;
final navigatorKey = GlobalKey<NavigatorState>();
Completer<void>? ended;
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky, overlays: []);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  channel.setMethodCallHandler((call) async {
    if (call.method == 'sessionEnded') {
      if (call.arguments['success'] != true) {
        ended?.completeError(StateError('${call.arguments}'));
      } else {
        ended?.complete();
      }
    }
  });
  runApp(MaterialApp(navigatorKey: navigatorKey,
      home: const Scaffold(body: Center(child: Text('KartPad Flutter lifecycle probe')))));
  WidgetsBinding.instance.addPostFrameCallback((_) => runProbe());
}

Future<void> runProbe() async {
  final ticker = WidgetsBinding.instance;
  void count(Duration _) {
    frames++;
    ticker.addPostFrameCallback(count);
  }
  ticker.addPostFrameCallback(count);
  ticker.scheduleFrame();
  try {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    for (var cycle = 0; cycle < 5; cycle++) {
      await channel.invokeMethod('before', {'cycle': cycle, 'frames': frames});
      final route = DialogRoute<void>(
        context: navigatorKey.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Launching game')),
      );
      navigatorKey.currentState!.push(route);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await channel.invokeMethod('async_identity', {'cycle': cycle});
      ended = Completer<void>();
      await channel.invokeMethod('cycle', {'cycle': cycle});
      await channel.invokeMethod('launch_acknowledged', {'cycle': cycle});
      await ended!.future;
      navigatorKey.currentState!.removeRoute(route);
      final watch = Stopwatch()..start();
      final previousFrames = frames;
      // NeoStation's menus are static: request a repaint after the native
      // return, without continuously waking Flutter throughout the game.
      ticker.scheduleFrame();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await channel.invokeMethod('after', {
        'cycle': cycle, 'delayMs': watch.elapsedMilliseconds,
        'frames': frames - previousFrames,
      });
      if (watch.elapsedMilliseconds > 2000 || frames <= previousFrames) {
        throw StateError('Flutter did not resume timers and frames after donor shutdown');
      }
    }
    await channel.invokeMethod('waiter_contract');
    await channel.invokeMethod('success', {'cycles': 5});
  } catch (error, stack) {
    await channel.invokeMethod('failure', {'error': '$error', 'stack': '$stack'});
  }
}
