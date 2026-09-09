import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../screens/rpcs3_manager_screen.dart';
import '../services/rpcs3_internal_service.dart';

/// Owns the PS3 firmware gate and, once installed, the library import menu.
/// The host mounts this over the library before loading or displaying games.
class Rpcs3InternalPlaylistActions extends StatefulWidget {
  const Rpcs3InternalPlaylistActions({
    super.key,
    required this.onLibraryChanged,
    required this.onFirmwareChanged,
    required this.onBack,
    this.onInteractionChanged,
  });

  final Future<void> Function() onLibraryChanged;
  final ValueChanged<bool> onFirmwareChanged;
  final VoidCallback onBack;
  final ValueChanged<bool>? onInteractionChanged;

  @override
  State<Rpcs3InternalPlaylistActions> createState() =>
      _Rpcs3InternalPlaylistActionsState();
}

class _Rpcs3InternalPlaylistActionsState
    extends State<Rpcs3InternalPlaylistActions> {
  StreamSubscription<Rpcs3RuntimeState>? _runtimeSubscription;
  bool _checking = true;
  bool _busy = false;
  String _firmwareVersion = '';
  String? _error;
  Rpcs3RuntimePhase _phase = Rpcs3RuntimePhase.idle;
  String _progressMessage = '';

  bool get _firmwareInstalled => _firmwareVersion.isNotEmpty;
  bool get _fr => Localizations.localeOf(context).languageCode == 'fr';
  String get _failed =>
      _fr ? 'Échec de l’opération RPCS3.' : 'RPCS3 operation failed.';

  @override
  void initState() {
    super.initState();
    _runtimeSubscription = Rpcs3InternalService.runtimeStates.listen((state) {
      if (mounted && _busy) {
        setState(() {
          _phase = state.phase;
          _progressMessage = state.message;
        });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkFirmware();
    });
  }

  @override
  void dispose() {
    _runtimeSubscription?.cancel();
    super.dispose();
  }

  void _interaction(bool active) => widget.onInteractionChanged?.call(active);

  Future<void> _opened() async {
    _interaction(true);
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _checkFirmware() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    _interaction(true);
    try {
      // Reads the installed version file. No JIT, Core startup or ROM scan.
      final version = await Rpcs3InternalService.firmwareVersion();
      if (!mounted) return;
      setState(() => _firmwareVersion = version);
      widget.onFirmwareChanged(_firmwareInstalled);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _firmwareVersion = '';
        _error = '$_failed $error';
      });
      widget.onFirmwareChanged(false);
    } finally {
      if (mounted) {
        setState(() => _checking = false);
        _interaction(!_firmwareInstalled);
      }
    }
  }

  Future<void> _installFirmware() async {
    if (_busy || _checking) return;
    setState(() {
      _busy = true;
      _error = null;
      _phase = Rpcs3RuntimePhase.idle;
      _progressMessage = '';
    });
    _interaction(true);
    try {
      // The picker opens before JIT/Core preparation. Cancel keeps this gate.
      if (await Rpcs3InternalService.importFirmware()) {
        await _checkFirmware();
        if (!mounted) return;
        if (_firmwareInstalled) {
          _notice(_fr ? 'Firmware PS3 installé.' : 'PS3 firmware installed.');
        }
      }
    } on Rpcs3InternalException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '$_failed $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _interaction(!_firmwareInstalled);
      }
    }
  }

  Future<void> _openManager() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            Rpcs3ManagerScreen(onLibraryChanged: widget.onLibraryChanged),
      ),
    );
    if (mounted) await _checkFirmware();
  }

  Future<void> _selected(String action) async {
    if (_busy || _checking) return;
    if (action == 'open') {
      await _openManager();
      return;
    }

    if (action == 'firmware') {
      await _installFirmware();
      return;
    }
    if (!_firmwareInstalled) {
      _interaction(true);
      return;
    }

    setState(() => _busy = true);
    _interaction(true);
    try {
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
      if (mounted) {
        setState(() => _busy = false);
        _interaction(false);
      }
    }
  }

  Widget _buildFirmwareGate() {
    final checkingLabel = _fr
        ? 'Vérification du firmware PS3…'
        : 'Checking PS3 firmware…';
    final progressLabel = _progressMessage.isNotEmpty
        ? _progressMessage
        : _phase == Rpcs3RuntimePhase.installingFirmware
        ? (_fr ? 'Installation du firmware PS3…' : 'Installing PS3 firmware…')
        : (_fr ? 'Préparation de l’installation…' : 'Preparing installation…');

    return Material(
      key: const ValueKey('rpcs3-library-firmware-gate'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.system_update_alt, size: 48),
                  const SizedBox(height: 20),
                  Text(
                    _checking
                        ? checkingLabel
                        : (_fr
                              ? 'Firmware PS3 requis'
                              : 'PS3 firmware required'),
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  if (_checking || _busy) ...[
                    const LinearProgressIndicator(),
                    if (_busy) ...[
                      const SizedBox(height: 12),
                      Text(progressLabel, textAlign: TextAlign.center),
                    ],
                  ] else ...[
                    Text(
                      _fr
                          ? 'Installez le firmware officiel PS3 pour ouvrir votre bibliothèque. Sélectionnez votre fichier PS3UPDAT.PUP.'
                          : 'Install the official PS3 firmware to open your library. Select your PS3UPDAT.PUP file.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      key: const ValueKey('rpcs3-library-install-firmware'),
                      onPressed: _installFirmware,
                      icon: const Icon(Icons.file_upload_outlined),
                      label: Text(
                        _fr
                            ? 'Installer le firmware PS3'
                            : 'Install PS3 firmware',
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(
                      onPressed: _busy ? null : _checkFirmware,
                      child: Text(_fr ? 'Réessayer' : 'Retry'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy ? null : widget.onBack,
                    child: Text(_fr ? 'Retour' : 'Back'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_checking || !_firmwareInstalled) return _buildFirmwareGate();
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned(
          top: 8.r,
          right: 10.r,
          child: SafeArea(
            child: Material(
              color: scheme.tertiaryFixed,
              borderRadius: BorderRadius.circular(10.r),
              child: SizedBox(
                width: 36.r,
                height: 36.r,
                child: PopupMenuButton<String>(
                  key: const ValueKey('rpcs3-internal-import-menu'),
                  tooltip: _fr ? 'RPCS3 / Importer' : 'RPCS3 / Import',
                  enabled: !_busy,
                  padding: EdgeInsets.zero,
                  onOpened: _opened,
                  onCanceled: () => _interaction(false),
                  onSelected: _selected,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Icons.file_upload_outlined,
                          size: 18.r,
                          color: scheme.onTertiaryFixed,
                        ),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      enabled: false,
                      child: Text(
                        '${_fr ? 'Firmware installé' : 'Firmware installed'} : $_firmwareVersion',
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'games',
                      child: Text(_fr ? 'Importer des jeux' : 'Import games'),
                    ),
                    PopupMenuItem(
                      value: 'folder',
                      child: Text(
                        _fr
                            ? 'Importer un dossier de jeu'
                            : 'Import game folder',
                      ),
                    ),
                    PopupMenuItem(
                      value: 'firmware',
                      child: Text(
                        _fr
                            ? 'Importer le firmware PS3'
                            : 'Import PS3 firmware',
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'open',
                      child: Text(_fr ? 'Ouvrir RPCS3' : 'Open RPCS3'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_error != null)
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Material(
                color: scheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
