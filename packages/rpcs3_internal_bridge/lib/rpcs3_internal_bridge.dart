import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

class Rpcs3InternalBridge {
  Rpcs3InternalBridge._();

  static const MethodChannel _channel = MethodChannel(
    'neostation/rpcs3_internal',
  );
  static const MethodChannel _jitChannel = MethodChannel(
    'neostation/rpcs3_jit',
  );

  // Keep a process-lifetime handle so libRPCS3Core remains present in the
  // NeoStation image before StikJIT's Universal script attaches. Standalone
  // RPCS3 is launched with its Core already mapped; mirroring that ordering is
  // important because universal.js resolves/scopes its JIT traps against the
  // target's currently loaded images.
  static DynamicLibrary? _preloadedCore;

  /// Maps libRPCS3Core.dylib into the NeoStation process without initializing
  /// the emulator. JIT is deliberately *not* required here. The real runtime
  /// sequence is: map Core -> attach universal.js -> initialize Core -> finish
  /// the helper transaction -> install firmware / boot content.
  static Map<String, dynamic> preloadCoreImage({
    bool expandedJitRegion = true,
  }) {
    if (!Platform.isIOS) {
      return const <String, dynamic>{
        'success': false,
        'message': 'RPCS3 internal Core is available on iOS only.',
      };
    }
    if (_preloadedCore != null) {
      return const <String, dynamic>{
        'success': true,
        'alreadyLoaded': true,
        'abi': 30,
      };
    }

    Pointer<Utf8>? key;
    Pointer<Utf8>? value;
    try {
      // RPCS3 reads this policy while the dylib is mapped, before initialize.
      // Set it here so preloading cannot accidentally lock the Core into the
      // regular arena before the native bridge sees it.
      final setenv = DynamicLibrary.process().lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, Pointer<Utf8>, int)
      >('setenv');
      key = 'RPCS3_IOS_EXPANDED_JIT_ARENA'.toNativeUtf8();
      value = (expandedJitRegion ? '1' : '0').toNativeUtf8();
      if (setenv(key, value, 1) != 0) {
        return const <String, dynamic>{
          'success': false,
          'message': 'Unable to configure the RPCS3 expanded JIT arena.',
        };
      }

      final executable = Platform.resolvedExecutable;
      final separator = executable.lastIndexOf('/');
      if (separator <= 0) {
        return <String, dynamic>{
          'success': false,
          'message': 'Unable to resolve the NeoStation application bundle.',
        };
      }
      final corePath =
          '${executable.substring(0, separator)}/Frameworks/libRPCS3Core.dylib';
      if (!File(corePath).existsSync()) {
        return <String, dynamic>{
          'success': false,
          'message': 'Embedded libRPCS3Core.dylib is missing.',
          'path': corePath,
        };
      }

      final core = DynamicLibrary.open(corePath);
      final abi = core.lookupFunction<Uint32 Function(), int Function()>(
        'rpcs3_ios_abi_version',
      )();
      if (abi != 30) {
        return <String, dynamic>{
          'success': false,
          'message': 'Unsupported RPCS3 iOS ABI $abi (expected 30).',
          'abi': abi,
        };
      }
      _preloadedCore = core;
      return <String, dynamic>{
        'success': true,
        'alreadyLoaded': false,
        'abi': abi,
        'path': corePath,
      };
    } catch (error) {
      return <String, dynamic>{
        'success': false,
        'message': 'RPCS3 Core preload failed: $error',
      };
    } finally {
      if (key != null) malloc.free(key);
      if (value != null) malloc.free(value);
    }
  }

  static Future<Map<String, dynamic>> diagnostics() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('diagnostics') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> jitStatus() async =>
      Map<String, dynamic>.from(
        await _jitChannel.invokeMapMethod<String, dynamic>('status') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> prepareJit({
    required String pairingFilePath,
  }) async {
    // The standalone RPCS3 app already has its Core image mapped when
    // StikDebug attaches universal.js. Do the same in NeoStation. Loading the
    // image does not initialize RPCS3 and does not allocate its executable
    // arena; it only makes the Core/trap image visible to the debugger before
    // vAttach, avoiding the attach-time crash seen when the dylib appeared only
    // after the helper was already driving the target process.
    final preload = preloadCoreImage(expandedJitRegion: true);
    if (preload['success'] != true) {
      return <String, dynamic>{
        'success': false,
        'message': preload['message']?.toString() ??
            'RPCS3 Core could not be mapped before JIT attachment.',
        'corePreload': preload,
      };
    }

    final response = Map<String, dynamic>.from(
      await _jitChannel.invokeMapMethod<String, dynamic>('prepareJit', {
            'pairingFilePath': pairingFilePath,
          }) ??
          const <String, dynamic>{},
    );
    response['corePreloaded'] = true;
    response['corePreloadAbi'] = preload['abi'];
    return response;
  }

  static Future<Map<String, dynamic>> initialize({
    required String supportPath,
    required String cachePath,
    bool expandedJitRegion = true,
  }) async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>('initialize', {
          'supportPath': supportPath,
          'cachePath': cachePath,
          'expandedJitRegion': expandedJitRegion,
        }) ??
        const <String, dynamic>{},
  );

  /// Call only after initialize has prepared and sealed the Core JIT arena.
  static Future<Map<String, dynamic>> completeJit() async =>
      Map<String, dynamic>.from(
        await _jitChannel.invokeMapMethod<String, dynamic>('completeJit') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> shutdown() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('shutdown') ??
            const <String, dynamic>{},
      );

  static Future<String> firmwareVersion() async =>
      (await _channel.invokeMethod<String>('firmwareVersion')) ?? '';

  static Future<Map<String, dynamic>> installFirmware(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('installFirmware', {
              'path': path,
            }) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> installPackage(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('installPackage', {
              'path': path,
            }) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> installIso(
    String path, {
    String? keyPath,
  }) async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>('installIso', {
          'path': path,
          if (keyPath != null) 'keyPath': keyPath,
        }) ??
        const <String, dynamic>{},
  );

  static Future<Map<String, dynamic>> installZip(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('installZip', {
              'path': path,
            }) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> installFolder(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('installFolder', {
              'path': path,
            }) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> launchGame({
    required String titleId,
    String? savestateId,
  }) async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>('launchGame', {
          'titleId': titleId,
          if (savestateId != null) 'savestateId': savestateId,
        }) ??
        const <String, dynamic>{},
  );

  static Future<int> emulationState() async =>
      (await _channel.invokeMethod<int>('emulationState')) ?? 0;

  static Future<bool> stop() async =>
      (await _channel.invokeMethod<bool>('stop')) ?? false;
}
