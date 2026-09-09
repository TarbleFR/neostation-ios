import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/rpcs3_manager_screen.dart';
import '../services/rpcs3_internal_service.dart';

class Rpcs3InternalPlaylistActions extends StatefulWidget {
  const Rpcs3InternalPlaylistActions({
    super.key,
    required this.onLibraryChanged,
    this.onInteractionChanged,
  });

  final Future<void> Function() onLibraryChanged;
  final ValueChanged<bool>? onInteractionChanged;

  @override
  State<Rpcs3InternalPlaylistActions> createState() =>
      _Rpcs3InternalPlaylistActionsState();
}

class _Rpcs3InternalPlaylistActionsState
    extends State<Rpcs3InternalPlaylistActions> {
  static const _firmwareInstalledKey =
      'rpcs3_internal_firmware_installed_v1';
  static const _firmwareVersionKey = 'rpcs3_internal_firmware_version_v1';

  bool _busy = false;
  bool _onboardingShown = false;
  bool _firmwareKnownInstalled = false;
  String _firmwareVersion = '';

  bool get _fr => Localizations.localeOf(context).languageCode == 'fr';
  String get _import => _fr ? 'RPCS3 / Importer' : 'RPCS3 / Import';
  String get _open => _fr ? 'Ouvrir RPCS3' : 'Open RPCS3';
  String get _games => _fr ? 'Importer des jeux' : 'Import games';
  String get _folder =>
      _fr ? 'Importer un dossier de jeu' : 'Import game folder';
  String get _firmware =>
      _fr ? 'Importer le firmware PS3' : 'Import PS3 firmware';
  String get _firmwareMissing => _fr ? 'Firmware requis' : 'Firmware required';
  String get _failed =>
      _fr ? 'Échec de l’opération RPCS3.' : 'RPCS3 operation failed.';

  @override
  void initState() {
    super.initState();

    // Do not initialize or query RPCS3 Core just to decide whether onboarding
    // should be shown. Build 222 did that through firmwareVersion(), which can
    // wait on JIT/Core startup before the user ever sees the PUP picker. Load a
    // lightweight local marker instead and present the firmware CTA immediately
    // on a fresh PS3 library.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _restoreFirmwareStateAndShowOnboarding();
    });
  }

  void _interaction(bool active) => widget.onInteractionChanged?.call(active);

  Future<void> _opened() async {
    _interaction(true);
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _restoreFirmwareStateAndShowOnboarding() async {
    final preferences = await SharedPreferences.getInstance();
    final installed = preferences.getBool(_firmwareInstalledKey) ?? false;
    final version = preferences.getString(_firmwareVersionKey) ?? '';

    if (!mounted) return;
    setState(() {
      _firmwareKnownInstalled = installed;
      _firmwareVersion = version;
    });

    if (!installed) {
      await _showFirmwareOnboarding();
    }
  }

  Future<void> _showFirmwareOnboarding() async {
    if (!mounted || _onboardingShown || _busy || _firmwareKnownInstalled) {
      return;
    }
    _onboardingShown = true;
    _interaction(true);

    final install = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(_fr ? 'Firmware PS3 requis' : 'PS3 firmware required'),
          content: Text(
            _fr
                ? 'RPCS3 nécessite le firmware officiel PS3 avant de pouvoir utiliser la bibliothèque. Sélectionnez le fichier PS3UPDAT.PUP pour continuer.'
                : 'RPCS3 requires the official PS3 firmware before the library can be used. Select PS3UPDAT.PUP to continue.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(_fr ? 'Retour' : 'Back'),
            ),
            FilledButton.icon(
              key: const ValueKey('rpcs3-library-install-firmware'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.system_update_alt),
              label: Text(
                _fr ? 'Installer le firmware PS3' : 'Install PS3 firmware',
              ),
            ),
          ],
        );
      },
    );

    _interaction(false);
    if (install == true && mounted) {
      await _installFirmware();
    }
  }

  Future<void> _rememberInstalledFirmware() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_firmwareInstalledKey, true);
    if (_firmwareVersion.isNotEmpty) {
      await preferences.setString(_firmwareVersionKey, _firmwareVersion);
    }
  }

  Future<void> _installFirmware() async {
    if (_busy) return;
    setState(() => _busy = true);
    _interaction(true);
    try {
      // importFirmware() opens the PUP picker first. JIT/Core initialization is
      // deferred until the user has actually selected the firmware file.
      if (await Rpcs3InternalService.importFirmware()) {
        _firmwareVersion = await Rpcs3InternalService.firmwareVersion();
        _firmwareKnownInstalled = true;
        await _rememberInstalledFirmware();
        if (mounted) setState(() {});
        _notice(
          _fr
              ? 'Firmware PS3 installé${_firmwareVersion.isEmpty ? '' : ' : $_firmwareVersion'}.'
              : 'PS3 firmware installed${_firmwareVersion.isEmpty ? '' : ': $_firmwareVersion'}.',
        );
      } else {
        // Picker cancelled: allow onboarding to be presented again next time
        // the PS3 library is opened.
        _onboardingShown = false;
      }
    } on Rpcs3InternalException catch (error) {
      _onboardingShown = false;
      _notice(error.message);
    } catch (error) {
      _onboardingShown = false;
      _notice('$_failed $error');
    } finally {
      if (mounted) setState(() => _busy = false);
      _interaction(false);
    }
  }

  Future<void> _openManager() async {
    _interaction(false);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Rpcs3ManagerScreen(
          onLibraryChanged: widget.onLibraryChanged,
        ),
      ),
    );
    if (!mounted) return;
    try {
      if (await Rpcs3InternalService.hasFirmware()) {
        _firmwareVersion = await Rpcs3InternalService.firmwareVersion();
        _firmwareKnownInstalled = true;
        await _rememberInstalledFirmware();
      }
    } catch (_) {
      // Firmware state is shown again the next time the manager is opened.
    } finally {
      await Rpcs3InternalService.closeManagementRuntime();
    }
    if (mounted) setState(() {});
  }

  Future<void> _selected(String action) async {
    if (_busy) return;

    if (action == 'open') {
      await _openManager();
      return;
    }

    if (action == 'firmware') {
      await _installFirmware();
      return;
    }

    setState(() => _busy = true);
    try {
      if (!_firmwareKnownInstalled) {
        _onboardingShown = false;
        await _showFirmwareOnboarding();
        return;
      }

      if (action == 'games') {
        final result = await Rpcs3InternalService.importGames();
        if (result.imported > 0) await widget.onLibraryChanged();
        if (result.rejected > 0) {
          _notice(result.errors.isNotEmpty ? result.errors.first : _failed);
        }
      } else if (action == 'folder') {
        if (await Rpcs3InternalService.importExtractedGameFolder()) {
          await widget.onLibraryChanged();
        }
      }
    } on Rpcs3InternalException catch (error) {
      _notice(error.message);
    } catch (error) {
      _notice('$_failed $error');
    } finally {
      if (mounted) setState(() => _busy = false);
      _interaction(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final firmwareLabel = _firmwareKnownInstalled
        ? (_firmwareVersion.isEmpty
              ? (_fr ? 'Firmware installé' : 'Firmware installed')
              : '${_fr ? 'Firmware installé' : 'Firmware installed'}: $_firmwareVersion')
        : _firmwareMissing;

    return Container(
      width: 36.r,
      height: 36.r,
      decoration: BoxDecoration(
        color: scheme.tertiaryFixed,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: scheme.tertiaryFixed, width: 2.r),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.3),
            blurRadius: 3.r,
            offset: Offset(1.5.r, 1.5.r),
          ),
        ],
      ),
      child: PopupMenuButton<String>(
        key: const ValueKey('rpcs3-internal-import-menu'),
        tooltip: _import,
        enabled: !_busy,
        padding: EdgeInsets.zero,
        onOpened: _opened,
        onCanceled: () => _interaction(false),
        onSelected: _selected,
        icon: _busy
            ? SizedBox(
                width: 18.r,
                height: 18.r,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onTertiaryFixed,
                ),
              )
            : Icon(
                Icons.file_upload_outlined,
                size: 18.r,
                color: scheme.onTertiaryFixed,
              ),
        itemBuilder: (context) => [
          PopupMenuItem(
            enabled: false,
            child: Row(
              children: [
                Icon(
                  _firmwareKnownInstalled
                      ? Icons.check_circle_outline
                      : Icons.warning_amber_rounded,
                  size: 18.r,
                ),
                SizedBox(width: 8.r),
                Expanded(child: Text(firmwareLabel)),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'open',
            child: Row(
              children: [
                const Icon(Icons.memory),
                SizedBox(width: 8.r),
                Text(_open),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(value: 'firmware', child: Text(_firmware)),
          PopupMenuItem(
            value: 'games',
            enabled: _firmwareKnownInstalled,
            child: Text(_games),
          ),
          PopupMenuItem(
            value: 'folder',
            enabled: _firmwareKnownInstalled,
            child: Text(_folder),
          ),
        ],
      ),
    );
  }
}
