import 'package:flutter/services.dart';

class StikjitBridge {
  StikjitBridge._();

  static const MethodChannel _channel = MethodChannel('neostation/stikjit');
  static const MethodChannel _armsx2Channel = MethodChannel(
    'neostation/stikjit_armsx2',
  );
  static const MethodChannel _rpcs3Channel = MethodChannel(
    'neostation/stikjit_rpcs3',
  );

  static Future<StikjitLaunchResult> enableMeloNxJit({
    required String pairingFilePath,
    required String bundleId,
    required String gameUrl,
  }) async {
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
    bool autoLoadLastGame = false,
  }) async {
    final raw = await _armsx2Channel.invokeMethod<Object?>('enableArmsx2Jit', {
      'pairingFilePath': pairingFilePath,
      'bundleId': bundleId,
      'gameUrl': gameUrl,
      // Native preference detection now takes priority. This remains the
      // compatibility fallback when the ARMSX2 container cannot be inspected.
      'autoLoadLastGame': autoLoadLastGame,
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
      postJitHandoffSkipped:
          data['postJitHandoffSkipped'] as bool? ?? false,
      targetResumed: data['targetResumed'] as bool? ?? false,
      detectedAutoLoadLastGame: data['detectedAutoLoadLastGame'] as bool?,
      effectiveAutoLoadLastGame: data['effectiveAutoLoadLastGame'] as bool?,
      autoLoadModeSource: data['autoLoadModeSource']?.toString(),
      detectedAutoLoadPreferenceKey:
          data['detectedAutoLoadPreferenceKey']?.toString(),
      logs: logs,
    );
  }

  static Future<StikjitLaunchResult> enableRpcs3Jit({
    required String pairingFilePath,
    required String bundleId,
    required String titleId,
  }) async {
    final raw = await _rpcs3Channel.invokeMethod<Object?>('enableRpcs3Jit', {
      'pairingFilePath': pairingFilePath,
      'bundleId': bundleId,
      'titleId': titleId,
    });

    if (raw is! Map) {
      throw StateError('RPCS3 StikJIT bridge returned an invalid response.');
    }

    final data = Map<String, dynamic>.from(raw);
    final pidValue = data['pid'];
    if (pidValue is! num) {
      throw StateError('RPCS3 StikJIT bridge did not return the target PID.');
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

class StikjitLaunchResult {
  const StikjitLaunchResult({
    required this.pid,
    required this.bundleId,
    required this.txmPresent,
    required this.gameUrlOpened,
    this.postJitHandoffSkipped = false,
    this.targetResumed = false,
    this.detectedAutoLoadLastGame,
    this.effectiveAutoLoadLastGame,
    this.autoLoadModeSource,
    this.detectedAutoLoadPreferenceKey,
    required this.logs,
  });

  final int pid;
  final String? bundleId;
  final bool? txmPresent;
  final bool? gameUrlOpened;
  final bool postJitHandoffSkipped;
  final bool targetResumed;
  final bool? detectedAutoLoadLastGame;
  final bool? effectiveAutoLoadLastGame;
  final String? autoLoadModeSource;
  final String? detectedAutoLoadPreferenceKey;
  final List<String> logs;
}
