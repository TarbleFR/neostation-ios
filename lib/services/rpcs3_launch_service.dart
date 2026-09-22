import 'dart:io';

import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/rpcs3_game_profile_service.dart';
import 'package:neostation/services/rpcs3_internal_service.dart';

/// Direct launcher for the in-process RPCS3 engine.
///
/// NeoStation enables JIT for its own process and calls the embedded RPCS3
/// Core's `rpcs3_ios_boot_game` entry point directly. No external RPCS3
/// application is queried, opened or foregrounded.
abstract final class Rpcs3LaunchService {
  static final LoggerService _log = LoggerService.instance;
  static String? _lastError;
  static String? _lastErrorCode;

  static String? get lastError => _lastError;
  static String? get lastErrorCode => _lastErrorCode;

  static String? normalizeTitleId(String? value) {
    return Rpcs3GameProfileService.normalizeSerial(value);
  }

  static Future<void> initialize() async {
    if (!Platform.isIOS) return;
    await Rpcs3InternalService.rootDirectory();
  }

  static Future<bool> launchTitle(
    String? rawTitleId, {
    required String uiLocale,
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
      // One entry point owns the whole startup. Do not pre-initialize RPCS3,
      // apply a launch-time profile, retry, poll, or start a second boot.
      await Rpcs3InternalService.ensureGameplayInitialized();
      return await Rpcs3InternalService.launchTitle(
        titleId,
        uiLocale: uiLocale,
      );
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
