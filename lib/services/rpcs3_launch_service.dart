import 'dart:io';

import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/rpcs3_internal_service.dart';
import 'package:rpcs3_internal_bridge/rpcs3_internal_bridge.dart';

/// Direct launcher for the in-process RPCS3 engine.
///
/// NeoStation enables JIT for its own process and calls the embedded RPCS3
/// Core's `rpcs3_ios_boot_game` entry point directly. No external RPCS3
/// application is queried, opened or foregrounded.
abstract final class Rpcs3LaunchService {
  static final LoggerService _log = LoggerService.instance;
  static final RegExp _titleIdPattern = RegExp(r'^[A-Z0-9._-]{3,32}$');

  static String? _lastError;
  static String? _lastErrorCode;

  static String? get lastError => _lastError;
  static String? get lastErrorCode => _lastErrorCode;

  static String? normalizeTitleId(String? value) {
    final titleId = value?.trim().toUpperCase() ?? '';
    return _titleIdPattern.hasMatch(titleId) ? titleId : null;
  }

  static Future<void> initialize() async {
    if (!Platform.isIOS) return;
    await Rpcs3InternalService.rootDirectory();
  }

  /// Applies the iOS mobile boot profile exposed by our RPCS3 Core.
  ///
  /// Up-front PPU/SPU LLVM precompilation can spend minutes in "Building SPU
  /// Cache" on iPhone and, for some titles, never reach the game. RPCS3's own
  /// runtime explicitly supports stopping that precompile and compiling the
  /// remaining blocks on demand. Keep the persistent cache directory intact,
  /// but skip the blocking precompile and let RPCS3 choose its memory-safe LLVM
  /// worker count (0 = automatic on iOS).
  static Future<void> _applyMobileBootProfile() async {
    await Rpcs3InternalService.ensureGameplayInitialized();
    const settings = <String, String>{
      'advanced.llvm_precompilation': 'false',
      'emulator.max_llvm_threads': '0',
    };

    for (final entry in settings.entries) {
      final report = await Rpcs3InternalBridge.setSetting(entry.key, entry.value);
      if (report['success'] != true) {
        _log.i(
          'RPCS3 mobile boot setting ${entry.key}=${entry.value} was not applied: '
          '${report['message'] ?? 'unknown Core response'}',
        );
      }
    }
  }

  static Future<bool> launchTitle(
    String? rawTitleId, {
    String? displayTitle,
    String? sourcePath,
    String? sourceKind,
  }) async {
    if (!Platform.isIOS) return false;
    final titleId = normalizeTitleId(rawTitleId);
    if (titleId == null) return false;

    _lastError = null;
    _lastErrorCode = null;
    _log.i(
      'RPCS3 internal launch: titleId=$titleId '
      'title=${displayTitle?.trim() ?? ''} '
      'sourceKind=${sourceKind?.trim() ?? ''} '
      'sourcePath=${sourcePath?.trim() ?? ''}',
    );

    try {
      await _applyMobileBootProfile();
      return await Rpcs3InternalService.launchTitle(titleId);
    } on Rpcs3InternalException catch (error, stackTrace) {
      _lastError = error.message;
      _lastErrorCode = error.code;
      _log.e(
        'RPCS3 internal launch failed at ${error.code}: ${error.message}',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    } catch (error, stackTrace) {
      _lastError = error.toString();
      _lastErrorCode = 'unknown';
      _log.e(
        'RPCS3 internal launch failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }
}
