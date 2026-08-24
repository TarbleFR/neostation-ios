import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/sqlite_config_provider.dart';
import '../screens/systems_screen/fork_first_run_onboarding.dart';
import '../services/ios_emulator_preference_service.dart';
import 'ios_emulator_choice_screen.dart';
import 'setup_wizard.dart';
import 'shimmering_logo.dart';

/// Widget that checks the initial configuration and shows the first-run flow if necessary.
class PermissionCheckWrapper extends StatefulWidget {
  final Widget child;

  static const String setupCompletedKey = 'setup_completed_prefs';

  const PermissionCheckWrapper({super.key, required this.child});

  @override
  State<PermissionCheckWrapper> createState() => _PermissionCheckWrapperState();
}

class _PermissionCheckWrapperState extends State<PermissionCheckWrapper> {
  bool _needsSetup = false;
  bool _isChecking = true;
  bool _showForkWelcomeGate = false;
  bool _showEmulatorChoiceGate = false;
  bool _upgradeOfferScheduled = false;

  static final _log = LoggerService.instance;

  @override
  void initState() {
    super.initState();

    // Check whether initial configuration is needed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkInitialSetup();
    });
  }

  Future<void> _checkInitialSetup() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Fast-path: this flag survives SD-card unavailability and early-launcher
      // boot races. Existing installations must never be interrupted by the
      // fork's first-run welcome screen.
      if (prefs.getBool(PermissionCheckWrapper.setupCompletedKey) == true) {
        await prefs.setBool(forkOnboardingCompletedKey, true);
        if (!mounted) return;
        _pushWizardActive(false);
        setState(() {
          _needsSetup = false;
          _showForkWelcomeGate = false;
          _isChecking = false;
        });
        _scheduleExistingUserOffer();
        return;
      }

      if (!mounted) return;
      final configProvider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );

      if (!configProvider.initialized) {
        await configProvider.initialize();
      }

      final hasRomFolder = configProvider.config.romFolder?.isNotEmpty == true;
      final setupCompleted = configProvider.config.setupCompleted;

      if (hasRomFolder || setupCompleted) {
        // Backfill both preferences for users upgrading from an older build.
        await prefs.setBool(PermissionCheckWrapper.setupCompletedKey, true);
        await prefs.setBool(forkOnboardingCompletedKey, true);
        if (!mounted) return;
        _pushWizardActive(false);
        setState(() {
          _needsSetup = false;
          _showForkWelcomeGate = false;
          _isChecking = false;
        });
        _scheduleExistingUserOffer();
        return;
      }

      // Genuinely fresh install. Show the fork welcome screen first. If it was
      // already confirmed before an interrupted setup, resume directly in
      // NeoStation's normal SetupWizard instead.
      final welcomeGateCompleted =
          prefs.getBool(forkOnboardingCompletedKey) ?? false;
      final hasEmulatorChoice =
          !Platform.isIOS ||
          await IosEmulatorPreferenceService.hasPrimaryChoice();

      if (!mounted) return;
      _pushWizardActive(true);
      setState(() {
        _needsSetup = true;
        _showForkWelcomeGate = !welcomeGateCompleted;
        _showEmulatorChoiceGate = welcomeGateCompleted && !hasEmulatorChoice;
        _isChecking = false;
      });
    } catch (e) {
      _log.e('Error checking initial setup: $e');
      if (!mounted) return;
      _pushWizardActive(false);
      setState(() {
        _needsSetup = false;
        _showForkWelcomeGate = false;
        _isChecking = false;
      });
    }
  }

  /// Mirrors "the wizard is on screen" to the secondary display, which parks
  /// its app dock and launcher while setup runs. Pushed from here — the single
  /// place that decides whether the wizard shows — so a normal boot also clears
  /// a flag left behind by a run that was killed mid-wizard.
  void _pushWizardActive(bool active) {
    if (!mounted) return;
    Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    ).setSetupWizardActive(active);
  }

  Future<void> _completeForkWelcomeGate() async {
    // Switch to NeoStation's normal SetupWizard immediately. Preference I/O is
    // intentionally done after the visual transition so tapping Continue never
    // appears to hang on slower iOS storage.
    if (!mounted) return;
    final hasChoice =
        !Platform.isIOS ||
        await IosEmulatorPreferenceService.hasPrimaryChoice();
    if (!mounted) return;
    setState(() {
      _showForkWelcomeGate = false;
      _showEmulatorChoiceGate = !hasChoice;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(forkOnboardingCompletedKey, true);
    } catch (e) {
      // A preference write failure must not trap the user before setup. The
      // device language has already been applied by the welcome screen.
      _log.w('Could not persist first-run welcome state: $e');
    }
  }

  void _scheduleExistingUserOffer() {
    if (!Platform.isIOS || _upgradeOfferScheduled) return;
    _upgradeOfferScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          !await IosEmulatorPreferenceService.shouldShowUpgradeOffer()) {
        return;
      }
      if (!mounted) return;
      final choice = await showDialog<IosLibraryEmulator>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Manic EMU is now supported'),
          content: const Text(
            'NeoStation can now launch games with Manic EMU. You can make it '
            'your main emulator now, keep RetroArch, or change this later in '
            'Settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Not now'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                IosLibraryEmulator.retroArch,
              ),
              child: const Text('Keep RetroArch'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                IosLibraryEmulator.manicEmu,
              ),
              child: const Text('Use Manic EMU'),
            ),
          ],
        ),
      );
      if (choice != null) {
        await IosEmulatorPreferenceService.setPrimary(choice);
      }
      await IosEmulatorPreferenceService.markUpgradeOfferSeen();
    });
  }

  void _completeSetup() async {
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    await configProvider.completeSetup();

    // Setup is done — let the secondary display bring in the dock/launcher.
    configProvider.setSetupWizardActive(false);

    // Persist flag to SharedPreferences so the wizard is never shown again
    // even if the SQLite DB is temporarily inaccessible (e.g. SD card not ready).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(PermissionCheckWrapper.setupCompletedKey, true);
    await prefs.setBool(forkOnboardingCompletedKey, true);

    if (!mounted) return;
    setState(() {
      _needsSetup = false;
      _showForkWelcomeGate = false;
      _showEmulatorChoiceGate = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      // Show loading while checking — same shimmering logo as the rest of the
      // startup chain, so this gate doesn't read as a separate plain screen.
      return const Scaffold(body: Center(child: ShimmeringLogo()));
    }

    if (_needsSetup) {
      if (_showForkWelcomeGate) {
        return Scaffold(
          body: ForkFirstRunOnboarding(
            onFinished: _completeForkWelcomeGate,
          ),
        );
      }

      if (_showEmulatorChoiceGate) {
        return IosEmulatorChoiceScreen(
          onFinished: () {
            if (mounted) setState(() => _showEmulatorChoiceGate = false);
          },
        );
      }

      // Continue with NeoStation's original configuration wizard in the
      // language automatically selected from the iPhone/iPad locale.
      return SetupWizard(onComplete: _completeSetup);
    }

    // Show the normal app.
    return widget.child;
  }
}
