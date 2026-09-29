import 'package:flutter/services.dart';

/// Control plane only: no frame-by-frame data crosses a Flutter channel.
class NeoSwap {
  NeoSwap._();
  static const channel = MethodChannel('neostation/neo_swap');
  static const capacitiesMiB = [0, 512, 1024, 2048, 4096, 8192];
  static const probeSizesMiB = [64, 128, 512, 1024, 2048, 4096, 8192];

  static Future<Map<String, dynamic>> snapshot() => _call('snapshot');
  static Future<Map<String, dynamic>> configure(int capacityMiB) {
    if (!capacitiesMiB.contains(capacityMiB)) {
      throw ArgumentError.value(capacityMiB, 'capacityMiB');
    }
    return _call('configure', {'capacityMiB': capacityMiB});
  }

  static Future<Map<String, dynamic>> probe() => _call('probe');
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
