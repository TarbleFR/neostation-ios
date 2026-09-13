import 'dart:io';

import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/pairing_file_service.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

/// Keeps NeoStation's device-local RemotePairing route alive without requiring
/// a separately installed VPN application.
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

  /// Saving the first system configuration is the operation that asks iOS to
  /// display its native VPN authorization sheet. Existing configurations are
  /// reloaded and reused, so accepting once does not cause repeated prompts.
  static Future<LocalJitTunnelState> authorizeAndEnable() =>
      ensureRunningForJit();

  static Future<LocalJitTunnelState> ensureRunningForJit() async {
    if (!Platform.isIOS) {
      throw const LocalJitTunnelException(
        'unsupportedPlatform',
        'The integrated local JIT tunnel is available only on iOS.',
      );
    }

    try {
      final state = await StikjitBridge.ensureLocalTunnel();
      if (!state.active) {
        throw LocalJitTunnelException(
          'notConnected',
          'The NeoStation local JIT tunnel is ${state.status}.',
        );
      }
      _log.i(
        'NeoStation local JIT tunnel ready: '
        '${state.interfaceAddress ?? 'unknown'} -> '
        '${state.peerAddress ?? 'unknown'}; onDemand=${state.onDemand}.',
      );
      return state;
    } on PlatformException catch (error) {
      throw _platformException(error, 'start');
    }
  }

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

  /// Startup/resume refresh is deliberately best-effort: a denied VPN prompt
  /// must not block the frontend. Every JIT launch performs an authoritative
  /// awaited check again and surfaces an actionable failure.
  static Future<void> refreshInBackground({required String reason}) async {
    if (!Platform.isIOS ||
        !await PairingFileService.hasStoredPairingFile()) {
      return;
    }
    try {
      final current = await status();
      if (!current.authorized || !current.enabled) {
        _log.i(
          'NeoStation local JIT tunnel remains disabled after $reason; '
          'no system authorization prompt was requested in background.',
        );
        return;
      }
      if (current.active) return;
      await ensureRunningForJit();
      _log.i('NeoStation local JIT tunnel refreshed after $reason.');
    } catch (error) {
      _log.w(
        'NeoStation local JIT tunnel background refresh failed after '
        '$reason: $error',
      );
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
