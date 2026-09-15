import 'dart:io';

import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

import 'local_jit_session_coordinator.dart';

/// Coordinates the local StikJIT route for one foreground NeoStation session.
/// Only the native bridge selects/controls a VPN; LocalDevVPN is never mutated.
class LocalJitTunnelService {
  LocalJitTunnelService._();

  static final LoggerService _log = LoggerService.instance;
  static int _lifecycleGeneration = 0;
  static final _session = LocalJitSessionCoordinator<LocalJitTunnelState>(
    ensureRoute: _ensureNativeRoute,
    stopTunnel: _disableNativeTunnel,
    onResetError: (error) {
      _log.w('Could not reset a stale NeoStation local tunnel: $error');
    },
  );

  static Future<LocalJitTunnelState> status() async {
    if (!Platform.isIOS) {
      return const LocalJitTunnelState(
        active: false,
        status: 'unsupported',
        managedByNeoStation: true,
        configured: false,
        authorized: false,
        enabled: false,
        interfaceAddress: null,
        peerAddress: null,
        onDemand: false,
      );
    }
    try {
      return await StikjitBridge.localTunnelStatus();
    } on PlatformException catch (error) {
      throw _platformException(error, 'inspect');
    }
  }

  static Future<LocalJitTunnelState> authorizeAndEnable() async {
    return ensureRunningForJit();
  }

  /// Shared by lifecycle activation and all emulators. A game cannot overtake
  /// the cold reset, and a stale Dart continuation cannot undo a manual stop.
  static Future<LocalJitTunnelState> ensureRunningForJit() async {
    if (!Platform.isIOS) {
      throw const LocalJitTunnelException(
        'unsupportedPlatform',
        'The integrated local JIT tunnel is available only on iOS.',
      );
    }
    try {
      return await _session.ensure();
    } on LocalJitSessionCancelled {
      throw const LocalJitTunnelException(
        'local_tunnel_cancelled',
        'The local JIT route request was cancelled by a newer stop.',
      );
    }
  }

  static Future<LocalJitTunnelState> _ensureNativeRoute() async {
    try {
      final state = await StikjitBridge.ensureJitRoute();
      if (!state.active || !state.routeVerified) {
        throw LocalJitTunnelException(
          'notConnected',
          'The local JIT route is ${state.status}.',
        );
      }
      _log.i(
        'Local JIT route ready: '
        '${state.interfaceAddress ?? 'external'} -> '
        '${state.peerAddress ?? 'unknown'}; '
        'managedByNeoStation=${state.managedByNeoStation}; '
        'onDemand=${state.onDemand}.',
      );
      return state;
    } on PlatformException catch (error) {
      throw _platformException(error, 'start');
    }
  }

  /// Invalidates both native requests and not-yet-submitted Dart continuations.
  static Future<LocalJitTunnelState> disable() async {
    if (!Platform.isIOS) {
      throw const LocalJitTunnelException(
        'unsupportedPlatform',
        'The integrated local JIT tunnel is available only on iOS.',
      );
    }
    ++_lifecycleGeneration;
    return _session.stop();
  }

  static Future<LocalJitTunnelState> _disableNativeTunnel() async {
    try {
      return await StikjitBridge.disableLocalTunnel();
    } on PlatformException catch (error) {
      throw _platformException(error, 'stop');
    }
  }

  /// Best-effort frontend activation. The game repeats the same real preflight.
  static Future<void> refreshInBackground({required String reason}) async {
    if (!Platform.isIOS) return;
    final generation = ++_lifecycleGeneration;
    try {
      final route = await ensureRunningForJit();
      if (generation != _lifecycleGeneration) return;
      _log.i(
        route.managedByNeoStation
            ? 'NeoStationLocalTunnel is ready after $reason.'
            : 'External StikJIT route reused after $reason; '
                'NeoStationLocalTunnel remains off.',
      );
    } catch (error) {
      if (generation != _lifecycleGeneration) return;
      _log.w('Local JIT route activation failed after $reason: $error');
    }
  }

  static Future<void> stopForLifecycle({required String reason}) async {
    if (!Platform.isIOS) return;
    ++_lifecycleGeneration;
    try {
      final state = await disable();
      _log.i(
        'NeoStation local tunnel stopped for $reason: ${state.status}; '
        'enabled=${state.enabled}; onDemand=${state.onDemand}.',
      );
    } catch (error) {
      _log.w('NeoStation local tunnel stop failed for $reason: $error');
    }
  }

  static LocalJitTunnelException _platformException(
    PlatformException error,
    String operation,
  ) {
    _log.w(
      'Local JIT tunnel $operation failed (${error.code}): '
      '${error.message}; details=${error.details}',
    );
    return LocalJitTunnelException(
      error.code,
      error.message ?? 'The NeoStation local JIT tunnel could not $operation.',
    );
  }
}

class LocalJitTunnelException implements Exception {
  const LocalJitTunnelException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}
