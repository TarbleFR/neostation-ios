#!/usr/bin/env python3
"""Run the actual GameLaunchManager with controllable audio/native dependencies.

Only platform and I/O services are doubled. The production manager and its
asynchronous finalization order are compiled unchanged with Flutter's notifier.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
manager = (ROOT / 'lib/services/game_launch_manager.dart').read_text()
manager = re.sub(r'^import .*;\n', '', manager, flags=re.M)
fixture = r'''
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
class Platform {
  static bool get isIOS => true;
  static bool get isAndroid => false;
  static String get operatingSystem => 'ios';
}
final events = <String>[];
class LoggerService {
  static final instance = LoggerService();
  void i(String s) {}
  void w(String s) {}
  void d(String s) {}
  void e(String s, {Object? error, StackTrace? stackTrace}) {}
}
class GameService {
  static void clearOnGameReturnedCallback() {}
  static void clearOnProcessExitCallback() {}
  static void setOnGameReturnedCallback(void Function(Object?) cb) {}
  static void setOnProcessExitCallback(void Function() cb) {}
  static Future<bool> isEmulatorRunning(String? exe) async => true;
}
class DusklightInternalBridge {
  static final controller = StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get sessionEvents => controller.stream;
  static bool get didEndSession => false;
  static bool get didReleaseRuntime => false;
}
class Armsx2InternalBridge {
  static Stream<Map<String, dynamic>> get sessionEvents => const Stream.empty();
}
class SfxService {
  static final instance = SfxService._();
  factory SfxService() => instance;
  SfxService._();
  bool isEnabled = true;
  void setEnabled(bool value) { isEnabled = value; events.add('sfx:$value'); }
}
class MusicPlayerService {
  static final instance = MusicPlayerService._();
  factory MusicPlayerService() => instance;
  MusicPlayerService._();
  bool playing = true, wasPlaying = false, failResume = false;
  Future<void> pauseForGame() async {
    events.add('pause'); wasPlaying = playing; playing = false;
  }
  Future<void> resumeAfterGame() async {
    expect(AudioPolicyService().active, isTrue);
    events.add('resume');
    if (failResume) throw StateError('injected audio backend error');
    playing = wasPlaying; wasPlaying = false;
  }
}
class AudioPolicyService {
  static final instance = AudioPolicyService._();
  factory AudioPolicyService() => instance;
  AudioPolicyService._();
  Completer<void>? activation;
  bool active = false;
  Future<void> restoreAfterGameSession() async {
    events.add('activate'); await activation?.future;
    active = true; events.add('activated');
  }
}
Future<void> flush() async {
  for (var i = 0; i < 20; ++i) { await Future<void>.value(); }
}
'''
scenarios = r'''
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = GameLaunchManager();
  final audio = AudioPolicyService();
  final music = MusicPlayerService();
  final sfx = SfxService();
  setUp(() { events.clear(); audio.active = false; audio.activation = null; music.failResume = false; });
  test('100 returns reactivate before voices and preserve muted preferences', () async {
    for (var i = 0; i < 100; ++i) {
      events.clear(); audio.active = false; audio.activation = Completer<void>();
      final effects = i.isEven, playing = i % 3 == 0;
      sfx.isEnabled = effects; music.playing = playing;
      await manager.beginSession();
      manager.onGameStarted(emulatorExe: 'ios_dusklight_internal');
      DusklightInternalBridge.controller.add({
        'reason': 'native-return', 'runtimeReleased': false,
      });
      await flush(); expect(manager.phase, GameLaunchPhase.closing);
      manager.completeClose(); manager.onDialogDisposed(); manager.onDialogDisposed();
      await flush();
      expect(events.where((e) => e == 'activate').length, 1);
      expect(music.playing, isFalse); expect(sfx.isEnabled, isFalse);
      audio.activation!.complete(); await flush();
      expect(events.indexOf('activated'), lessThan(events.indexOf('resume')));
      expect(manager.isActive, isFalse);
      expect(music.playing, playing); expect(sfx.isEnabled, effects);
    }
  });
  test('rapid new launch waits for the old activation instead of being interrupted', () async {
    sfx.isEnabled = true; music.playing = true;
    await manager.beginSession(); manager.completeClose();
    audio.activation = Completer<void>(); manager.onDialogDisposed(); await flush();
    var newLaunchReady = false;
    final next = manager.beginSession().then((_) { newLaunchReady = true; });
    await flush(); expect(newLaunchReady, isFalse);
    audio.activation!.complete(); await next;
    expect(events.last, 'pause'); expect(music.playing, isFalse);
    expect(sfx.isEnabled, isFalse); expect(manager.phase, GameLaunchPhase.launching);
    audio.activation = null;
    manager.completeClose(); manager.onDialogDisposed(); await flush();
    expect(music.playing, isTrue); expect(sfx.isEnabled, isTrue);
  });
  test('failed launch and a playback failure still release the completion barrier', () async {
    sfx.isEnabled = false; music.playing = false;
    await manager.beginSession(); music.failResume = true;
    manager.onDialogDisposed(); await flush();
    expect(manager.isActive, isFalse); expect(sfx.isEnabled, isFalse);
    music.failResume = false;
    await manager.beginSession();
    manager.onDialogDisposed(); await flush();
    expect(manager.isActive, isFalse);
  });
}
'''
with tempfile.TemporaryDirectory(prefix='neostation-audio-handoff-') as directory:
    root = Path(directory)
    (root / 'test').mkdir()
    (root / 'pubspec.yaml').write_text('''name: neostation_audio_handoff_harness
environment:
  sdk: '>=3.9.2 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  flutter_test:
    sdk: flutter
''')
    (root / 'test/audio_test.dart').write_text(fixture + manager + scenarios)
    subprocess.run([os.environ.get('FLUTTER_BIN', 'flutter'), 'test', '--reporter', 'expanded'], cwd=root, check=True)
