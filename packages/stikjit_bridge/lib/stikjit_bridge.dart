import 'package:flutter/services.dart';

class StikjitBridge {
  StikjitBridge._();

  static const MethodChannel _channel = MethodChannel('neostation/stikjit');
  static const MethodChannel _armsx2Channel = MethodChannel(
    'neostation/stikjit_armsx2',
  );

  static Future<LocalJitTunnelState> ensureLocalTunnel() async {
    final raw = await _channel.invokeMethod<Object?>('ensureLocalTunnel');
    if (raw is! Map) {
      throw StateError('NeoStation local tunnel returned an invalid response.');
    }
    return LocalJitTunnelState.fromMap(Map<String, dynamic>.from(raw));
  }

  static Future<LocalJitTunnelState> localTunnelStatus() async {
    final raw = await _channel.invokeMethod<Object?>('localTunnelStatus');
    if (raw is! Map) {
      throw StateError('NeoStation local tunnel returned an invalid status.');
    }
    return LocalJitTunnelState.fromMap(Map<String, dynamic>.from(raw));
  }

  static Future<LocalJitTunnelState> disableLocalTunnel() async {
    final raw = await _channel.invokeMethod<Object?>('disableLocalTunnel');
    if (raw is! Map) {
      throw StateError('NeoStation local tunnel returned an invalid status.');
    }
    return LocalJitTunnelState.fromMap(Map<String, dynamic>.from(raw));
  }

  static Future<StikjitLaunchResult> enableMeloNxJit({
    required String pairingFilePath,
    required String bundleId,
    required String gameUrl,
  }) async {
    await ensureLocalTunnel();
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
    await ensureLocalTunnel();
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

class LocalJitTunnelState {
  const LocalJitTunnelState({
    required this.active,
    required this.status,
    required this.managedByNeoStation,
    required this.configured,
    required this.authorized,
    required this.enabled,
    required this.interfaceAddress,
    required this.peerAddress,
    required this.onDemand,
  });

  factory LocalJitTunnelState.fromMap(Map<String, dynamic> data) =>
      LocalJitTunnelState(
        active: data['active'] == true,
        status: data['status']?.toString() ?? 'unknown',
        managedByNeoStation: data['managedByNeoStation'] == true,
        configured: data['configured'] == true,
        authorized: data['authorized'] == true,
        enabled: data['enabled'] == true,
        interfaceAddress: data['interfaceAddress']?.toString(),
        peerAddress: data['peerAddress']?.toString(),
        onDemand: data['onDemand'] == true,
      );

  final bool active;
  final String status;
  final bool managedByNeoStation;
  final bool configured;
  final bool authorized;
  final bool enabled;
  final String? interfaceAddress;
  final String? peerAddress;
  final bool onDemand;
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
