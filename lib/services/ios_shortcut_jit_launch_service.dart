import 'dart:io';

import 'package:neostation/services/jit_backend_preference_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/stikjit_armsx2_service.dart';
import 'package:neostation/services/stikjit_melonx_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Runs the Apple Shortcuts used by NeoStation's MeloNX and ARMSX2 iOS launch
/// flows and opens their one-time installation/setup links.
class IosShortcutJitLaunchService {
  IosShortcutJitLaunchService._();

  static final _log = LoggerService.instance;

  /// Keep these names in sync with the shared/user-created Shortcuts.
  /// The `+` characters are part of the actual Shortcut names and are
  /// percent-encoded by [Uri] below.
  static const String melonxShortcutName = 'NeoStation+MeloNX+JIT';
  static const String armsx2ShortcutName = 'NeoStation+ARMSX2+JIT';

  /// One-time installer for the exact NeoStation MeloNX launch Shortcut.
  static const String _melonxShortcutInstallUrl =
      'https://www.icloud.com/shortcuts/84b9d0fbdd714c6c9596ba2e3c699031';

  /// One-time installer for the exact NeoStation ARMSX2 launch Shortcut.
  static const String _armsx2ShortcutInstallUrl =
      'https://www.icloud.com/shortcuts/1419632b150747f5bcd7b9bc65e36114';

  static bool get hasMeloNXShortcutInstaller =>
      _melonxShortcutInstallUrl.startsWith('https://www.icloud.com/shortcuts/');

  static bool get hasArmsx2ShortcutInstaller =>
      _armsx2ShortcutInstallUrl.startsWith('https://www.icloud.com/shortcuts/');

  /// Opens the shared ARMSX2 launch Shortcut. While the iCloud sharing link
  /// is not configured yet, fall back to Apple's official create-shortcut URL.
  static Future<bool> openArmsx2ShortcutInstaller() async {
    if (!Platform.isIOS) return false;

    final target = hasArmsx2ShortcutInstaller
        ? Uri.parse(_armsx2ShortcutInstallUrl)
        : Uri.parse('shortcuts://create-shortcut');

    try {
      return await launchUrl(target, mode: LaunchMode.externalApplication);
    } catch (e) {
      _log.e('IosShortcutJitLaunchService: failed to open ARMSX2 setup: $e');
      return false;
    }
  }

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

    // ARMSX2 remains a second independent integrated path. When the emergency
    // switch is on, execution skips this branch and naturally reaches the old
    // StikDebug Shortcut below.
    if (!useStikDebugFallback &&
        shortcutName == armsx2ShortcutName &&
        input != null &&
        StikJitArmsx2Service.isExperimentalEnabled) {
      return StikJitArmsx2Service.launch(gameUrl: input);
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
