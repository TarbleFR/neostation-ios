import 'dart:io';

import 'package:external_folder_access/external_folder_access.dart';
import 'package:neostation/services/logger_service.dart';

/// Stable RPCS3 iOS launcher.
///
/// NeoStation requests StikDebug Universal JIT for RPCS3, then leaves RPCS3
/// responsible for its native Start/Commencer screen and game selection.
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

  /// Opens StikDebug with its Universal JIT request for RPCS3.
  ///
  /// [displayTitle], [sourcePath], and [sourceKind] are retained for diagnostics
  /// and compatibility with existing callers. RPCS3 performs game selection.
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
      'RPCS3 standard launch: titleId=$titleId '
      'title=${displayTitle?.trim() ?? ''} '
      'sourceKind=${sourceKind?.trim() ?? ''} '
      'sourcePath=${sourcePath?.trim() ?? ''}',
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
        'Rpcs3LaunchService: standard JIT handoff failed for $titleId',
        error: error,
        stackTrace: stack,
      );
      return false;
    }
  }
}
