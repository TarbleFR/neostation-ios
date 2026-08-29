import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/sqlite_config_provider.dart';
import '../l10n/manic_emu_locale.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkInitialSetup();
    });
  }

  Future<void> _checkInitialSetup() async {
    try {
      final prefs = await SharedPreferences.getInstance();

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

  void _pushWizardActive(bool active) {
    if (!mounted) return;
    Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    ).setSetupWizardActive(active);
  }

  Future<void> _completeForkWelcomeGate() async {
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
      _log.w('Could not persist first-run welcome state: $e');
    }
  }

  /// Existing iOS users may still need to choose between RetroArch and Manic
  /// EMU. RetroArch itself is now TestFlight-only, so there is deliberately no
  /// second distribution/version dialog here.
  void _scheduleExistingUserOffer() {
    if (!Platform.isIOS || _upgradeOfferScheduled) return;
    _upgradeOfferScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      final hasChoice = await IosEmulatorPreferenceService.hasPrimaryChoice();
      final shouldOffer = await IosEmulatorPreferenceService.shouldShowUpgradeOffer();
      if (!mounted || hasChoice || !shouldOffer) return;

      final choice = await showDialog<IosLibraryEmulator>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Configuration de l’émulateur iOS'),
          content: const Text(
            'Choisissez l’émulateur principal de votre bibliothèque. RetroArch utilise désormais uniquement la version bêta/TestFlight compatible NeoStation.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                IosLibraryEmulator.retroArch,
              ),
              child: const Text('RetroArch TestFlight'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                IosLibraryEmulator.manicEmu,
              ),
              child: const Text('Manic EMU'),
            ),
          ],
        ),
      );

      if (choice == null || !mounted) return;
      await IosEmulatorPreferenceService.setPrimary(choice);
      await IosEmulatorPreferenceService.markUpgradeOfferSeen();
    });
  }

  void _completeSetup() async {
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
      _showEmulatorChoiceGate = false;
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

      if (_showEmulatorChoiceGate) {
        return IosEmulatorChoiceScreen(
          onFinished: () {
            if (mounted) setState(() => _showEmulatorChoiceGate = false);
          },
        );
      }

      return SetupWizard(onComplete: _completeSetup);
    }

    return widget.child;
  }
}
