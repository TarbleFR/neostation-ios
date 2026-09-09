import 'dart:async';

import 'package:flutter/material.dart';

import '../services/rpcs3_internal_service.dart';

/// User-facing management surface for the embedded RPCS3 engine.
///
/// RPCS3 iOS 0.8.1 requires JIT before its Core can be loaded, even for
/// firmware/content maintenance. Opening this screen prepares that runtime and
/// then exposes the Core's native installation APIs through NeoStation.
class Rpcs3ManagerScreen extends StatefulWidget {
  const Rpcs3ManagerScreen({
    super.key,
    required this.onLibraryChanged,
  });

  final Future<void> Function() onLibraryChanged;

  @override
  State<Rpcs3ManagerScreen> createState() => _Rpcs3ManagerScreenState();
}

class _Rpcs3ManagerScreenState extends State<Rpcs3ManagerScreen> {
  bool _loading = true;
  bool _busy = false;
  String _firmwareVersion = '';
  String _build = '';
  int _abi = 0;
  String? _error;

  bool get _fr => Localizations.localeOf(context).languageCode == 'fr';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    // Closing the manager leaves the validated RPCS3 Core ready for a later
    // direct game boot; it is not an external emulator process.
    unawaited(Rpcs3InternalService.closeManagementRuntime());
    super.dispose();
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Rpcs3InternalService.ensureManagementInitialized();
      final version = await Rpcs3InternalService.firmwareVersion();
      final diagnostics = await Rpcs3InternalService.diagnostics();
      if (!mounted) return;
      setState(() {
        _firmwareVersion = version;
        _build = diagnostics['build']?.toString() ?? '';
        _abi = (diagnostics['abi'] as num?)?.toInt() ?? 0;
      });
    } on Rpcs3InternalException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _installFirmware() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (await Rpcs3InternalService.importFirmware()) {
        _firmwareVersion = await Rpcs3InternalService.firmwareVersion();
        _notice(
          _fr
              ? 'Firmware PS3 installé : $_firmwareVersion'
              : 'PS3 firmware installed: $_firmwareVersion',
        );
        if (mounted) setState(() {});
      }
    } on Rpcs3InternalException catch (error) {
      _notice(error.message);
    } catch (error) {
      _notice(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importGames() async {
    if (_busy) return;
    setState(() => _busy = true);
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
    } on Rpcs3InternalException catch (error) {
      _notice(error.message);
    } catch (error) {
      _notice(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importFolder() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (await Rpcs3InternalService.importExtractedGameFolder()) {
        await widget.onLibraryChanged();
        _notice(
          _fr ? 'Dossier de jeu PS3 importé.' : 'PS3 game folder imported.',
        );
      }
    } on Rpcs3InternalException catch (error) {
      _notice(error.message);
    } catch (error) {
      _notice(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final firmwareInstalled = _firmwareVersion.isNotEmpty;

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
                            Icon(
                              Icons.memory,
                              color: scheme.primary,
                            ),
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
                              ? 'RPCS3 active d’abord le JIT requis par son moteur, puis ce menu permet d’installer le firmware et les jeux. Le lancement d’un jeu reste direct depuis NeoStation.'
                              : 'RPCS3 first enables the JIT required by its engine, then this menu can install firmware and games. Games still boot directly from NeoStation.',
                        ),
                        if (_build.isNotEmpty || _abi != 0) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Core ${_build.isEmpty ? '' : _build}${_abi == 0 ? '' : ' • ABI $_abi'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: Icon(
                      firmwareInstalled
                          ? Icons.check_circle
                          : Icons.warning_amber_rounded,
                      color: firmwareInstalled
                          ? scheme.primary
                          : scheme.error,
                    ),
                    title: Text(
                      firmwareInstalled
                          ? (_fr
                                ? 'Firmware PS3 installé'
                                : 'PS3 firmware installed')
                          : (_fr ? 'Firmware PS3 requis' : 'PS3 firmware required'),
                    ),
                    subtitle: Text(
                      firmwareInstalled
                          ? _firmwareVersion
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
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const ValueKey('rpcs3-manager-firmware'),
                  onPressed: _loading || _busy ? null : _installFirmware,
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(
                    _fr ? 'Installer le firmware PS3' : 'Install PS3 firmware',
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  key: const ValueKey('rpcs3-manager-games'),
                  onPressed: _loading || _busy ? null : _importGames,
                  icon: const Icon(Icons.file_upload_outlined),
                  label: Text(_fr ? 'Importer des jeux' : 'Import games'),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  key: const ValueKey('rpcs3-manager-folder'),
                  onPressed: _loading || _busy ? null : _importFolder,
                  icon: const Icon(Icons.folder_open),
                  label: Text(
                    _fr
                        ? 'Importer un dossier de jeu'
                        : 'Import a game folder',
                  ),
                ),
                if (_loading || _busy) ...[
                  const SizedBox(height: 24),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
