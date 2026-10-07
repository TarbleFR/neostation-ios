import 'package:flutter/services.dart';

/// Control plane only: no frame-by-frame data crosses a Flutter channel.
class NeoSwap {
  NeoSwap._();
  static const channel = MethodChannel('neostation/neo_swap');
  
  static const probeSizesMiB = [64, 128, 512, 1024, 2048, 4096, 8192];
  
  /// Allocate maximum memory for the emulator
  static Future<Map<String, dynamic>> allocateMaxMemory(int sizeMiB) async {
    final Map<String, dynamic> args = {'sizeMiB': sizeMiB};
    return await channel.invokeMethod('allocateMaxMemory', args);
  }
  
  /// Get current memory statistics
  static Future<Map<String, dynamic>> getMemoryStats() async {
    return await channel.invokeMethod('getMemoryStats');
  }
  
  /// Set shader storage preference
  static Future<Map<String, dynamic>> setShaderStorage(bool enabled) async {
    final Map<String, dynamic> args = {'enabled': enabled};
    return await channel.invokeMethod('setShaderStorage', args);
  }
  
  /// Probe memory capacity
  static Future<Map<String, dynamic>> probe() async {
    return await channel.invokeMethod('probe');
  }
  
  /// Get capacity probe results
  static Future<Map<String, dynamic>> capacityProbe(int sizeMiB) async {
    final Map<String, dynamic> args = {'sizeMiB': sizeMiB};
    return await channel.invokeMethod('capacityProbe', args);
  }
  
  /// Get current snapshot
  static Future<Map<String, dynamic>> snapshot() async {
    return await channel.invokeMethod('snapshot');
  }
}