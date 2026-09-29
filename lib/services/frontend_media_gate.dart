import 'dart:async';
import 'package:flutter/foundation.dart';

/// Process-local barrier shared by every frontend video producer. It is not
/// released by app-foreground callbacks: an embedded game stays in-process.
class FrontendMediaGate extends ChangeNotifier {
  FrontendMediaGate();
  static final instance = FrontendMediaGate();
  final Set<Object> _owners = <Object>{};
  final Map<Object, Future<void> Function()> _stoppers = {};
  Future<void> _quiet = Future<void>.value();
  bool get blocked => _owners.isNotEmpty;
  Future<void> get quiet async {
    // A new widget can register while the previous teardown is awaiting native
    // disposal. Follow the latest barrier, not a stale Future snapshot.
    while (true) {
      final observed = _quiet;
      await observed;
      if (identical(observed, _quiet)) return;
    }
  }

  void _observeErrors() {
    // Callers still receive the original failure through quiet. This observer
    // prevents an unhandled error before the launch service reaches its await.
    unawaited(_quiet.catchError((Object _) {}));
  }

  void register(Object owner, Future<void> Function() stop) {
    _stoppers[owner] = stop;
    if (blocked) {
      _quiet = Future.wait<void>([_quiet, Future<void>.sync(stop)]).then((_) {});
      _observeErrors();
    }
  }
  void unregister(Object owner) => _stoppers.remove(owner);

  Future<void> hold(Object owner) {
    final wasBlocked = blocked;
    _owners.add(owner);
    if (!wasBlocked) {
      // Invoke synchronously to invalidate timers/generations BEFORE awaiting
      // controller initialization, disposal, JIT or platform handoff.
      final stops = _stoppers.values.toList(growable: false);
      _quiet = Future.wait<void>([
        _quiet.catchError((Object _) {}),
        for (final stop in stops) Future<void>.sync(stop),
      ]).then((_) {});
      _observeErrors();
      notifyListeners();
    }
    return quiet;
  }
  void release(Object owner) {
    final wasBlocked = blocked;
    _owners.remove(owner);
    if (wasBlocked && !blocked) notifyListeners();
  }
}
