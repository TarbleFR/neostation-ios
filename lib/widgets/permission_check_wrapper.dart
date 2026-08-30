import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/pairing_file_service.dart';
import 'package:neostation/services/stikjit_melonx_service.dart';
import '../providers/sqlite_config_provider.dart';
import '../screens/systems_screen/fork_first_run_onboarding.dart';
import 'pairing_file_onboarding.dart';
import 'setup_wizard.dart';
import 'shimmering_logo.dart';

/// Widget that checks the initial configuration and shows the first-run flow if necessary.
class PermissionCheckWrapper extends StatefulWidget {
  final Widget child;

  static const String setupCompletedKey = 'setup_completed_prefs';
  static const String pairingOnboardingCompletedKey =
      'pairing_file_onboarding_completed';

  const PermissionCheckWrapper({super.key, required this.child});

  @override
  State<PermissionCheckWrapper> createState() => _PermissionCheckWrapperState();
}

class _PermissionCheckWrapperState extends State<PermissionCheckWrapper> {
  bool _needsSetup = false;
  bool _isChecking = true;
  bool _showForkWelcomeGate = false;
  bool _showPairingFileGate = false;

  static final _log = LoggerService.instance;

  bool get _supportsPairingGate =>
      Platform.isIOS && StikJitMeloNxService.isExperimentalEnabled;

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
      // boot races. Existing installations must never be interrupted by a new
      // onboarding screen added by the iOS fork.
      if (prefs.getBool(PermissionCheckWrapper.setupCompletedKey) == true) {
        await prefs.setBool(forkOnboardingCompletedKey, true);
        if (!mounted) return;
        _pushWizardActive(false);
        setState(() {
          _needsSetup = false;
          _showForkWelcomeGate = false;
          _showPairingFileGate = false;
          _isChecking = false;
        });
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
        // Backfill preferences for users upgrading from an older build.
        await prefs.setBool(PermissionCheckWrapper.setupCompletedKey, true);
        await prefs.setBool(forkOnboardingCompletedKey, true);
        if (!mounted) return;
        _pushWizardActive(false);
        setState(() {
          _needsSetup = false;
          _showForkWelcomeGate = false;
          _showPairingFileGate = false;
          _isChecking = false;
        });
        return;
      }

      // Genuinely fresh install. Show the fork welcome screen first. If it was
      // already confirmed before an interrupted setup, resume at the next gate.
      final welcomeGateCompleted =
          prefs.getBool(forkOnboardingCompletedKey) ?? false;

      var pairingGateCompleted =
          prefs.getBool(PermissionCheckWrapper.pairingOnboardingCompletedKey) ??
          false;

      if (_supportsPairingGate && !pairingGateCompleted) {
        try {
          if (await PairingFileService.hasStoredPairingFile()) {
            pairingGateCompleted = true;
            await prefs.setBool(
              PermissionCheckWrapper.pairingOnboardingCompletedKey,
              true,
            );
          }
        } catch (error) {
          _log.w('Could not inspect pairing-file onboarding state: $error');
        }
      }

      if (!mounted) return;
      _pushWizardActive(true);
      setState(() {
        _needsSetup = true;
        _showForkWelcomeGate = !welcomeGateCompleted;
        _showPairingFileGate =
            welcomeGateCompleted &&
            _supportsPairingGate &&
            !pairingGateCompleted;
        _isChecking = false;
      });
    } catch (e) {
      _log.e('Error checking initial setup: $e');
      if (!mounted) return;
      _pushWizardActive(false);
      setState(() {
        _needsSetup = false;
        _showForkWelcomeGate = false;
        _showPairingFileGate = false;
        _isChecking = false;
      });
    }
  }

  /// Mirrors "the wizard is on screen" to the secondary display, which parks
  /// its app dock and launcher while setup runs.
  void _pushWizardActive(bool active) {
    if (!mounted) return;
    Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    ).setSetupWizardActive(active);
  }

  Future<void> _completeForkWelcomeGate() async {
    if (!mounted) return;

    var showPairing = _supportsPairingGate;
    if (showPairing) {
      try {
        showPairing = !await PairingFileService.hasStoredPairingFile();
      } catch (_) {
        showPairing = true;
      }
    }

    if (!mounted) return;
    setState(() {
      _showForkWelcomeGate = false;
      _showPairingFileGate = showPairing;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(forkOnboardingCompletedKey, true);
      if (_supportsPairingGate && !showPairing) {
        await prefs.setBool(
          PermissionCheckWrapper.pairingOnboardingCompletedKey,
          true,
        );
      }
    } catch (e) {
      _log.w('Could not persist first-run welcome state: $e');
    }
  }

  Future<void> _completePairingFileGate() async {
    if (!mounted) return;
    setState(() => _showPairingFileGate = false);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(
        PermissionCheckWrapper.pairingOnboardingCompletedKey,
        true,
      );
    } catch (e) {
      // A preference write failure must not trap the user in onboarding.
      _log.w('Could not persist pairing-file onboarding state: $e');
    }
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
    // even if the SQLite DB is temporarily inaccessible.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(PermissionCheckWrapper.setupCompletedKey, true);
    await prefs.setBool(forkOnboardingCompletedKey, true);

    if (!mounted) return;
    setState(() {
      _needsSetup = false;
      _showForkWelcomeGate = false;
      _showPairingFileGate = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
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

      if (_showPairingFileGate) {
        return Scaffold(
          body: PairingFileOnboarding(
            onFinished: _completePairingFileGate,
          ),
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
