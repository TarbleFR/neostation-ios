import 'package:flutter/services.dart';

class StikjitBridge {
  StikjitBridge._();

  static const MethodChannel _channel = MethodChannel('neostation/stikjit');

  static Future<StikjitLaunchResult> enableMeloNxJit({
    required String pairingFilePath,
    required String bundleId,
  }) async {
    final raw = await _channel.invokeMethod<Object?>('enableMeloNxJit', {
      'pairingFilePath': pairingFilePath,
      'bundleId': bundleId,
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
      logs: logs,
    );
  }
}

class StikjitLaunchResult {
  const StikjitLaunchResult({
    required this.pid,
    required this.bundleId,
    required this.txmPresent,
    required this.logs,
  });

  final int pid;
  final String? bundleId;
  final bool? txmPresent;
  final List<String> logs;
}
