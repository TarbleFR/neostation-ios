import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/pairing_file_service.dart';
import 'package:neostation/services/retroarch_migration_service.dart';
import 'package:neostation/services/stikjit_melonx_service.dart';
import '../providers/sqlite_config_provider.dart';
import '../screens/systems_screen/fork_first_run_onboarding.dart';
import 'pairing_file_onboarding.dart';
import 'setup_wizard.dart';
import 'shimmering_logo.dart';
import 'console_library_picker.dart';
import 'retroarch_migration_dialog.dart';
import '../services/library_visibility_service.dart';
import '../services/retroarch_core_catalog.dart';
import '../services/retroarch_internal_service.dart';

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
  bool _migrationScheduled = false;
  bool _librariesChosen = false;

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
        if (Platform.isIOS) {
          await RetroArchMigrationService.instance.initialize(
            existingInstallation: true,
          );
        }
        await prefs.setBool(forkOnboardingCompletedKey, true);
        if (!mounted) return;
        _pushWizardActive(false);
        setState(() {
          _needsSetup = false;
          _showForkWelcomeGate = false;
          _showPairingFileGate = false;
          _isChecking = false;
        });
        _offerExistingRetroArchMigration();
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

      if (hasRomFolder ||
          setupCompleted ||
          configProvider.isExistingLibraryInstallation) {
        if (Platform.isIOS) {
          await RetroArchMigrationService.instance.initialize(
            existingInstallation: true,
          );
        }
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
        _offerExistingRetroArchMigration();
        return;
      }

      if (Platform.isIOS &&
          configProvider.usesLibrarySelection &&
          !configProvider.needsLibrarySelection) {
        // Resume a first install interrupted after the selection was saved.
        await _completeLibrarySelection();
        if (mounted) setState(() => _isChecking = false);
        return;
      }

      // Fresh installs choose all console libraries in one opt-in step after
      // the welcome gate, then pair only if a chosen console requires JIT.
      final welcomeGateCompleted =
          prefs.getBool(forkOnboardingCompletedKey) ?? false;

      if (!mounted) return;
      _pushWizardActive(true);
      setState(() {
        _needsSetup = true;
        _showForkWelcomeGate = !welcomeGateCompleted;
        // Ask for pairing only after the user has selected a JIT console.
        _showPairingFileGate = false;
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

  void _offerExistingRetroArchMigration() {
    if (!Platform.isIOS || _migrationScheduled) return;
    _migrationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await RetroArchMigrationDialog.showIfNeeded(context);
        if (!mounted || !RetroArchMigrationService.instance.usesEmbedded) {
          return;
        }
        await RetroArchInternalService.ensureLayout();
        if (!mounted) return;
        final provider = context.read<SqliteConfigProvider>();
        for (final folder in provider.enabledLibraryFolders) {
          if (RetroArchCoreCatalog.supportsSystem(folder)) {
            await provider.refreshRetroArchInternalLibrary(folder);
          }
        }
      } catch (error) {
        _log.w('Could not offer RetroArch migration: $error');
      }
    });
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

    setState(() {
      _showForkWelcomeGate = false;
      _showPairingFileGate = false;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(forkOnboardingCompletedKey, true);
    } catch (e) {
      _log.w('Could not persist first-run welcome state: $e');
    }
  }

  Future<void> _completeLibrarySelection() async {
    if (!mounted) return;
    _librariesChosen = true;
    final provider = context.read<SqliteConfigProvider>();
    final needsJit = LibraryVisibilityService.requiresPairingFor(
      provider.enabledLibraryFolders,
    );
    var showPairing = _supportsPairingGate && needsJit;
    if (showPairing) {
      final prefs = await SharedPreferences.getInstance();
      showPairing =
          prefs.getBool(PermissionCheckWrapper.pairingOnboardingCompletedKey) !=
          true;
      if (showPairing) {
        try {
          showPairing = !await PairingFileService.hasStoredPairingFile();
        } catch (_) {
          // Keep the established import gate for a chosen JIT console.
        }
      }
    }
    if (!mounted) return;
    if (showPairing) {
      setState(() {
        _needsSetup = true;
        _showForkWelcomeGate = false;
        _showPairingFileGate = true;
      });
      return;
    }
    await _completeSetup();
  }

  Future<void> _completePairingFileGate() async {
    if (!mounted) return;

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
    if (_librariesChosen && mounted) await _completeSetup();
  }

  Future<void> _completeSetup() async {
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    if (Platform.isIOS) {
      await RetroArchMigrationService.instance.initialize(
        existingInstallation: false,
      );
      if (RetroArchMigrationService.instance.usesEmbedded) {
        await RetroArchInternalService.ensureLayout();
      }
      await configProvider.selectRomFolder(scan: false);
    }
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
          body: ForkFirstRunOnboarding(onFinished: _completeForkWelcomeGate),
        );
      }

      if (_showPairingFileGate) {
        return Scaffold(
          body: PairingFileOnboarding(onFinished: _completePairingFileGate),
        );
      }

      if (Platform.isIOS) {
        final provider = context.watch<SqliteConfigProvider>();
        return Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ConsoleLibraryPicker(
                libraries: provider.selectableLibrarySystems,
                initiallyEnabled: provider.enabledLibraryFolders,
                onSave: provider.saveLibrarySelection,
                onFinished: _completeLibrarySelection,
                firstLaunch: true,
              ),
            ),
          ),
        );
      }
      return SetupWizard(onComplete: _completeSetup);
    }

    return widget.child;
  }
}
