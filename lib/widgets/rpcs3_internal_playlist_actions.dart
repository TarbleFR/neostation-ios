import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../l10n/rpcs3_ui_locale.dart';
import '../screens/rpcs3_manager_screen.dart';
import '../services/rpcs3_content_import_service.dart';
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
    this.embedded = false,
  });

  final Future<void> Function() onLibraryChanged;
  final ValueChanged<bool> onFirmwareChanged;
  final VoidCallback onBack;
  final ValueChanged<bool>? onInteractionChanged;
  final bool embedded;

  @override
  State<Rpcs3InternalPlaylistActions> createState() =>
      _Rpcs3InternalPlaylistActionsState();
}

class _Rpcs3InternalPlaylistActionsState
    extends State<Rpcs3InternalPlaylistActions> {
  StreamSubscription<Rpcs3RuntimeState>? _runtimeSubscription;
  StreamSubscription<Rpcs3ContentImportProgress>? _contentProgressSubscription;
  bool _checking = true;
  bool _busy = false;
  String _firmwareVersion = '';
  String? _error;
  Rpcs3RuntimePhase _phase = Rpcs3RuntimePhase.idle;
  String _progressMessage = '';
  Rpcs3ContentImportProgress? _contentProgress;
  String? _activeAction;
  OverlayEntry? _operationOverlayEntry;

  bool get _firmwareInstalled => _firmwareVersion.isNotEmpty;
  String _t(String key) => Rpcs3UiLocale.text(context, key);
  String _tf(String key, Map<String, Object?> values) =>
      Rpcs3UiLocale.format(context, key, values);
  String get _failed => _t('operationFailed');

  @override
  void initState() {
    super.initState();
    _runtimeSubscription = Rpcs3InternalService.runtimeStates.listen((state) {
      if (mounted && _busy) {
        setState(() {
          _phase = state.phase;
          _progressMessage = switch (state.phase) {
            Rpcs3RuntimePhase.checkingJit ||
            Rpcs3RuntimePhase.enablingJit => _t('enabling'),
            Rpcs3RuntimePhase.initializingCore => _t('jitCoreWillPrepare'),
            Rpcs3RuntimePhase.installingFirmware => _t('installingFirmware'),
            Rpcs3RuntimePhase.importingContent => _t('importProgress'),
            Rpcs3RuntimePhase.ready => _t('ready'),
            _ => _progressMessage,
          };
        });
        _operationOverlayEntry?.markNeedsBuild();
      }
    });
    _contentProgressSubscription = Rpcs3ContentImportService.progress.listen((
      event,
    ) {
      if (mounted && _busy) {
        setState(() => _contentProgress = event);
        _operationOverlayEntry?.markNeedsBuild();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkFirmware();
    });
  }

  @override
  void dispose() {
    _operationOverlayEntry?.remove();
    _operationOverlayEntry = null;
    _runtimeSubscription?.cancel();
    _contentProgressSubscription?.cancel();
    super.dispose();
  }

  void _interaction(bool active) => widget.onInteractionChanged?.call(active);

  void _showOperationOverlay() {
    if (!widget.embedded || _operationOverlayEntry != null || !mounted) return;
    _operationOverlayEntry = OverlayEntry(
      builder: (overlayContext) =>
          _buildOperationOverlay(Theme.of(overlayContext).colorScheme),
    );
    Overlay.of(context, rootOverlay: true).insert(_operationOverlayEntry!);
  }

  void _hideOperationOverlay() {
    _operationOverlayEntry?.remove();
    _operationOverlayEntry = null;
  }

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
      _contentProgress = null;
    });
    _showOperationOverlay();
    _interaction(true);
    try {
      // The picker opens before JIT/Core preparation. Cancel keeps this gate.
      if (await Rpcs3InternalService.importFirmware()) {
        await _checkFirmware();
        if (!mounted) return;
        if (_firmwareInstalled) {
          _notice(_t('firmwareInstalled'));
        }
      }
    } on Rpcs3InternalException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '$_failed $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _hideOperationOverlay();
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
    if (!_firmwareInstalled && action != 'saves' && action != 'restoreSaves') {
      _interaction(true);
      return;
    }

    setState(() {
      _busy = true;
      _activeAction = action;
      _contentProgress = null;
      _progressMessage = switch (action) {
        'folder' => _t('openingFolder'),
        'saves' => _t('preparingSaves'),
        'restoreSaves' => _t('importingSaves'),
        _ => _t('selectingGames'),
      };
    });
    _showOperationOverlay();
    _interaction(true);
    try {
      if (action == 'games') {
        final result = await Rpcs3ContentImportService.importGames();
        if (result.imported > 0) await widget.onLibraryChanged();
        if (result.rejected > 0) {
          _notice(result.errors.isNotEmpty ? result.errors.first : _failed);
        }
      } else if (action == 'folder') {
        if (await Rpcs3ContentImportService.importExtractedGameFolder()) {
          await widget.onLibraryChanged();
        }
      } else if (action == 'saves') {
        await Rpcs3InternalService.exportSaveData();
        _notice(_t('savesAvailable'));
      } else if (action == 'restoreSaves') {
        final imported = await Rpcs3InternalService.importSaveDataFromFiles();
        _notice(_tf('savesImported', {'count': imported}));
      }
    } on Rpcs3InternalException catch (error) {
      _notice(error.message);
    } catch (error) {
      _notice('$_failed $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activeAction = null;
          _contentProgress = null;
        });
        _hideOperationOverlay();
        _interaction(false);
      }
    }
  }

  Widget _buildFirmwareGate() {
    final checkingLabel = _t('checkingFirmware');
    final progressLabel = _progressMessage.isNotEmpty
        ? _progressMessage
        : _phase == Rpcs3RuntimePhase.installingFirmware
        ? _t('installingFirmware')
        : _t('preparingInstallation');

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
                        : _t('firmwareRequired'),
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
                      _t('firmwareHelp'),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      key: const ValueKey('rpcs3-library-install-firmware'),
                      onPressed: _installFirmware,
                      icon: const Icon(Icons.file_upload_outlined),
                      label: Text(_t('installFirmware')),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(
                      onPressed: _busy ? null : _checkFirmware,
                      child: Text(_t('retry')),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy ? null : widget.onBack,
                    child: Text(_t('back')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOperationOverlay(ColorScheme scheme) {
    final exportingSaves = _activeAction == 'saves';
    final importingSaves = _activeAction == 'restoreSaves';
    final progress = _contentProgress;
    final fraction = progress?.fraction;
    final itemLabel = progress == null || progress.itemName.isEmpty
        ? (_progressMessage.isNotEmpty
              ? _progressMessage
              : _t('importProgress'))
        : progress.itemCount > 1
        ? '${_t('import')} ${progress.itemIndex}/${progress.itemCount} • ${progress.itemName}'
        : progress.itemName;
    final detail = progress?.detail.trim() ?? '';
    final percent = fraction == null ? null : (fraction * 100).round();

    return Positioned.fill(
      key: const ValueKey('rpcs3-import-progress-overlay'),
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.68),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Material(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(18.r),
              child: Padding(
                padding: EdgeInsets.all(24.r),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      exportingSaves
                          ? Icons.folder_copy_outlined
                          : importingSaves
                          ? Icons.restore_page_outlined
                          : Icons.downloading_rounded,
                      size: 42.r,
                    ),
                    SizedBox(height: 14.r),
                    Text(
                      exportingSaves
                          ? _t('exportingSaves')
                          : importingSaves
                          ? _t('importingSaveFiles')
                          : _t('importingGame'),
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 12.r),
                    Text(
                      itemLabel,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: 14.r),
                    LinearProgressIndicator(value: fraction),
                    SizedBox(height: 10.r),
                    if (percent != null)
                      Text(
                        '$percent %',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    if (detail.isNotEmpty) ...[
                      SizedBox(height: 8.r),
                      Text(
                        detail,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    SizedBox(height: 10.r),
                    Text(
                      exportingSaves
                          ? _t('filesFolderAvailable')
                          : importingSaves
                          ? _t('readingImport')
                          : _t('keepOpen'),
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.embedded && (_checking || !_firmwareInstalled)) {
      return _buildFirmwareGate();
    }
    final scheme = Theme.of(context).colorScheme;
    final button = SizedBox(
      width: 36.r,
      height: 36.r,
      child: PopupMenuButton<String>(
        key: const ValueKey('rpcs3-internal-import-menu'),
        tooltip: _t('importMenu'),
        enabled: !_busy && !_checking && _firmwareInstalled,
        padding: EdgeInsets.zero,
        onOpened: _opened,
        onCanceled: () => _interaction(false),
        onSelected: _selected,
        icon: _busy || _checking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                Icons.file_upload_outlined,
                size: 18.r,
                color: widget.embedded
                    ? scheme.onSurface
                    : scheme.onTertiaryFixed,
              ),
        itemBuilder: _menuItems,
      ),
    );
    if (widget.embedded) return button;
    return Stack(
      children: [
        Positioned(
          top: 8.r,
          right: 10.r,
          child: SafeArea(
            child: Material(
              color: scheme.tertiaryFixed,
              borderRadius: BorderRadius.circular(10.r),
              child: SizedBox(width: 36.r, height: 36.r, child: button),
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
        if (_busy) _buildOperationOverlay(scheme),
      ],
    );
  }

  List<PopupMenuEntry<String>> _menuItems(BuildContext context) => [
    PopupMenuItem(
      enabled: false,
      child: Text(
        '${_t('firmwareInstalledShort')} : $_firmwareVersion',
      ),
    ),
    const PopupMenuDivider(),
    PopupMenuItem(
      value: 'games',
      child: Text(_t('importGames')),
    ),
    PopupMenuItem(
      value: 'folder',
      child: Text(_t('importDecryptedFolder')),
    ),
    PopupMenuItem(
      value: 'firmware',
      child: Text(_t('installFirmware')),
    ),
    const PopupMenuDivider(),
    PopupMenuItem(
      value: 'open',
      child: Text(_t('openRpcs3')),
    ),
  ];
}
