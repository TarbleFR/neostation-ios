import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/rpcs3_ui_locale.dart';
import '../services/rpcs3_content_import_service.dart';
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
  StreamSubscription<Rpcs3ContentImportProgress>? _contentProgressSubscription;
  bool _busy = false;
  bool _preparing = false;
  bool _jitReady =
      Rpcs3InternalService.jitPrepared ||
      Rpcs3InternalService.runtimeState.jitReady;
  bool _coreReady = Rpcs3InternalService.initialized;
  String? _firmwareVersion;
  String _build = '';
  int _abi = 0;
  String _statusMessage = '';
  String? _error;
  Rpcs3ContentImportProgress? _contentProgress;

  String _t(String key) => Rpcs3UiLocale.text(context, key);
  String _tf(String key, Map<String, Object?> values) =>
      Rpcs3UiLocale.format(context, key, values);

  @override
  void initState() {
    super.initState();
    _runtimeSubscription = Rpcs3InternalService.runtimeStates.listen((state) {
      if (!mounted) return;
      setState(() {
        // Once enabled in this process, CS_DEBUGGED persists after the StikJIT
        // helper detaches. Do not regress the UI to Inactive on a later state
        // event that only describes the Core handshake phase.
        _jitReady =
            _jitReady ||
            state.jitReady ||
            Rpcs3InternalService.jitPrepared;
        _coreReady = state.coreReady;
        _statusMessage = switch (state.phase) {
          Rpcs3RuntimePhase.checkingJit ||
          Rpcs3RuntimePhase.enablingJit => _t('enabling'),
          Rpcs3RuntimePhase.initializingCore => _t('jitCoreWillPrepare'),
          Rpcs3RuntimePhase.installingFirmware => _t('installingFirmware'),
          Rpcs3RuntimePhase.importingContent => _t('importProgress'),
          Rpcs3RuntimePhase.ready => _t('ready'),
          _ => _statusMessage,
        };
        _error = state.phase == Rpcs3RuntimePhase.error
            ? _t('operationFailed')
            : state.error;
        _preparing =
            state.phase == Rpcs3RuntimePhase.checkingJit ||
            state.phase == Rpcs3RuntimePhase.enablingJit ||
            state.phase == Rpcs3RuntimePhase.initializingCore;
      });
    });
    _contentProgressSubscription = Rpcs3ContentImportService.progress.listen((event) {
      if (!mounted || !_busy) return;
      setState(() => _contentProgress = event);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _runtimeSubscription?.cancel();
    _contentProgressSubscription?.cancel();
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
            diagnostics['jitEnabled'] == true ||
            diagnostics['jitPrepared'] == true ||
            Rpcs3InternalService.jitPrepared ||
            (jit is Map && jit['debugged'] == true);
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
        if (_jitReady && _coreReady) {
          _statusMessage = _t('jitCoreReady');
        } else if (_jitReady) {
          _statusMessage = _t('jitCoreOnDemand');
        } else {
          _statusMessage = _t('jitCoreWillPrepare');
        }
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
      _contentProgress = null;
    });
    try {
      if (await Rpcs3InternalService.importFirmware()) {
        await _refreshFirmwareVersion();
        _notice(
          _tf('firmwareInstalledNotice', {'version': _firmwareVersion ?? ''}),
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
      _contentProgress = null;
      _statusMessage = _t('selectingGames');
    });
    try {
      final result = await Rpcs3ContentImportService.importGames();
      if (result.imported > 0) {
        await widget.onLibraryChanged();
        _notice(
          _tf('gamesImported', {'count': result.imported}),
        );
      }
      if (result.rejected > 0) {
        _notice(
          result.errors.isNotEmpty
              ? result.errors.first
              : _t('importRejected'),
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
      if (mounted) {
        setState(() {
          _busy = false;
          _contentProgress = null;
        });
      }
    }
  }

  Future<void> _importFolder() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _contentProgress = null;
      _statusMessage = _t('selectingFolder');
    });
    try {
      if (await Rpcs3ContentImportService.importExtractedGameFolder()) {
        await widget.onLibraryChanged();
        _notice(
          _t('folderImported'),
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
      if (mounted) {
        setState(() {
          _busy = false;
          _contentProgress = null;
        });
      }
    }
  }

  Future<void> _exportSaves() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _contentProgress = null;
      _statusMessage = _t('preparingSaves');
    });
    try {
      await Rpcs3InternalService.exportSaveData();
      if (mounted) {
        _notice(
          _t('savesAvailable'),
        );
      }
    } on Rpcs3InternalException catch (error) {
      if (mounted) setState(() => _error = error.message);
      _notice(error.message);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      _notice(error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _statusMessage = _t('ready');
        });
      }
    }
  }

  Future<void> _importSaves() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _contentProgress = null;
      _statusMessage = _t('importingSaves');
    });
    try {
      final imported = await Rpcs3InternalService.importSaveDataFromFiles();
      if (mounted) {
        _notice(
          _tf('savesImported', {'count': imported}),
        );
      }
    } on Rpcs3InternalException catch (error) {
      if (mounted) setState(() => _error = error.message);
      _notice(error.message);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      _notice(error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _statusMessage = _t('ready');
        });
      }
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
    final progress = _contentProgress;
    final fraction = progress?.fraction;

    return Scaffold(
      appBar: AppBar(
        title: const Text('RPCS3'),
        actions: [
          IconButton(
            tooltip: _t('refresh'),
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
                                _t('embeddedTitle'),
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _t('embeddedDesc'),
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
                              ? _t('enabled')
                              : _preparing
                              ? _t('enabling')
                              : _t('inactive'),
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
                              ? _t('coreReady')
                              : _t('onDemand'),
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
                          LinearProgressIndicator(value: fraction),
                          if (progress != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              progress.itemCount > 1
                                  ? '${progress.itemIndex}/${progress.itemCount} • ${progress.itemName}'
                                  : progress.itemName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (progress.detail.isNotEmpty)
                              Text(
                                progress.detail,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            if (fraction != null)
                              Text('${(fraction * 100).round()} %'),
                          ],
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
                          ? _t('firmwareNotChecked')
                          : firmwareInstalled
                          ? _t('firmwareInstalled')
                          : _t('firmwareRequired'),
                    ),
                    subtitle: Text(
                      !firmwareChecked
                          ? _t('checkingFirmware')
                          : firmwareInstalled
                          ? _firmwareVersion!
                          : _t('installOfficialPup'),
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
                            label: Text(_t('retry')),
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
                  label: Text(_t('installFirmware')),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  key: const ValueKey('rpcs3-manager-games'),
                  onPressed: _busy ? null : _importGames,
                  icon: const Icon(Icons.file_upload_outlined),
                  label: Text(_t('importGames')),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  key: const ValueKey('rpcs3-manager-folder'),
                  onPressed: _busy ? null : _importFolder,
                  icon: const Icon(Icons.folder_open),
                  label: Text(_t('importDecryptedFolder')),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const ValueKey('rpcs3-manager-export-saves'),
                  onPressed: _busy ? null : _exportSaves,
                  icon: const Icon(Icons.drive_folder_upload_outlined),
                  label: Text(_t('exportSaves')),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const ValueKey('rpcs3-manager-import-saves'),
                  onPressed: _busy ? null : _importSaves,
                  icon: const Icon(Icons.restore_page_outlined),
                  label: Text(_t('importSaves')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
