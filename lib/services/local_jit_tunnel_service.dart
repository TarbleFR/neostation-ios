import 'dart:io';

import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

/// Single-source policy for NeoStation's integrated local JIT VPN.
///
/// Settings ON/OFF are the only mutating operations. Emulator/JIT preflight is
/// read-only and application lifecycle events never change the VPN state.
class LocalJitTunnelService {
  LocalJitTunnelService._();

  static final LoggerService _log = LoggerService.instance;

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

  /// Explicit Settings ON. No RemotePairing/JIT diagnostic is allowed to undo
  /// this choice after NetworkExtension reaches an active state.
  static Future<LocalJitTunnelState> authorizeAndEnable() async {
    if (!Platform.isIOS) {
      throw const LocalJitTunnelException(
        'unsupportedPlatform',
        'The integrated local JIT tunnel is available only on iOS.',
      );
    }
    try {
      final state = await StikjitBridge.activateOwnedTunnel();
      _log.i(
        'NeoStationLocalTunnel explicit ON: ${state.status}; '
        'enabled=${state.enabled}; onDemand=${state.onDemand}.',
      );
      return state;
    } on PlatformException catch (error) {
      throw _platformException(error, 'start');
    }
  }

  /// Read-only game/JIT preflight. This method never starts, stops, saves or
  /// reconfigures a VPN profile.
  static Future<LocalJitTunnelState> ensureRunningForJit() async {
    if (!Platform.isIOS) {
      throw const LocalJitTunnelException(
        'unsupportedPlatform',
        'The integrated local JIT tunnel is available only on iOS.',
      );
    }
    try {
      final state = await StikjitBridge.ensureJitRoute();
      _log.i(
        'Local JIT endpoint reachable: ${state.peerAddress ?? 'unknown'}; '
        'managedByNeoStation=${state.managedByNeoStation}.',
      );
      return state;
    } on PlatformException catch (error) {
      throw _platformException(error, 'probe');
    }
  }

  /// Explicit Settings OFF. This is the only application path that stops the
  /// NeoStation-owned tunnel.
  static Future<LocalJitTunnelState> disable() async {
    if (!Platform.isIOS) {
      throw const LocalJitTunnelException(
        'unsupportedPlatform',
        'The integrated local JIT tunnel is available only on iOS.',
      );
    }
    try {
      final state = await StikjitBridge.disableLocalTunnel();
      _log.i(
        'NeoStationLocalTunnel explicit OFF: ${state.status}; '
        'enabled=${state.enabled}.',
      );
      return state;
    } on PlatformException catch (error) {
      throw _platformException(error, 'stop');
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
