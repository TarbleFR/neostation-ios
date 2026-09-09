import 'dart:async';

import 'package:flutter/material.dart';

import '../services/rpcs3_internal_service.dart';

/// User-facing management surface for the embedded RPCS3 engine.
///
/// Opening this screen pre-warms JIT in the background but deliberately keeps
/// libRPCS3Core.dylib dormant until a firmware/content/game action needs it.
class Rpcs3ManagerScreen extends StatefulWidget {
  const Rpcs3ManagerScreen({super.key, required this.onLibraryChanged});

  final Future<void> Function() onLibraryChanged;

  @override
  State<Rpcs3ManagerScreen> createState() => _Rpcs3ManagerScreenState();
}

class _Rpcs3ManagerScreenState extends State<Rpcs3ManagerScreen> {
  StreamSubscription<Rpcs3RuntimeState>? _runtimeSubscription;
  bool _busy = false;
  bool _preparing = false;
  bool _jitReady = false;
  bool _coreReady = false;
  String? _firmwareVersion;
  String _build = '';
  int _abi = 0;
  String _statusMessage = '';
  String? _error;

  bool get _fr => Localizations.localeOf(context).languageCode == 'fr';

  @override
  void initState() {
    super.initState();
    _runtimeSubscription = Rpcs3InternalService.runtimeStates.listen((state) {
      if (!mounted) return;
      setState(() {
        _jitReady = state.jitReady;
        _coreReady = state.coreReady;
        _statusMessage = state.message;
        _error = state.error;
        _preparing =
            state.phase == Rpcs3RuntimePhase.checkingJit ||
            state.phase == Rpcs3RuntimePhase.enablingJit ||
            state.phase == Rpcs3RuntimePhase.initializingCore;
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _runtimeSubscription?.cancel();
    unawaited(Rpcs3InternalService.closeManagementRuntime());
    super.dispose();
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _readDiagnostics() async {
    try {
      final diagnostics = await Rpcs3InternalService.diagnostics();
      final jit = diagnostics['jit'];
      if (!mounted) return;
      setState(() {
        _jitReady =
            jit is Map &&
            jit['debugged'] == true &&
            (jit['requiresCoreHandshake'] != true ||
                diagnostics['initialized'] == true);
        _coreReady = diagnostics['initialized'] == true;
        _build = diagnostics['build']?.toString() ?? '';
        _abi = (diagnostics['abi'] as num?)?.toInt() ?? 0;
      });
    } on Rpcs3InternalException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _bootstrap() async {
    if (_preparing) return;
    setState(() {
      _preparing = true;
      _error = null;
    });

    // Inspection only: Universal JIT must attach as part of Core startup.
    try {
      await _refreshFirmwareVersion();
      await _readDiagnostics();
      await Rpcs3InternalService.prepareManager();
      await _readDiagnostics();
      if (!mounted) return;
      setState(() {
        _statusMessage = _fr
            ? 'Le JIT et RPCS3 Core seront préparés lors de l’importation ou du lancement.'
            : 'JIT and RPCS3 Core will be prepared when importing or launching.';
      });
    } on Rpcs3InternalException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _refresh() async {
    setState(() => _error = null);
    await _readDiagnostics();
    if (!_jitReady) await _bootstrap();
  }

  Future<void> _refreshFirmwareVersion() async {
    final version = await Rpcs3InternalService.firmwareVersion();
    if (mounted) setState(() => _firmwareVersion = version);
  }

  Future<void> _installFirmware() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (await Rpcs3InternalService.importFirmware()) {
        await _refreshFirmwareVersion();
        _notice(
          _fr
              ? 'Firmware PS3 installé : ${_firmwareVersion ?? ''}'
              : 'PS3 firmware installed: ${_firmwareVersion ?? ''}',
        );
      }
      await _readDiagnostics();
    } on Rpcs3InternalException catch (error) {
      if (mounted) setState(() => _error = error.message);
      _notice(error.message);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      _notice(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importGames() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await Rpcs3InternalService.importGames();
      if (result.imported > 0) {
        await widget.onLibraryChanged();
        _notice(
          _fr
              ? '${result.imported} jeu(x) PS3 importé(s).'
              : '${result.imported} PS3 game(s) imported.',
        );
      }
      if (result.rejected > 0) {
        _notice(
          result.errors.isNotEmpty
              ? result.errors.first
              : (_fr ? 'Import RPCS3 refusé.' : 'RPCS3 import rejected.'),
        );
      }
      await _readDiagnostics();
    } on Rpcs3InternalException catch (error) {
      if (mounted) setState(() => _error = error.message);
      _notice(error.message);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      _notice(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importFolder() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (await Rpcs3InternalService.importExtractedGameFolder()) {
        await widget.onLibraryChanged();
        _notice(
          _fr ? 'Dossier de jeu PS3 importé.' : 'PS3 game folder imported.',
        );
      }
      await _readDiagnostics();
    } on Rpcs3InternalException catch (error) {
      if (mounted) setState(() => _error = error.message);
      _notice(error.message);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      _notice(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _statusRow({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
          Text(value, style: TextStyle(color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final firmwareChecked = _firmwareVersion != null;
    final firmwareInstalled = _firmwareVersion?.isNotEmpty == true;
    final currentState = Rpcs3InternalService.runtimeState;
    final working = _busy || _preparing || currentState.busy;

    return Scaffold(
      appBar: AppBar(
        title: const Text('RPCS3'),
        actions: [
          IconButton(
            tooltip: _fr ? 'Actualiser' : 'Refresh',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.memory, color: scheme.primary),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _fr
                                    ? 'Émulateur RPCS3 intégré'
                                    : 'Embedded RPCS3 emulator',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _fr
                              ? 'Le JIT est vérifié automatiquement à l’ouverture. Le Core RPCS3 reste dormant jusqu’à l’installation du firmware, l’import d’un jeu ou le lancement d’un titre.'
                              : 'JIT is checked automatically when this screen opens. RPCS3 Core stays dormant until firmware installation, game import or title launch.',
                        ),
                        const SizedBox(height: 16),
                        _statusRow(
                          icon: _jitReady
                              ? Icons.check_circle
                              : _preparing
                              ? Icons.hourglass_top
                              : Icons.radio_button_unchecked,
                          label: 'JIT',
                          value: _jitReady
                              ? (_fr ? 'Activé' : 'Enabled')
                              : _preparing
                              ? (_fr ? 'Activation…' : 'Enabling…')
                              : (_fr ? 'Inactif' : 'Inactive'),
                          color: _jitReady
                              ? scheme.primary
                              : _preparing
                              ? scheme.tertiary
                              : scheme.onSurfaceVariant,
                        ),
                        _statusRow(
                          icon: _coreReady
                              ? Icons.check_circle
                              : Icons.pause_circle_outline,
                          label: 'RPCS3 Core',
                          value: _coreReady
                              ? (_fr ? 'Prêt' : 'Ready')
                              : (_fr ? 'À la demande' : 'On demand'),
                          color: _coreReady
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                        if (_statusMessage.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            _statusMessage,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (_build.isNotEmpty || _abi != 0) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Core ${_build.isEmpty ? '' : _build}${_abi == 0 ? '' : ' • ABI $_abi'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (working) ...[
                          const SizedBox(height: 12),
                          const LinearProgressIndicator(),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: Icon(
                      !firmwareChecked
                          ? Icons.help_outline
                          : firmwareInstalled
                          ? Icons.check_circle
                          : Icons.warning_amber_rounded,
                      color: !firmwareChecked
                          ? scheme.onSurfaceVariant
                          : firmwareInstalled
                          ? scheme.primary
                          : scheme.error,
                    ),
                    title: Text(
                      !firmwareChecked
                          ? (_fr
                                ? 'Firmware PS3 non vérifié'
                                : 'PS3 firmware not checked')
                          : firmwareInstalled
                          ? (_fr
                                ? 'Firmware PS3 installé'
                                : 'PS3 firmware installed')
                          : (_fr
                                ? 'Firmware PS3 requis'
                                : 'PS3 firmware required'),
                    ),
                    subtitle: Text(
                      !firmwareChecked
                          ? (_fr
                                ? 'Vérification des fichiers du firmware…'
                                : 'Checking the installed firmware files…')
                          : firmwareInstalled
                          ? _firmwareVersion!
                          : (_fr
                                ? 'Installez le fichier officiel PS3UPDAT.PUP.'
                                : 'Install the official PS3UPDAT.PUP file.'),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: scheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _error!,
                            style: TextStyle(color: scheme.onErrorContainer),
                          ),
                          const SizedBox(height: 10),
                          TextButton.icon(
                            onPressed: _busy ? null : _bootstrap,
                            icon: const Icon(Icons.refresh),
                            label: Text(_fr ? 'Réessayer' : 'Retry'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const ValueKey('rpcs3-manager-firmware'),
                  onPressed: _busy ? null : _installFirmware,
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(
                    _fr ? 'Installer le firmware PS3' : 'Install PS3 firmware',
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  key: const ValueKey('rpcs3-manager-games'),
                  onPressed: _busy ? null : _importGames,
                  icon: const Icon(Icons.file_upload_outlined),
                  label: Text(_fr ? 'Importer des jeux' : 'Import games'),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  key: const ValueKey('rpcs3-manager-folder'),
                  onPressed: _busy ? null : _importFolder,
                  icon: const Icon(Icons.folder_open),
                  label: Text(
                    _fr ? 'Importer un dossier de jeu' : 'Import a game folder',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
