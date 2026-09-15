import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/local_jit_session_coordinator.dart';

void main() {
  test('manual stop cancels a resume still waiting for the cold reset', () async {
    final reset = Completer<String>();
    var stops = 0;
    var starts = 0;
    final session = LocalJitSessionCoordinator<String>(
      ensureRoute: () async { starts++; return 'route'; },
      stopTunnel: () { stops++; return stops == 1 ? reset.future : Future.value('off'); },
      onResetError: (_) {},
    );
    final oldResume = session.ensure();
    final cancelled = expectLater(oldResume, throwsA(isA<LocalJitSessionCancelled>()));
    expect(stops, 1);
    await session.stop();
    reset.complete('off');
    await cancelled;
    expect(starts, 0, reason: 'The old Dart continuation must not reach the bridge.');
    expect(await session.ensure(), 'route');
    expect(starts, 1, reason: 'A genuinely newer request remains allowed.');
  });

  test('game and lifecycle requests cannot overtake or duplicate cold reset', () async {
    final reset = Completer<String>();
    var stops = 0;
    var starts = 0;
    final session = LocalJitSessionCoordinator<String>(
      ensureRoute: () async { starts++; return 'route'; },
      stopTunnel: () { stops++; return reset.future; },
      onResetError: (_) {},
    );
    final first = session.ensure();
    final second = session.ensure();
    await Future<void>.delayed(Duration.zero);
    expect(stops, 1);
    expect(starts, 0);
    reset.complete('off');
    expect(await Future.wait([first, second]), ['route', 'route']);
    // Native manager coalesces these route requests; the Dart layer gates reset.
    expect(starts, 2);
  });

  test('stop rejects an in-flight result, without disabling later activation', () async {
    final route = Completer<String>();
    var starts = 0;
    var stops = 0;
    final session = LocalJitSessionCoordinator<String>(
      ensureRoute: () { starts++; return starts == 1 ? route.future : Future.value('new'); },
      stopTunnel: () async { stops++; return 'off'; },
      onResetError: (_) {},
    );
    final pending = session.ensure();
    final cancelled = expectLater(pending, throwsA(isA<LocalJitSessionCancelled>()));
    await Future<void>.delayed(Duration.zero);
    expect(starts, 1);
    await session.stop();
    route.complete('obsolete');
    await cancelled;
    expect(stops, 2);
    expect(await session.ensure(), 'new');
  });

  test('reset failure does not block an independently verified external route', () async {
    final failures = <Object>[];
    final session = LocalJitSessionCoordinator<String>(
      ensureRoute: () async => 'external-verified',
      stopTunnel: () async => throw StateError('no owned profile access'),
      onResetError: failures.add,
    );
    expect(await session.ensure(), 'external-verified');
    expect(await session.ensure(), 'external-verified');
    expect(failures, hasLength(1));
  });

  test('failed route preflight never becomes a successful activation', () async {
    final session = LocalJitSessionCoordinator<String>(
      ensureRoute: () async => throw StateError('endpoint unreachable'),
      stopTunnel: () async => 'off',
      onResetError: (_) {},
    );
    await expectLater(session.ensure(), throwsStateError);
  });
}
