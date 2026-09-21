import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/rpcs3_startup_transaction.dart';

class Harness {
  final calls = <String>[];
  final phases = <Rpcs3StartupPhase>[];
  String? fail;
  Map<String, dynamic>? cleanupOverride;
  Map<String, dynamic>? reserveOverride;
  Map<String, dynamic>? completionOverride;
  Map<String, dynamic>? executionOverride;
  Completer<void>? attachGate;
  Future<Map<String, dynamic>> step(
    String name,
    Map<String, dynamic> success,
  ) async {
    calls.add(name);
    if (name == 'attach' && attachGate != null) await attachGate!.future;
    if (fail == name)
      return {
        'success': false,
        'code': 'KERNEL_ORIGINAL_3',
        'stage': name,
        'message': 'exact native failure',
      };
    return success;
  }

  Rpcs3StartupOperations get operations => Rpcs3StartupOperations(
    route: () => step('route', {'success': true}),
    reserve: () => step(
      'reserve',
      reserveOverride ??
          {
            'success': true,
            'addressSpaceReserved': true,
            'codeBytes': 469762048,
            'dataBytes': 603979776,
            'budgetBytes': 1073741824,
          },
    ),
    attach: () => step('attach', {'success': true, 'requiresCompletion': true}),
    initialize: () => step('initialize', {'success': true}),
    complete: () => step(
      'complete',
      completionOverride ?? {'success': true, 'transactionClosed': true},
    ),
    verify: () => step(
      'verify',
      executionOverride ?? {'success': true, 'status': 0, 'output': 40},
    ),
    abort: () => step(
      'abort',
      cleanupOverride ??
          {
            'success': true,
            'transactionClosed': true,
            'retryable': true,
            'code': 'RPCS3_STARTUP_ABORTED',
            'message': 'all resources released',
          },
    ),
    onPhase: phases.add,
  );
}

void main() {
  test(
    'ready only after actual reservation, initialize, detach and generated execution',
    () async {
      final tx = Rpcs3StartupTransaction();
      final h = Harness();
      await tx.ensure(h.operations);
      expect(h.calls, [
        'route',
        'reserve',
        'attach',
        'initialize',
        'complete',
        'verify',
      ]);
      expect(tx.ready, true);
      await tx.ensure(h.operations); // no double initialization
      expect(h.calls.length, 6);
    },
  );
  test(
    'simultaneous calls share one native startup and no early ready',
    () async {
      final tx = Rpcs3StartupTransaction();
      final h = Harness()..attachGate = Completer<void>();
      final one = tx.ensure(h.operations);
      final two = tx.ensure(h.operations);
      await Future<void>.delayed(Duration.zero);
      expect(tx.ready, false);
      expect(tx.inProgress, true);
      expect(h.calls, ['route', 'reserve', 'attach']);
      h.attachGate!.complete();
      await Future.wait([one, two]);
      expect(h.calls.where((c) => c == 'attach').length, 1);
      expect(tx.inProgress, false);
    },
  );
  test(
    'route failure does not reserve memory or touch helper; manual retry works',
    () async {
      final tx = Rpcs3StartupTransaction();
      final h = Harness()..fail = 'route';
      await expectLater(
        tx.ensure(h.operations),
        throwsA(isA<Rpcs3StartupFailure>()),
      );
      expect(h.calls, ['route']);
      expect(tx.phase, Rpcs3StartupPhase.idle);
      h.fail = null;
      await tx.ensure(h.operations);
      expect(tx.ready, true);
    },
  );
  for (final phase in [
    'reserve',
    'attach',
    'initialize',
    'complete',
    'verify',
  ]) {
    test(
      'failure at $phase closes transaction and a clean new attempt succeeds',
      () async {
        final tx = Rpcs3StartupTransaction();
        final h = Harness()..fail = phase;
        await expectLater(
          tx.ensure(h.operations),
          throwsA(
            isA<Rpcs3StartupFailure>()
                .having((e) => e.code, 'original code', 'KERNEL_ORIGINAL_3')
                .having(
                  (e) => e.detail,
                  'original detail',
                  'exact native failure',
                ),
          ),
        );
        expect(h.calls.last, 'abort');
        expect(tx.ready, false);
        expect(tx.phase, Rpcs3StartupPhase.idle);
        h.fail = null;
        await tx.ensure(h.operations);
        expect(tx.ready, true);
      },
    );
  }
  test(
    'unconfirmed cleanup blocks re-entry but preserves original fault, not generic incomplete',
    () async {
      final tx = Rpcs3StartupTransaction();
      final h = Harness()
        ..fail = 'initialize'
        ..cleanupOverride = {
          'success': false,
          'code': 'DETACH_TIMEOUT',
          'message': 'not closed',
        };
      for (var i = 0; i < 2; i++) {
        await expectLater(
          tx.ensure(h.operations),
          throwsA(
            isA<Rpcs3StartupFailure>()
                .having((e) => e.code, 'cause', 'KERNEL_ORIGINAL_3')
                .having((e) => e.cleanupCode, 'cleanup', 'DETACH_TIMEOUT'),
          ),
        );
      }
      expect(tx.phase, Rpcs3StartupPhase.blocked);
      expect(h.calls.where((c) => c == 'attach').length, 1);
    },
  );
  test('cleanup success without all confirmations is not retryable', () async {
    final tx = Rpcs3StartupTransaction();
    final h = Harness()
      ..fail = 'initialize'
      ..cleanupOverride = {'success': true};
    await expectLater(
      tx.ensure(h.operations),
      throwsA(isA<Rpcs3StartupFailure>()),
    );
    expect(tx.phase, Rpcs3StartupPhase.blocked);
  });
  test('a success stub without actual VA reservation is rejected', () async {
    final tx = Rpcs3StartupTransaction();
    final h = Harness()..reserveOverride = {'success': true};
    await expectLater(
      tx.ensure(h.operations),
      throwsA(
        isA<Rpcs3StartupFailure>().having(
          (e) => e.code,
          'code',
          'RPCS3_VA_PROOF_MISSING',
        ),
      ),
    );
    expect(h.calls, ['route', 'reserve', 'abort']);
  });
  test(
    'missing detach proof and wrong execution output cannot publish ready',
    () async {
      for (final isDetach in [true, false]) {
        final tx = Rpcs3StartupTransaction();
        final h = Harness();
        if (isDetach) {
          h.completionOverride = {'success': true};
        } else {
          h.executionOverride = {'success': true, 'status': 0, 'output': 41};
        }
        await expectLater(
          tx.ensure(h.operations),
          throwsA(isA<Rpcs3StartupFailure>()),
        );
        expect(tx.ready, false);
        expect(h.calls.last, 'abort');
      }
    },
  );
}
