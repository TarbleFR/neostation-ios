from pathlib import Path


def replace_once(file_path: str, old: str, new: str, label: str) -> None:
    p = Path(file_path)
    text = p.read_text(encoding='utf-8')
    if old not in text:
        raise SystemExit(f'{label}: anchor not found in {file_path}')
    p.write_text(text.replace(old, new, 1), encoding='utf-8')


def remove_exact(file_path: str, value: str, label: str) -> None:
    replace_once(file_path, value, '', label)


setup = 'lib/widgets/setup_wizard.dart'
for import_line in (
    "import 'package:neostation/services/ios_emulator_preference_service.dart';\n",
    "import 'package:neostation/services/manic_emu_launch_service.dart';\n",
    "import 'package:neostation/l10n/manic_emu_locale.dart';\n",
):
    remove_exact(setup, import_line, 'setup Manic import')

replace_once(
    setup,
    """    final primary = await IosEmulatorPreferenceService.primary();\n    if (!mounted || _currentStep != _stepFolder || _isSelectingFolder) return;\n\n    final existingLink = primary == IosLibraryEmulator.manicEmu\n        ? ConfigService.linkedManicEmuFolderPath\n        : ConfigService.linkedExternalFolderPath;\n""",
    """    if (!mounted || _currentStep != _stepFolder || _isSelectingFolder) return;\n\n    final existingLink = ConfigService.linkedExternalFolderPath;\n""",
    'setup initial iOS link',
)

replace_once(
    setup,
    """        // Lead with linking RetroArch's own folder here — now that\n        // launching found games works, it's\n        // the better default for anyone using RetroArch. The plain\n        // internal-folder path (ConfigService.getDefaultIOSRomsFolder,\n        // via selectRomFolder below) remains available afterwards from\n        // Settings > Directories for anyone who declines or doesn't use\n        // RetroArch — this is only about which one leads during\n        // first-run onboarding.\n        final primary = await IosEmulatorPreferenceService.primary();\n        final usesManic = primary == IosLibraryEmulator.manicEmu;\n        final bookmarkKey = usesManic\n            ? ManicEmuLaunchService.bookmarkKey\n            : ExternalFolderAccess.defaultBookmarkKey;\n        final linked = await ExternalFolderAccess.pickAndActivateFolder(\n          key: bookmarkKey,\n        );\n""",
    """        // iOS first-run links RetroArch directly.\n        final linked = await ExternalFolderAccess.pickAndActivateFolder(\n          key: ExternalFolderAccess.defaultBookmarkKey,\n        );\n""",
    'setup iOS picker',
)

replace_once(
    setup,
    """          if (usesManic) {\n            ConfigService.linkedManicEmuFolderPath = linked;\n          } else {\n            ConfigService.linkedExternalFolderPath = linked;\n          }\n""",
    """          ConfigService.linkedExternalFolderPath = linked;\n""",
    'setup iOS root assignment',
)

# Build 171 adds the RetroArch nested-library resolver behind the old Manic gate.
replace_once(
    setup,
    """          var scanRoot = linked;\n          if (!usesManic) {\n            final availableSystems = configProvider.availableSystems.isNotEmpty\n                ? configProvider.availableSystems\n                : await ConfigService.loadAvailableSystems();\n            scanRoot = await IosRomLibraryRootResolver.resolveRetroArchScanRoot(\n              linkedRoot: linked,\n              systemFolderNames: availableSystems.expand(\n                (system) => <String>[system.folderName, ...system.folders],\n              ),\n            );\n          }\n""",
    """          final availableSystems = configProvider.availableSystems.isNotEmpty\n              ? configProvider.availableSystems\n              : await ConfigService.loadAvailableSystems();\n          final scanRoot = await IosRomLibraryRootResolver.resolveRetroArchScanRoot(\n            linkedRoot: linked,\n            systemFolderNames: availableSystems.expand(\n              (system) => <String>[system.folderName, ...system.folders],\n            ),\n          );\n""",
    'setup Build 171 RetroArch resolver gate',
)

replace_once(
    setup,
    """          if (mounted && usesManic) {\n            AppNotification.showNotification(\n              context,\n              ManicEmuLocale.text(context, 'folderLinked'),\n              type: NotificationType.info,\n            );\n          }\n""",
    '',
    'setup Manic notification',
)

setup_text = Path(setup).read_text(encoding='utf-8')
setup_text = setup_text.replace(
    'while RetroArch is still in the foreground for its callback). Manic\n    // EMU never leaves the app here, so its picker is normally started by the\n    // initial post-frame callback above.',
    'while RetroArch is still in the foreground for its callback).',
)
setup_text = setup_text.replace('RetroArch/Manic EMU library', 'RetroArch library')
Path(setup).write_text(setup_text, encoding='utf-8')

permission = 'lib/widgets/permission_check_wrapper.dart'
remove_exact(
    permission,
    "import 'package:neostation/services/ios_emulator_preference_service.dart';\n",
    'permission preference import',
)
replace_once(
    permission,
    """      final hasPrimaryChoice =\n          !Platform.isIOS ||\n          await IosEmulatorPreferenceService.hasPrimaryChoice();\n\n""",
    '',
    'permission primary choice',
)
replace_once(
    permission,
    """      if (welcomeGateCompleted && pairingReady && !hasPrimaryChoice) {\n""",
    """      if (welcomeGateCompleted && pairingReady) {\n""",
    'permission first-run resume',
)
replace_once(
    permission,
    """      await IosEmulatorPreferenceService.setPrimary(\n        IosLibraryEmulator.retroArch,\n      );\n      await IosEmulatorPreferenceService.markUpgradeOfferSeen();\n\n""",
    '',
    'permission old emulator preference',
)

config = 'lib/services/config_service.dart'
replace_once(
    config,
    """  /// iOS-only folder linked from Manic EMU's Files container.\n  static String? linkedManicEmuFolderPath;\n\n""",
    '',
    'ConfigService Manic path',
)

for dead_file in (
    'lib/services/manic_emu_launch_service.dart',
    'lib/services/ios_emulator_preference_service.dart',
    'lib/l10n/manic_emu_locale.dart',
):
    p = Path(dead_file)
    if p.exists():
        p.unlink()

retro = Path('lib/services/retroarch_library_service.dart')
text = retro.read_text(encoding='utf-8')
text = text.replace("        'manic_emu_upgrade_offer_seen_v1',\n", '')
text = text.replace("            key.startsWith('manic_emu_') ||\n", '')
text = text.replace("      await ExternalFolderAccess.clearBookmark(key: 'manicemu');\n", '')
text = text.replace('App Store/Manic', 'legacy iOS')
text = text.replace('Manic routing state', 'legacy routing state')
text = text.replace('experimental App Store/Manic builds', 'experimental iOS builds')
retro.write_text(text, encoding='utf-8')

melonx = Path('lib/services/melonx_library_service.dart')
text = melonx.read_text(encoding='utf-8')
text = text.replace(
    "  // MeloNX's compatibility scheme used by ManicEMU for frontend launches.\n",
    "  // MeloNX compatibility frontend scheme.\n",
)
text = text.replace(
    "  /// MeloNX's compatibility frontend scheme. ManicEMU uses this exact scheme\n",
    "  /// MeloNX's compatibility frontend scheme. This scheme\n",
)
melonx.write_text(text, encoding='utf-8')

external = Path('packages/external_folder_access/lib/external_folder_access.dart')
text = external.read_text(encoding='utf-8')
text = text.replace(
    'blocking Flutter while Manic EMU identifiers are prepared for large ROMs.',
    'blocking Flutter while file identifiers are prepared for large ROMs.',
)
external.write_text(text, encoding='utf-8')

print('ManicEMU runtime integration removed from Build 171 base')
