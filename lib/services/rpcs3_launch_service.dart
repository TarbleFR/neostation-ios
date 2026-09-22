import 'dart:async';
import 'dart:io';

import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/rpcs3_game_profile_service.dart';
import 'package:neostation/services/rpcs3_internal_service.dart';
import 'package:rpcs3_internal_bridge/rpcs3_internal_bridge.dart';

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

  /// Publishes the serial-keyed, partial profile before boot.
  ///
  /// No global RPCS3 setting is mutated here. The Core layers only this game's
  /// managed keys over the global configuration selected by the user.
  static Future<void> _applyMobileBootProfile(String titleId) async {
    await Rpcs3InternalService.ensureGameplayInitialized();
    final report = await Rpcs3GameProfileService.applyForLaunch(titleId);
    if (report['success'] != true) {
      throw Rpcs3InternalException(
        'gameProfileFailed',
        report['message']?.toString() ??
            'RPCS3 could not load the serial-specific compatibility profile.',
      );
    }
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
      await _applyMobileBootProfile(titleId);
      // The native boot result is authoritative. Do not poll progress, abort a
      // long compilation, stop emulation, clear caches, or start a second boot
      // from the Dart launch path.
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
