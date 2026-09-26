#!/usr/bin/env python3
"""Exercise production Dart launch/close bodies with Flutter's real Navigator.

Native launch and metadata widgets are replaced with controllable doubles. The
route implementation itself is read verbatim from production sources, so these
checks cover taps, back, late completion and stacked dialogs without native JIT.
"""
from pathlib import Path
import os
import subprocess
import tempfile
from rpcs3_atomic_startup_test import extract_function

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'lib/utils/game_launch_utils.dart').read_text()
launch = source[source.index('Future<void> launchGameWithDialog('):]
close = extract_function((ROOT / 'lib/widgets/game_launch_dialog.dart').read_text(), 'void _closeDialog()')
PREAMBLE = r'''
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
class GameModel {}
class SystemModel {
  final String folderName;
  SystemModel([this.folderName = 'test']);
}
class FileProvider {}
class LoggerService {
  static final instance = LoggerService();
  void i(String _) {}
}
class GameLaunchResult {
  final bool success;
  final String message;
  GameLaunchResult(this.success, [this.message = '']);
}
class GameService {
  static bool pending = false;
  static int calls = 0;
  static String? launchedEmulatorExe;
  static late Completer<GameLaunchResult> result;
  static void beginLaunchPending() { pending = true; }
  static void clearLaunchPending() { pending = false; }
  static Future<GameLaunchResult> launchGame(BuildContext c, SystemModel s, GameModel g) {
    calls++;
    return result.future;
  }
}
class GameLaunchManager {
  static final instance = GameLaunchManager._();
  factory GameLaunchManager() => instance;
  GameLaunchManager._();
  String? phase;
  bool closeRouteImmediately = false;
  int starts = 0;
  Future<void> beginSession() async { phase = 'launching'; }
  void onGameStarted({String? emulatorExe}) { phase = 'playing'; starts++; }
  void onDialogDisposed() { phase = null; }
  void userDismiss() { if (phase == 'playing') phase = 'closing'; }
}
class GameLaunchDialog extends StatefulWidget {
  final VoidCallback onGameClosed;
  const GameLaunchDialog({super.key, required GameModel game, required SystemModel system,
    required FileProvider fileProvider, required this.onGameClosed});
  @override State<GameLaunchDialog> createState() => _DialogState();
}
class _DialogState extends State<GameLaunchDialog> {
  bool _closeCalled = false;
  bool _onGameClosedFired = false;
  @override void dispose() {
    GameService.clearLaunchPending();
    GameLaunchManager().onDialogDisposed();
    if (!_onGameClosedFired) widget.onGameClosed();
    super.dispose();
  }
  @override Widget build(BuildContext context) => const Center(child: Text('launch-pending'));
'''
TESTS = r'''
void main() {
  late BuildContext launcherContext;
  late GlobalKey<NavigatorState> navigator;
  late Future<void> launchFuture;
  int closed = 0;
  String? error;
  Future<void> mount(WidgetTester tester) async {
    navigator = GlobalKey<NavigatorState>(); closed = 0; error = null;
    GameService.pending = false; GameService.calls = 0;
    GameService.result = Completer<GameLaunchResult>();
    GameLaunchManager().phase = null; GameLaunchManager().starts = 0;
    GameLaunchManager().closeRouteImmediately = false;
    await tester.pumpWidget(MaterialApp(navigatorKey: navigator,
      home: Builder(builder: (context) {
        launcherContext = context;
        return const Scaffold(body: Text('library'));
      })));
  }
  Future<void> start(WidgetTester tester) async {
    launchFuture = launchGameWithDialog(context: launcherContext, game: GameModel(),
      system: SystemModel(), fileProvider: FileProvider(), onGameClosed: () { closed++; },
      onLaunchFailed: (context, result) async { error = result.message; });
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(GameService.calls, 1);
  }
  testWidgets('rapid touches and back keep the native launch session alive', (tester) async {
    await mount(tester); await start(tester);
    for (int i = 0; i < 4; i++) {
      await tester.tapAt(const Offset(10, 10));
      await tester.tap(find.text('launch-pending'));
      await navigator.currentState!.maybePop();
      await tester.pump();
    }
    expect(find.text('launch-pending'), findsOneWidget);
    expect(closed, 0); expect(GameService.pending, isTrue);
    expect(GameLaunchManager().phase, 'launching'); expect(GameService.calls, 1);
    GameService.result.complete(GameLaunchResult(true));
    await tester.pump(); await launchFuture;
    expect(GameLaunchManager().starts, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Ports launch skips the artificial two-second delay', (tester) async {
    await mount(tester);
    launchFuture = launchGameWithDialog(context: launcherContext, game: GameModel(),
      system: SystemModel('ports'), fileProvider: FileProvider(),
      onGameClosed: () { closed++; });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(GameService.calls, 1);
    GameService.result.complete(GameLaunchResult(true));
    await tester.pump(); await launchFuture;
    expect(GameLaunchManager().starts, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failure preserves its detail and removes only the launch dialog', (tester) async {
    await mount(tester); await start(tester);
    showDialog<void>(context: launcherContext, builder: (_) => const Text('other-dialog'));
    await tester.pumpAndSettle();
    GameService.result.complete(GameLaunchResult(false, 'original JIT reservation error'));
    await tester.pumpAndSettle(); await launchFuture;
    expect(error, 'original JIT reservation error');
    expect(find.text('other-dialog'), findsOneWidget);
    expect(find.text('launch-pending'), findsNothing);
    expect(closed, 1); expect(GameService.pending, isFalse);
    navigator.currentState!.pop(); await tester.pumpAndSettle();
    expect(find.text('library'), findsOneWidget);
    // A new explicit launch after failure is independent of the first result.
    GameService.result = Completer<GameLaunchResult>();
    launchFuture = launchGameWithDialog(context: launcherContext, game: GameModel(),
      system: SystemModel(), fileProvider: FileProvider(), onGameClosed: () { closed++; });
    await tester.pump(); await tester.pump(const Duration(seconds: 2));
    expect(GameService.calls, 2);
    GameService.result.complete(GameLaunchResult(true));
    await tester.pump(); await launchFuture;
    expect(GameLaunchManager().starts, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('late failure after external route removal cannot pop the library', (tester) async {
    await mount(tester); await start(tester);
    final route = ModalRoute.of(tester.element(find.text('launch-pending')))!;
    navigator.currentState!.removeRoute(route); await tester.pumpAndSettle();
    GameService.result.complete(GameLaunchResult(false, 'late error'));
    await tester.pumpAndSettle(); await launchFuture;
    expect(find.text('library'), findsOneWidget); expect(error, isNull);
    expect(closed, 1); expect(GameLaunchManager().starts, 0);
    expect(GameService.pending, isFalse);
  });
  testWidgets('thrown launch error closes its own route and keeps original error', (tester) async {
    await mount(tester); await start(tester);
    final failure = StateError('native launch failed');
    final expectation = expectLater(launchFuture, throwsA(same(failure)));
    GameService.result.completeError(failure);
    await tester.pumpAndSettle(); await expectation;
    expect(find.text('library'), findsOneWidget);
    expect(find.text('launch-pending'), findsNothing);
    expect(GameService.pending, isFalse); expect(closed, 1);
  });
  testWidgets('delayed normal close cannot pop a newer dialog', (tester) async {
    await mount(tester); await start(tester);
    GameService.result.complete(GameLaunchResult(true));
    await tester.pump(); await launchFuture;
    final state = tester.state<_DialogState>(find.byType(GameLaunchDialog));
    state._closeDialog();
    showDialog<void>(context: launcherContext, builder: (_) => const Text('newer-dialog'));
    await tester.pump(); await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('newer-dialog'), findsOneWidget);
    expect(find.text('launch-pending'), findsNothing); expect(closed, 1);
    navigator.currentState!.pop(); await tester.pumpAndSettle();
    expect(find.text('library'), findsOneWidget);
  });
  testWidgets('embedded iOS return closes its owned route without waiting for a timer', (tester) async {
    await mount(tester); await start(tester);
    GameService.result.complete(GameLaunchResult(true));
    await tester.pump(); await launchFuture;
    GameLaunchManager().closeRouteImmediately = true;
    final state = tester.state<_DialogState>(find.byType(GameLaunchDialog));
    state._closeDialog();
    showDialog<void>(context: launcherContext, builder: (_) => const Text('newer-dialog'));
    await tester.pump();
    // The route removal callback must run on this turn; Navigator may still
    // paint its outgoing overlay until a later frame.
    expect(closed, 1);
    await tester.pumpAndSettle();
    expect(find.text('launch-pending'), findsNothing);
    expect(find.text('newer-dialog'), findsOneWidget);
    navigator.currentState!.pop(); await tester.pumpAndSettle();
    expect(find.text('library'), findsOneWidget);
  });
}
'''
with tempfile.TemporaryDirectory(prefix='neostation-launch-route-') as directory:
    root = Path(directory)
    (root / 'test').mkdir()
    (root / 'pubspec.yaml').write_text('''name: neostation_launch_route_harness
environment:
  sdk: '>=3.9.2 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  flutter_test:
    sdk: flutter
''')
    (root / 'test/launch_test.dart').write_text(PREAMBLE + close + '\n}\n' + launch + TESTS)
    subprocess.run([os.environ.get('FLUTTER_BIN', 'flutter'), 'test', '--reporter', 'expanded'], cwd=root, check=True)
