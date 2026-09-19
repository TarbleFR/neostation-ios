import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

/// Read-only preflight for the LocalDevVPN RemotePairing endpoint.
class LocalDevVpnRouteService {
  LocalDevVpnRouteService._();

  static const _defaultTimeout = Duration(seconds: 2);
  static final LoggerService _log = LoggerService.instance;
  static Future<LocalDevVpnRouteState>? _probeInFlight;
  static bool? _debugIOSOverride;
  static Duration? _debugTimeoutOverride;

  static bool get _isIOS => _debugIOSOverride ?? Platform.isIOS;
  static Duration get _timeout => _debugTimeoutOverride ?? _defaultTimeout;

  @visibleForTesting
  static void debugOverrideIOS(bool? value) {
    _debugIOSOverride = value;
  }

  @visibleForTesting
  static void debugOverrideTimeout(Duration? value) {
    _debugTimeoutOverride = value;
  }

  /// Coalesces concurrent launches into one bounded native TCP probe.
  static Future<LocalDevVpnRouteState> ensureReachable() async {
    if (!_isIOS) {
      throw const LocalDevVpnRouteException(
        code: 'unsupported_platform',
        message: 'LocalDevVPN route probing is available only on iOS.',
      );
    }

    final existing = _probeInFlight;
    if (existing != null) return existing;

    final probe = _probe();
    _probeInFlight = probe;
    try {
      return await probe;
    } finally {
      if (identical(_probeInFlight, probe)) {
        _probeInFlight = null;
      }
    }
  }

  static Future<LocalDevVpnRouteState> _probe() async {
    final timer = Stopwatch()..start();
    try {
      final state = await StikjitBridge.probeLocalDevVpnRoute().timeout(
        _timeout,
      );
      _log.i(
        'LocalDevVPN route ready at ${state.host}:${state.port}; '
        'nativeState=${state.state}/${state.networkState}; '
        'nativeElapsedMs=${state.elapsedMs}; totalElapsedMs=${timer.elapsedMilliseconds}.',
      );
      return state;
    } on TimeoutException catch (error) {
      _log.w(
        'LocalDevVPN route probe timed out after ${timer.elapsedMilliseconds}ms.',
      );
      throw LocalDevVpnRouteException(
        code: 'localdevvpn_route_probe_timeout',
        message:
            'LocalDevVPN did not answer at '
            '${LocalDevVpnRouteState.expectedHost}:'
            '${LocalDevVpnRouteState.expectedPort} within two seconds.',
        details: error,
      );
    } on PlatformException catch (error) {
      _log.w(
        'LocalDevVPN route unavailable after ${timer.elapsedMilliseconds}ms '
        '(${error.code}): ${error.message}; details=${error.details}.',
      );
      throw LocalDevVpnRouteException(
        code: error.code,
        message: error.message ?? 'The LocalDevVPN route is unavailable.',
        details: error.details,
      );
    } on StateError catch (error, stackTrace) {
      _log.e(
        'LocalDevVPN route probe returned an invalid response after '
        '${timer.elapsedMilliseconds}ms.',
        error: error,
        stackTrace: stackTrace,
      );
      throw LocalDevVpnRouteException(
        code: 'localdevvpn_route_invalid_response',
        message: 'LocalDevVPN route probe returned an invalid native response.',
        details: error,
      );
    } catch (error, stackTrace) {
      _log.e(
        'LocalDevVPN route probe failed after ${timer.elapsedMilliseconds}ms.',
        error: error,
        stackTrace: stackTrace,
      );
      throw LocalDevVpnRouteException(
        code: 'localdevvpn_route_probe_failed',
        message: 'LocalDevVPN route probing failed unexpectedly.',
        details: error,
      );
    }
  }
}

class LocalDevVpnRouteException implements Exception {
  const LocalDevVpnRouteException({
    required this.code,
    required this.message,
    this.details,
  });

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => message;
}
