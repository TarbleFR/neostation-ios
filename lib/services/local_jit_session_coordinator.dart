/// Serializes the one-time cold reset with every route request. Cancellation
/// belongs to the request, not just to work already submitted to the native
/// bridge: a stop also invalidates Dart continuations still awaiting the reset.
class LocalJitSessionCoordinator<T> {
  LocalJitSessionCoordinator({
    required Future<T> Function() ensureRoute,
    required Future<T> Function() stopTunnel,
    required void Function(Object error) onResetError,
  }) : _ensureRoute = ensureRoute,
       _stopTunnel = stopTunnel,
       _onResetError = onResetError;

  final Future<T> Function() _ensureRoute;
  final Future<T> Function() _stopTunnel;
  final void Function(Object error) _onResetError;
  Future<void>? _coldReset;
  int _generation = 0;

  Future<void> _resetOnce() async {
    try {
      await _stopTunnel();
    } catch (error) {
      // Startup remains best-effort; the actual route preflight is still
      // authoritative and may reuse a working external route.
      _onResetError(error);
    }
  }

  Future<T> ensure({Future<T> Function()? routeOverride}) async {
    final generation = _generation;
    await (_coldReset ??= _resetOnce());
    if (generation != _generation) {
      throw const LocalJitSessionCancelled();
    }
    final route = await (routeOverride ?? _ensureRoute)();
    if (generation != _generation) {
      throw const LocalJitSessionCancelled();
    }
    return route;
  }

  Future<T> stop() {
    ++_generation;
    return _stopTunnel();
  }
}

class LocalJitSessionCancelled implements Exception {
  const LocalJitSessionCancelled();
}
