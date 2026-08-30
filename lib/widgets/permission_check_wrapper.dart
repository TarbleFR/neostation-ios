import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/services/ios_emulator_preference_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/pairing_file_service.dart';
import 'package:neostation/services/retroarch_library_service.dart';
import 'package:neostation/services/stikjit_melonx_service.dart';
import '../providers/sqlite_config_provider.dart';
import '../screens/systems_screen/fork_first_run_onboarding.dart';
import 'pairing_file_onboarding.dart';
import 'setup_wizard.dart';
import 'shimmering_logo.dart';

/// Checks the initial configuration and displays the first-run flow when needed.
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
  bool _isStartingRetroArchSync = false;
  bool _retroArchSyncStarted = false;

  static final _log = LoggerService.instance;

  bool get _supportsPairingGate =>
      Platform.isIOS && StikJitMeloNxService.isExperimentalEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkInitialSetup();
    });
  }

  Future<void> _checkInitialSetup() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Existing installations must never be interrupted by a newly added
      // onboarding step. The pairing file remains available in Settings > Tools.
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

      // Genuine fresh install. Keep the established RetroArch first-run flow,
      // inserting only the Pairing File gate before it.
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

      final pairingReady = !_supportsPairingGate || pairingGateCompleted;
      final hasPrimaryChoice =
          !Platform.isIOS ||
          await IosEmulatorPreferenceService.hasPrimaryChoice();

      if (!mounted) return;
      _pushWizardActive(true);
      setState(() {
        _needsSetup = true;
        _showForkWelcomeGate = !welcomeGateCompleted;
        _showPairingFileGate =
            welcomeGateCompleted && !pairingReady && _supportsPairingGate;
        _isChecking = false;
      });

      // If an interrupted first run already completed the two gates, resume the
      // exact RetroArch-first setup rather than waiting for another launch.
      if (welcomeGateCompleted && pairingReady && !hasPrimaryChoice) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _startFirstRunRetroArchFlow();
        });
      }
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

    if (!showPairing) {
      await _startFirstRunRetroArchFlow();
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

    await _startFirstRunRetroArchFlow();
  }

  /// Reuses NeoStation's established first-install RetroArch sequence:
  /// select RetroArch as the initial library, request its exported playlists,
  /// then let the unchanged SetupWizard activate the linked folder and await
  /// the real scan when NeoStation returns to the foreground.
  Future<void> _startFirstRunRetroArchFlow() async {
    if (!Platform.isIOS ||
        !mounted ||
        _retroArchSyncStarted ||
        _isStartingRetroArchSync) {
      return;
    }

    _retroArchSyncStarted = true;
    setState(() {
      _showForkWelcomeGate = false;
      _showPairingFileGate = false;
      _isStartingRetroArchSync = true;
    });

    try {
      await IosEmulatorPreferenceService.setPrimary(
        IosLibraryEmulator.retroArch,
      );
      await IosEmulatorPreferenceService.markUpgradeOfferSeen();

      final opened = await RetroArchLibraryService.requestLibrarySync();
      if (!opened) {
        _log.w(
          'RetroArch first-run library sync could not be opened; '
          'continuing with the normal folder-link step.',
        );
      }
    } catch (e) {
      // RetroArch not being installed must not block NeoStation setup. The
      // normal folder-link screen remains available immediately afterwards.
      _log.w('RetroArch first-run library sync failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isStartingRetroArchSync = false);
      }
    }
  }

  Future<void> _completeSetup() async {
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    await configProvider.completeSetup();
    configProvider.setSetupWizardActive(false);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(PermissionCheckWrapper.setupCompletedKey, true);
    await prefs.setBool(forkOnboardingCompletedKey, true);

    if (!mounted) return;
    setState(() {
      _needsSetup = false;
      _showForkWelcomeGate = false;
      _showPairingFileGate = false;
      _isStartingRetroArchSync = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking || _isStartingRetroArchSync) {
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

      return SetupWizard(onComplete: _completeSetup);
    }

    return widget.child;
  }
}
