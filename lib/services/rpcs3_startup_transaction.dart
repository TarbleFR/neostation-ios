import 'dart:async';

/// Single owner of the startup transaction. An attachment is not JIT success.
enum Rpcs3StartupPhase {
  idle,
  route,
  attaching,
  initializing,
  completing,
  verifying,
  aborting,
  ready,
  blocked,
}

typedef Rpcs3StartupOperation = Future<Map<String, dynamic>> Function();

class Rpcs3StartupFailure implements Exception {
  const Rpcs3StartupFailure(
    this.code,
    this.detail,
    this.stage, {
    this.cleanupCode,
    this.cleanupDetail,
  });
  final String code;
  final String detail;
  final String stage;
  final String? cleanupCode;
  final String? cleanupDetail;
  String get message =>
      '[$code] stage=$stage; $detail'
      '${cleanupCode == null ? '' : '\nCleanup: [$cleanupCode] $cleanupDetail'}';
  @override
  String toString() => message;
}

class Rpcs3StartupOperations {
  const Rpcs3StartupOperations({
    required this.route,
    required this.attach,
    required this.initialize,
    required this.complete,
    required this.verify,
    required this.abort,
    required this.onPhase,
  });
  final Rpcs3StartupOperation route,
      attach,
      initialize,
      complete,
      verify,
      abort;
  final void Function(Rpcs3StartupPhase) onPhase;
}

class Rpcs3StartupTransaction {
  Rpcs3StartupPhase phase = Rpcs3StartupPhase.idle;
  Future<void>? _pending;
  Rpcs3StartupFailure? _blockedFailure;
  bool get ready => phase == Rpcs3StartupPhase.ready;
  bool get inProgress => _pending != null;

  Future<void> ensure(Rpcs3StartupOperations operations) {
    if (_pending != null) return _pending!;
    if (ready) return Future<void>.value();
    if (_blockedFailure != null) return Future<void>.error(_blockedFailure!);
    final future = _run(operations);
    _pending = future;
    return future.whenComplete(() {
      if (identical(_pending, future)) _pending = null;
    });
  }

  Future<void> _run(Rpcs3StartupOperations operations) async {
    var resourcesMayExist = false;
    void setPhase(Rpcs3StartupPhase next) {
      phase = next;
      operations.onPhase(next);
    }

    Future<Map<String, dynamic>> step(
      Rpcs3StartupPhase next,
      Rpcs3StartupOperation operation,
    ) async {
      setPhase(next);
      final report = await operation();
      if (report['success'] != true) {
        throw Rpcs3StartupFailure(
          report['code']?.toString() ??
              'RPCS3_${next.name.toUpperCase()}_FAILED',
          report['message']?.toString() ??
              'Native operation returned no diagnostic.',
          report['stage']?.toString() ?? next.name,
        );
      }
      return report;
    }

    try {
      await step(Rpcs3StartupPhase.route, operations.route);
      final attach = await step(Rpcs3StartupPhase.attaching, operations.attach);
      resourcesMayExist = true;
      await step(Rpcs3StartupPhase.initializing, operations.initialize);
      if (attach['requiresCompletion'] != false) {
        final completion = await step(
          Rpcs3StartupPhase.completing,
          operations.complete,
        );
        if (completion['transactionClosed'] != true) {
          throw const Rpcs3StartupFailure(
            'RPCS3_JIT_DETACH_PROOF_MISSING',
            'Helper returned no confirmed transaction closure.',
            'completing',
          );
        }
      }
      final execution = await step(
        Rpcs3StartupPhase.verifying,
        operations.verify,
      );
      if (execution['status'] != 0 || execution['output'] != 40) {
        throw const Rpcs3StartupFailure(
          'RPCS3_LLVM_RESULT_MISMATCH',
          'The generated function did not return the expected result 40.',
          'verifying',
        );
      }
      setPhase(Rpcs3StartupPhase.ready);
    } catch (error) {
      final original = error is Rpcs3StartupFailure
          ? error
          : Rpcs3StartupFailure(
              'RPCS3_${phase.name.toUpperCase()}_EXCEPTION',
              error.toString(),
              phase.name,
            );
      if (!resourcesMayExist) {
        setPhase(Rpcs3StartupPhase.idle);
        throw original;
      }
      setPhase(Rpcs3StartupPhase.aborting);
      Map<String, dynamic> cleanup;
      try {
        cleanup = await operations.abort();
      } catch (cleanupError) {
        cleanup = {
          'success': false,
          'code': 'RPCS3_STARTUP_ABORT_EXCEPTION',
          'message': cleanupError.toString(),
        };
      }
      final cleanupClosed =
          cleanup['success'] == true && cleanup['transactionClosed'] == true;
      final failure = Rpcs3StartupFailure(
        original.code,
        original.detail,
        original.stage,
        cleanupCode:
            cleanup['code']?.toString() ?? 'RPCS3_STARTUP_ABORT_UNCONFIRMED',
        cleanupDetail:
            cleanup['message']?.toString() ?? 'No cleanup confirmation.',
      );
      // Never retry automatically. A fully closed cleanup merely permits a
      // later user-initiated launch. If cleanup cannot prove detach/rollback,
      // preserve the first failure and block unsafe reuse of the same process.
      if (cleanupClosed) {
        setPhase(Rpcs3StartupPhase.idle);
      } else {
        _blockedFailure = failure;
        setPhase(Rpcs3StartupPhase.blocked);
      }
      throw failure;
    }
  }
}
