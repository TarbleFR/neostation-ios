import 'dart:io';

import 'package:external_folder_access/external_folder_access.dart';
import 'package:neostation/services/jit_backend_preference_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/stikjit_rpcs3_service.dart';

/// RPCS3 iOS JIT launcher.
///
/// Integrated builds launch RPCS3 through the dedicated StikJIT bridge. The
/// single global emergency switch in Settings > Tools preserves the original
/// StikDebug Universal JIT request as an explicit fallback. RPCS3 remains
/// responsible for its native Start/game selection screen because the current
/// iOS port does not expose a supported direct-game callback.
abstract final class Rpcs3LaunchService {
  static const String targetBundleId = 'com.xitrix.RPCS3';

  static final LoggerService _log = LoggerService.instance;
  static final RegExp _titleIdPattern = RegExp(r'^[A-Z0-9._-]{3,32}$');

  static String? normalizeTitleId(String? value) {
    final titleId = value?.trim().toUpperCase() ?? '';
    return _titleIdPattern.hasMatch(titleId) ? titleId : null;
  }

  /// Compatibility hook used by application startup.
  static Future<void> initialize() async {}

  /// Starts RPCS3 with the JIT backend selected in Settings > Tools.
  ///
  /// [displayTitle], [sourcePath], and [sourceKind] are retained for diagnostics
  /// and future direct-launch support. RPCS3 currently performs game selection.
  static Future<bool> launchTitle(
    String? rawTitleId, {
    String? displayTitle,
    String? sourcePath,
    String? sourceKind,
  }) async {
    if (!Platform.isIOS) return false;

    final titleId = normalizeTitleId(rawTitleId);
    if (titleId == null) return false;

    _log.i(
      'RPCS3 launch: titleId=$titleId '
      'title=${displayTitle?.trim() ?? ''} '
      'sourceKind=${sourceKind?.trim() ?? ''} '
      'sourcePath=${sourcePath?.trim() ?? ''}',
    );

    var useStikDebugFallback = false;
    try {
      useStikDebugFallback =
          await JitBackendPreferenceService.useStikDebugFallback();
    } catch (error, stackTrace) {
      _log.e(
        'Rpcs3LaunchService: failed to load the global JIT backend; '
        'keeping integrated StikJIT.',
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (!useStikDebugFallback &&
        StikJitRpcs3Service.isExperimentalEnabled) {
      _log.i('RPCS3 launch backend: integrated StikJIT.');
      return StikJitRpcs3Service.launch(
        titleId: titleId,
        displayTitle: displayTitle,
        sourcePath: sourcePath,
        sourceKind: sourceKind,
      );
    }

    _log.i(
      useStikDebugFallback
          ? 'RPCS3 launch backend: StikDebug emergency fallback.'
          : 'RPCS3 integrated StikJIT is unavailable in this build; using the stable StikDebug path.',
    );

    try {
      final opened = await ExternalFolderAccess.openJitRequest(
        targetBaseBundleId: targetBundleId,
        scriptName: 'universal.js',
        debugFileName: 'rpcs3_launch_debug.txt',
      );
      return opened == true;
    } catch (error, stack) {
      _log.e(
        'Rpcs3LaunchService: StikDebug JIT handoff failed for $titleId',
        error: error,
        stackTrace: stack,
      );
      return false;
    }
  }
}
