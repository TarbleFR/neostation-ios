import 'dart:io';

import 'package:neostation/services/logger_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Runs the Apple Shortcuts used by NeoStation's iOS emulator launch flows and
/// opens their one-time installation/setup links.
class IosShortcutJitLaunchService {
  IosShortcutJitLaunchService._();

  static final _log = LoggerService.instance;

  /// Keep these names in sync with the shared/user-created Shortcuts.
  /// The `+` characters are part of the actual Shortcut names and are
  /// percent-encoded by [Uri] below.
  static const String melonxShortcutName = 'NeoStation+MeloNX+JIT';
  static const String armsx2ShortcutName = 'NeoStation+ARMSX2+JIT';
  static const String finShortcutName = 'NeoStation+Fin';

  /// One-time installer for the exact NeoStation MeloNX launch Shortcut.
  static const String _melonxShortcutInstallUrl =
      'https://www.icloud.com/shortcuts/84b9d0fbdd714c6c9596ba2e3c699031';

  /// One-time installer for the exact NeoStation ARMSX2 launch Shortcut.
  static const String _armsx2ShortcutInstallUrl =
      'https://www.icloud.com/shortcuts/1419632b150747f5bcd7b9bc65e36114';

  /// Fin's Shortcut is being built together with NeoStation. Leave this empty
  /// until the final `NeoStation+Fin` Shortcut is shared through iCloud.
  static const String _finShortcutInstallUrl = '';

  static bool get hasMeloNXShortcutInstaller =>
      _melonxShortcutInstallUrl.startsWith('https://www.icloud.com/shortcuts/');

  static bool get hasArmsx2ShortcutInstaller =>
      _armsx2ShortcutInstallUrl.startsWith('https://www.icloud.com/shortcuts/');

  static bool get hasFinShortcutInstaller =>
      _finShortcutInstallUrl.startsWith('https://www.icloud.com/shortcuts/');

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

  /// Opens the shared Fin Shortcut when available. Until we publish that iCloud
  /// link, this deliberately opens Apple's create-shortcut screen so the card
  /// remains useful while the Shortcut is being assembled and tested.
  static Future<bool> openFinShortcutInstaller() async {
    if (!Platform.isIOS) return false;

    final target = hasFinShortcutInstaller
        ? Uri.parse(_finShortcutInstallUrl)
        : Uri.parse('shortcuts://create-shortcut');

    try {
      return await launchUrl(target, mode: LaunchMode.externalApplication);
    } catch (e) {
      _log.e('IosShortcutJitLaunchService: failed to open Fin setup: $e');
      return false;
    }
  }

  /// Builds the canonical Shortcuts URL used by NeoStation to invoke an
  /// installed helper from outside the Shortcuts app.
  ///
  /// Keeping URL construction here guarantees the literal `+` characters in
  /// Shortcut names are encoded consistently everywhere.
  static Uri buildRunUri({
    required String shortcutName,
    String? input,
  }) {
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
  static Future<bool> run({
    required String shortcutName,
    String? input,
  }) async {
    if (!Platform.isIOS) return false;

    final shortcutUri = buildRunUri(
      shortcutName: shortcutName,
      input: input,
    );

    try {
      return await launchUrl(shortcutUri, mode: LaunchMode.externalApplication);
    } catch (e) {
      _log.e('IosShortcutJitLaunchService: failed to run $shortcutName: $e');
      return false;
    }
  }
}
