import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../services/dolphin_internal_v2_service.dart';

/// GameCube/Wii-only controls rendered on the native NeoStation playlist.
///
/// For every other system this widget returns an empty box and performs no
/// initialization, JIT work, file access or routing changes.
class DolphinInternalPlaylistActions extends StatefulWidget {
  final String systemFolder;
  final Future<void> Function() onLibraryChanged;

  const DolphinInternalPlaylistActions({
    super.key,
    required this.systemFolder,
    required this.onLibraryChanged,
  });

  @override
  State<DolphinInternalPlaylistActions> createState() =>
      _DolphinInternalPlaylistActionsState();
}

class _DolphinInternalPlaylistActionsState
    extends State<DolphinInternalPlaylistActions> {
  bool _busy = false;
  Set<DolphinIplRegion> _regions = const {};

  bool get _isDolphinPlaylist =>
      Platform.isIOS &&
      DolphinInternalV2Service.isDolphinSystem(widget.systemFolder);

  bool get _isGameCube => widget.systemFolder.toLowerCase() == 'gc';

  @override
  void initState() {
    super.initState();
    if (_isGameCube && _isDolphinPlaylist) {
      _reloadIplBadges();
    }
  }

  @override
  void didUpdateWidget(covariant DolphinInternalPlaylistActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.systemFolder != widget.systemFolder &&
        _isGameCube &&
        _isDolphinPlaylist) {
      _reloadIplBadges();
    }
  }

  Future<void> _reloadIplBadges() async {
    final regions = await DolphinInternalV2Service.installedIplRegions();
    if (mounted) setState(() => _regions = regions);
  }

  Future<void> _importGames() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await DolphinInternalV2Service.importGames(
        widget.systemFolder,
      );
      if (result.imported > 0) await widget.onLibraryChanged();
      if (!mounted) return;
      final details = result.errors.isEmpty ? '' : '\n${result.errors.first}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${result.imported} game(s) imported, '
            '${result.rejected} rejected.$details',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Dolphin import failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importIpl(DolphinIplRegion region) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await DolphinInternalV2Service.importIpl(region);
      await _reloadIplBadges();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✓ IPL ${region.name.toUpperCase()} validated'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('IPL rejected: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDolphinPlaylist) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Positioned(
      top: 8.r,
      right: 10.r,
      child: SafeArea(
        child: Material(
          color: theme.colorScheme.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(12.r),
          elevation: 3,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isGameCube) ...[
                  for (final region in DolphinIplRegion.values)
                    if (_regions.contains(region))
                      Padding(
                        padding: EdgeInsets.only(right: 5.r),
                        child: Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text(
                            '✓ IPL ${region.name.toUpperCase()}',
                            style: TextStyle(fontSize: 9.r),
                          ),
                        ),
                      ),
                  PopupMenuButton<DolphinIplRegion>(
                    tooltip: 'Import GameCube IPL',
                    enabled: !_busy,
                    onSelected: _importIpl,
                    itemBuilder: (_) => DolphinIplRegion.values
                        .map(
                          (region) => PopupMenuItem(
                            value: region,
                            child: Text(
                              'Import IPL ${region.name.toUpperCase()}',
                            ),
                          ),
                        )
                        .toList(),
                    icon: Icon(Icons.memory_rounded, size: 19.r),
                  ),
                  SizedBox(width: 4.r),
                ],
                FilledButton.icon(
                  onPressed: _busy ? null : _importGames,
                  icon: _busy
                      ? SizedBox(
                          width: 14.r,
                          height: 14.r,
                          child: const CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : Icon(Icons.file_upload_outlined, size: 17.r),
                  label: const Text('Import'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
