import 'package:flutter/services.dart';

/// Control plane only: no frame-by-frame data crosses a Flutter channel.
class NeoSwap {
  NeoSwap._();
  static const channel = MethodChannel('neostation/neo_swap');
  static const probeSizesMiB = [64, 128, 512, 1024, 2048, 4096, 8192];

  static Future<Map<String, dynamic>> snapshot() => _call('snapshot');
  static Future<Map<String, dynamic>> probe() => _call('probe');

  /// Compatibility diagnostic alias. Production builds refuse synthetic probes;
  /// this never allocates RAM for an emulator or changes its automatic budget.
  static Future<Map<String, dynamic>> allocateMaxMemory(int sizeMiB) =>
      capacityProbe(sizeMiB);

  /// Compatibility alias for the production broker's measured diagnostics.
  static Future<Map<String, dynamic>> getMemoryStats() => snapshot();

  /// Optional regenerable shader cache; applies on the next game launch.
  static Future<Map<String, dynamic>> setShaderStorage(bool enabled) =>
      _call('setShaderStorage', {'enabled': enabled});
  static Future<Map<String, dynamic>> capacityProbe(int sizeMiB) {
    if (!probeSizesMiB.contains(sizeMiB)) {
      throw ArgumentError.value(sizeMiB, 'sizeMiB');
    }
    return _call('capacityProbe', {'sizeMiB': sizeMiB});
  }

  static Future<Map<String, dynamic>> _call(
    String method, [
    Object? args,
  ]) async {
    final response = await channel.invokeMapMethod<String, dynamic>(
      method,
      args,
    );
    if (response == null) throw StateError('NeoSwap returned no response');
    return Map<String, dynamic>.from(response);
  }
}
