import 'package:flutter/services.dart';

class StikjitBridge {
  StikjitBridge._();

  static const MethodChannel _channel = MethodChannel('neostation/stikjit');
  static const MethodChannel _armsx2Channel = MethodChannel(
    'neostation/stikjit_armsx2',
  );

  static Future<LocalDevVpnRouteState> probeLocalDevVpnRoute() async {
    final raw = await _channel.invokeMethod<Object?>('probeLocalDevVpnRoute');
    if (raw is! Map) {
      throw StateError('LocalDevVPN route probe returned an invalid response.');
    }
    final state = LocalDevVpnRouteState.fromMap(Map<String, dynamic>.from(raw));
    if (!state.reachable ||
        state.host != LocalDevVpnRouteState.expectedHost ||
        state.port != LocalDevVpnRouteState.expectedPort) {
      throw PlatformException(
        code: 'localdevvpn_route_unavailable',
        message:
            'LocalDevVPN did not expose RemotePairing at '
            '${LocalDevVpnRouteState.expectedHost}:'
            '${LocalDevVpnRouteState.expectedPort} '
            '(state=${state.state}, elapsedMs=${state.elapsedMs}).',
        details: raw,
      );
    }
    return state;
  }

  static Future<StikjitLaunchResult> enableMeloNxJit({
    required String pairingFilePath,
    required String bundleId,
    required String gameUrl,
  }) async {
    await probeLocalDevVpnRoute();
    final raw = await _channel.invokeMethod<Object?>('enableMeloNxJit', {
      'pairingFilePath': pairingFilePath,
      'bundleId': bundleId,
      'gameUrl': gameUrl,
    });
    if (raw is! Map) {
      throw StateError('StikJIT bridge returned an invalid response.');
    }
    final data = Map<String, dynamic>.from(raw);
    final pidValue = data['pid'];
    if (pidValue is! num) {
      throw StateError('StikJIT bridge did not return the MeloNX PID.');
    }
    final logs = <String>[];
    final rawLogs = data['logs'];
    if (rawLogs is List) {
      logs.addAll(rawLogs.map((entry) => entry.toString()));
    }
    return StikjitLaunchResult(
      pid: pidValue.toInt(),
      bundleId: data['bundleId']?.toString(),
      txmPresent: data['txmPresent'] as bool?,
      gameUrlOpened: data['gameUrlOpened'] as bool?,
      logs: logs,
    );
  }

  static Future<StikjitLaunchResult> enableArmsx2Jit({
    required String pairingFilePath,
    required String bundleId,
    required String gameUrl,
  }) async {
    await probeLocalDevVpnRoute();
    final raw = await _armsx2Channel.invokeMethod<Object?>('enableArmsx2Jit', {
      'pairingFilePath': pairingFilePath,
      'bundleId': bundleId,
      'gameUrl': gameUrl,
    });
    if (raw is! Map) {
      throw StateError('ARMSX2 StikJIT bridge returned an invalid response.');
    }
    final data = Map<String, dynamic>.from(raw);
    final pidValue = data['pid'];
    if (pidValue is! num) {
      throw StateError('ARMSX2 StikJIT bridge did not return the target PID.');
    }
    final logs = <String>[];
    final rawLogs = data['logs'];
    if (rawLogs is List) {
      logs.addAll(rawLogs.map((entry) => entry.toString()));
    }
    return StikjitLaunchResult(
      pid: pidValue.toInt(),
      bundleId: data['bundleId']?.toString(),
      txmPresent: data['txmPresent'] as bool?,
      gameUrlOpened: data['gameUrlOpened'] as bool?,
      logs: logs,
    );
  }
}

class LocalDevVpnRouteState {
  const LocalDevVpnRouteState({
    required this.reachable,
    required this.host,
    required this.port,
    required this.elapsedMs,
    required this.state,
    required this.networkState,
    this.errorDomain,
    this.errorCode,
    this.errorDescription,
  });

  factory LocalDevVpnRouteState.fromMap(Map<String, dynamic> data) =>
      LocalDevVpnRouteState(
        reachable: data['reachable'] == true,
        host: data['host']?.toString() ?? '',
        port: (data['port'] as num?)?.toInt() ?? 0,
        elapsedMs: (data['elapsedMs'] as num?)?.toInt() ?? 0,
        state: data['state']?.toString() ?? 'unknown',
        networkState: data['networkState']?.toString() ?? 'unknown',
        errorDomain: data['errorDomain']?.toString(),
        errorCode: data['errorCode']?.toString(),
        errorDescription: data['errorDescription']?.toString(),
      );

  static const expectedHost = '10.7.0.1';
  static const expectedPort = 49152;

  final bool reachable;
  final String host;
  final int port;
  final int elapsedMs;
  final String state;
  final String networkState;
  final String? errorDomain;
  final String? errorCode;
  final String? errorDescription;
}

class StikjitLaunchResult {
  const StikjitLaunchResult({
    required this.pid,
    required this.bundleId,
    required this.txmPresent,
    required this.gameUrlOpened,
    required this.logs,
  });
  final int pid;
  final String? bundleId;
  final bool? txmPresent;
  final bool? gameUrlOpened;
  final List<String> logs;
}
