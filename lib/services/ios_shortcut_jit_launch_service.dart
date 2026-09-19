import 'dart:io';

import 'package:neostation/services/jit_backend_preference_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/stikjit_melonx_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Runs the Apple Shortcut used by NeoStation's MeloNX iOS launch flow.
class IosShortcutJitLaunchService {
  IosShortcutJitLaunchService._();

  static final _log = LoggerService.instance;

  /// Keep these names in sync with the shared/user-created Shortcuts.
  /// The `+` characters are part of the actual Shortcut names and are
  /// percent-encoded by [Uri] below.
  static const String melonxShortcutName = 'NeoStation+MeloNX+JIT';

  /// One-time installer for the exact NeoStation MeloNX launch Shortcut.
  static const String _melonxShortcutInstallUrl =
      'https://www.icloud.com/shortcuts/84b9d0fbdd714c6c9596ba2e3c699031';

  static bool get hasMeloNXShortcutInstaller =>
      _melonxShortcutInstallUrl.startsWith('https://www.icloud.com/shortcuts/');


  /// Opens Apple's import sheet for the shared MeloNX Shortcut.
  static Future<bool> openMeloNXShortcutInstaller() async {
    if (!Platform.isIOS || !hasMeloNXShortcutInstaller) return false;

    try {
      return await launchUrl(
        Uri.parse(_melonxShortcutInstallUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      _log.e(
        'IosShortcutJitLaunchService: failed to open MeloNX installer: $e',
      );
      return false;
    }
  }

  /// Builds the canonical Shortcuts URL used by NeoStation to invoke an
  /// installed helper from outside the Shortcuts app.
  ///
  /// Keeping URL construction here guarantees the literal `+` characters in
  /// Shortcut names are encoded consistently everywhere.
  static Uri buildRunUri({required String shortcutName, String? input}) {
    final query = <String, String>{'name': shortcutName};
    if (input != null) {
      query['input'] = 'text';
      query['text'] = input;
    }

    return Uri(
      scheme: 'shortcuts',
      host: 'run-shortcut',
      queryParameters: query,
    );
  }

  /// Runs the selected JIT backend and optionally passes the emulator game URL.
  static Future<bool> run({required String shortcutName, String? input}) async {
    if (!Platform.isIOS) return false;

    var useStikDebugFallback = false;
    try {
      useStikDebugFallback =
          await JitBackendPreferenceService.useStikDebugFallback();
    } catch (error, stackTrace) {
      _log.e(
        'IosShortcutJitLaunchService: failed to load the global JIT backend; '
        'keeping integrated StikJIT.',
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (useStikDebugFallback) {
      _log.i(
        'IosShortcutJitLaunchService: global StikDebug fallback routes '
        '$shortcutName through its existing Shortcut.',
      );
    }

    // Keep the validated MeloNX path unchanged. The global emergency switch
    // only decides whether this branch is entered before anything is launched.
    if (!useStikDebugFallback &&
        shortcutName == melonxShortcutName &&
        input != null &&
        StikJitMeloNxService.isExperimentalEnabled) {
      return StikJitMeloNxService.launch(gameUrl: input);
    }


    final shortcutUri = buildRunUri(shortcutName: shortcutName, input: input);

    try {
      return await launchUrl(shortcutUri, mode: LaunchMode.externalApplication);
    } catch (e) {
      _log.e('IosShortcutJitLaunchService: failed to run $shortcutName: $e');
      return false;
    }
  }
}
