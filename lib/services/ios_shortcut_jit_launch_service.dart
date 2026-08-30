import 'dart:io';

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

  /// Runs an installed Shortcut and optionally passes text input to it.
  static Future<bool> run({required String shortcutName, String? input}) async {
    if (!Platform.isIOS) return false;

    // Experimental builds can replace only the MeloNX Shortcut hop with the
    // built-in StikJIT bridge. ARMSX2 and every normal build keep the exact
    // existing Shortcut behaviour.
    if (shortcutName == melonxShortcutName &&
        input != null &&
        StikJitMeloNxService.isExperimentalEnabled) {
      return StikJitMeloNxService.launch(gameUrl: input);
    }

    // ARMSX2 uses a second, independent built-in StikJIT route. Keeping this
    // condition separate preserves the validated MeloNX branch and leaves the
    // existing Shortcut as the fallback for normal builds.
    if (shortcutName == armsx2ShortcutName &&
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
