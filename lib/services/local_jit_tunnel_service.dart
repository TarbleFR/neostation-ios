import 'dart:io';

import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

/// Coordinates the local StikJIT route for one foreground NeoStation session.
///
/// Route ownership and route availability are separate concepts: LocalDevVPN
/// may already expose the RemotePairing endpoint, while NeoStation only manages
/// NeoStationLocalTunnel. All launch paths ask for a validated route through
/// [ensureRunningForJit] and never start a VPN directly.
class LocalJitTunnelService {
  LocalJitTunnelService._();

  static final LoggerService _log = LoggerService.instance;
  static bool _coldSessionResetDone = false;
  static int _lifecycleGeneration = 0;

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

  /// Manual compatibility action retained for the Tools screen. The native
  /// bridge is route-aware, so this reuses a working external JIT route and
  /// starts NeoStationLocalTunnel only when it is genuinely needed.
  static Future<LocalJitTunnelState> authorizeAndEnable() async {
    return ensureRunningForJit();
  }

  /// Single authoritative JIT preflight shared by RPCS3, Dolphin, MeloNX,
  /// ARMSX2 and future JIT launch paths.
  static Future<LocalJitTunnelState> ensureRunningForJit() async {
    if (!Platform.isIOS) {
      throw const LocalJitTunnelException(
        'unsupportedPlatform',
        'The integrated local JIT tunnel is available only on iOS.',
      );
    }

    try {
      final state = await StikjitBridge.ensureJitRoute();
      if (!state.active) {
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

  /// Stops only the manager owned by NeoStation. The native layer filters by
  /// provider bundle/ownership marker and never mutates LocalDevVPN.
  static Future<LocalJitTunnelState> disable() async {
    if (!Platform.isIOS) {
      throw const LocalJitTunnelException(
        'unsupportedPlatform',
        'The integrated local JIT tunnel is available only on iOS.',
      );
    }
    try {
      return await StikjitBridge.disableLocalTunnel();
    } on PlatformException catch (error) {
      throw _platformException(error, 'stop');
    }
  }

  /// Cold start/resume activation is intentionally best-effort so VPN signing
  /// or authorization errors never block NeoStation's frontend. Game launch
  /// repeats the same route validation synchronously and surfaces the error.
  ///
  /// On the first activation of a process we first neutralize any NeoStation
  /// tunnel left by an abnormal previous session. The subsequent native route
  /// check can then distinguish LocalDevVPN from NeoStationLocalTunnel instead
  /// of mistaking a stale owned route for an external one.
  static Future<void> refreshInBackground({required String reason}) async {
    if (!Platform.isIOS) return;
    final generation = ++_lifecycleGeneration;

    if (!_coldSessionResetDone) {
      _coldSessionResetDone = true;
      try {
        await disable();
      } catch (error) {
        _log.w(
          'Could not reset a stale NeoStation local tunnel before $reason: '
          '$error',
        );
      }
      if (generation != _lifecycleGeneration) return;
    }

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
      _log.w(
        'Local JIT route activation failed after $reason: $error',
      );
    }
  }

  /// Called for inactive/background/hidden/detached/normal-exit lifecycle
  /// transitions. Incrementing the generation invalidates a Flutter-side
  /// activation result while the native manager gives the stop request
  /// priority over any in-flight start operation.
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
    return LocalJitTunnelException(
      error.code,
      error.message ??
          'The NeoStation local JIT tunnel could not $operation.',
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
