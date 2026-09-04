import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../services/dolphin_embedded_service.dart';

/// Top-right controls shown only on NeoStation's native GameCube and Wii
/// playlists. The controls never expose Dolphin's private folder structure.
class DolphinPlaylistActions extends StatefulWidget {
  const DolphinPlaylistActions({
    super.key,
    required this.systemFolder,
    required this.onLibraryChanged,
  });

  final String systemFolder;
  final Future<void> Function() onLibraryChanged;

  @override
  State<DolphinPlaylistActions> createState() =>
      _DolphinPlaylistActionsState();
}

class _DolphinPlaylistActionsState extends State<DolphinPlaylistActions> {
  bool _busy = false;
  Set<DolphinIplRegion> _installedIpl = const <DolphinIplRegion>{};

  bool get _isGameCube => widget.systemFolder.trim().toLowerCase() == 'gc';

  @override
  void initState() {
    super.initState();
    _reloadIplBadges();
  }

  Future<void> _reloadIplBadges() async {
    if (!_isGameCube) return;
    final installed = await DolphinEmbeddedService.installedIplRegions();
    if (!mounted) return;
    setState(() => _installedIpl = installed);
  }

  Future<void> _importGames() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await DolphinEmbeddedService.importGamesFromPicker(
        widget.systemFolder,
      );
      if (!mounted || result == null) return;
      await widget.onLibraryChanged();
      if (!mounted) return;

      final rejectedCount = result.rejected.length;
      final message = rejectedCount == 0
          ? '${result.imported} game${result.imported == 1 ? '' : 's'} imported.'
          : '${result.imported} imported, $rejectedCount rejected. Check Dolphin logs.';
      _showMessage(message, error: rejectedCount > 0);
    } catch (error) {
      if (mounted) _showMessage('Import failed: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseAndImportIpl() async {
    if (_busy || !_isGameCube) return;
    final region = await showDialog<DolphinIplRegion>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Import GameCube IPL'),
        content: const Text(
          'Choose the slot for your own 2 MiB IPL dump. NeoStation validates '
          'the file content before installing it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          for (final value in DolphinIplRegion.values)
            FilledButton.tonal(
              onPressed: () => Navigator.pop(dialogContext, value),
              child: Text(value.label),
            ),
        ],
      ),
    );
    if (region == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final result = await DolphinEmbeddedService.importIplFromPicker(region);
      if (!mounted || result == null) return;
      await _reloadIplBadges();
      if (!mounted) return;
      _showMessage(
        result.message +
            (result.crc32Hex == null ? '' : ' CRC32 ${result.crc32Hex}.'),
        error: !result.accepted,
      );
    } catch (error) {
      if (mounted) _showMessage('IPL import failed: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message, {required bool error}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.inverseSurface,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS ||
        !DolphinEmbeddedService.isDolphinSystemFolder(widget.systemFolder)) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 8.r,
      right: MediaQuery.paddingOf(context).right + 10.r,
      child: Material(
        elevation: 8,
        color: scheme.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(14.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14.r),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isGameCube)
                for (final region in DolphinIplRegion.values)
                  if (_installedIpl.contains(region))
                    Padding(
                      padding: EdgeInsets.only(right: 5.r),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(10.r),
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 7.r,
                            vertical: 4.r,
                          ),
                          child: Text(
                            '✓ IPL ${region.label}',
                            style: TextStyle(
                              color: scheme.onPrimaryContainer,
                              fontSize: 10.r,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
              if (_isGameCube) ...[
                OutlinedButton.icon(
                  onPressed: _busy ? null : _chooseAndImportIpl,
                  icon: Icon(Symbols.memory_rounded, size: 15.r),
                  label: const Text('IPL'),
                ),
                SizedBox(width: 6.r),
              ],
              FilledButton.icon(
                onPressed: _busy ? null : _importGames,
                icon: _busy
                    ? SizedBox.square(
                        dimension: 14.r,
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Symbols.file_upload_rounded, size: 16.r),
                label: const Text('Import'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
