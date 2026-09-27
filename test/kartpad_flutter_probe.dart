import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const channel = MethodChannel('probe');
int frames = 0;
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky, overlays: []);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('KartPad Flutter lifecycle probe')))));
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
      await channel.invokeMethod('async_identity', {'cycle': cycle});
      await channel.invokeMethod('cycle', {'cycle': cycle});
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
    await channel.invokeMethod('success', {'cycles': 5});
  } catch (error, stack) {
    await channel.invokeMethod('failure', {'error': '$error', 'stack': '$stack'});
  }
}
