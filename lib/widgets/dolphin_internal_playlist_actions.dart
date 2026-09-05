import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../l10n/dolphin_import_locale.dart';
import '../services/dolphin_internal_v2_service.dart';
import '../services/dolphin_system_files.dart';
import '../services/logger_service.dart';

/// An action inside the existing media tab pill, never a positioned overlay.
class DolphinInternalPlaylistActions extends StatefulWidget {
  final String systemFolder;
  final Future<void> Function() onLibraryChanged;
  final ValueChanged<bool>? onInteractionChanged;

  const DolphinInternalPlaylistActions({
    super.key,
    required this.systemFolder,
    required this.onLibraryChanged,
    this.onInteractionChanged,
  });

  @override
  State<DolphinInternalPlaylistActions> createState() =>
      _DolphinInternalPlaylistActionsState();
}

class _DolphinInternalPlaylistActionsState extends State<DolphinInternalPlaylistActions> {
  bool _busy = false;
  bool _interacting = false;
  Set<DolphinIplRegion> _regions = const {};

  bool get _isGameCube => widget.systemFolder.toLowerCase() == 'gc';
  String _text(String key) => DolphinImportLocale.text(context, key);

  void _interaction(bool active) {
    _interacting = active;
    widget.onInteractionChanged?.call(active);
  }

  @override
  void dispose() {
    if (_interacting) widget.onInteractionChanged?.call(false);
    super.dispose();
  }

  Future<void> _opened() async {
    _interaction(true);
    if (!_isGameCube) return;
    try {
      final regions = await DolphinInternalV2Service.installedIplRegions();
      if (mounted) setState(() => _regions = regions);
    } catch (_) {
      // Import remains available if the first inspection cannot read a slot.
    }
  }

  Future<bool> _confirm(String message, {String? title}) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title ?? _text('replaceTitle')),
          content: SingleChildScrollView(child: Text(message)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_text('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(_text('continue'))),
          ],
        ),
      ) ?? false;

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _selected(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      int? count;
      if (action == 'wiiMenu' && !_isGameCube) {
        final report = await DolphinInternalV2Service.launchWiiMenu();
        if (!report.ready) {
          _notice(report.failedStage == 'wii.menu_missing'
              ? _text('wiiMenuMissing')
              : report.message.isNotEmpty ? report.message : _text('wiiMenuFailed'));
        }
      } else if (action == 'games') {
        final result = await DolphinInternalV2Service.importGames(widget.systemFolder);
        if (result.imported > 0) await widget.onLibraryChanged();
        if (!mounted) return;
        if (result.rejected > 0) _notice(_text('failed'));
        if (result.imported > 0) count = result.imported;
      } else if (action.startsWith('ipl:')) {
        final region = DolphinIplRegion.values.byName(action.substring(4));
        if (await DolphinInternalV2Service.importIpl(region)) count = 1;
      } else if (action == 'wiiFiles') {
        if (!await _confirm(_text('filesHelp')) || !mounted) return;
        count = await DolphinInternalV2Service.importWiiSystemFiles();
      } else {
        final fromShared = action == 'shared';
        if (fromShared) {
          await DolphinInternalV2Service.sharedSystemDirectory(widget.systemFolder);
          if (!mounted) return;
          if (!await _confirm(
            _text('sharedHelp').replaceAll('{system}', _isGameCube ? 'GameCube' : 'Wii'),
            title: _text('shared'),
          ) || !mounted) return;
        }
        if (!_isGameCube && (!await _confirm(_text('replaceWii')) || !mounted)) return;
        count = await DolphinInternalV2Service.importSystemFolder(
          widget.systemFolder, fromShared: fromShared,
        );
      }
      if (!mounted) return;
      if (count != null) _notice(_text('imported').replaceAll('{count}', '$count'));
    } catch (error) {
      LoggerService.instance.w('Dolphin playlist action failed: $error');
      if (!mounted) return;
      final code = error is DolphinSystemFilesException ? error.code : '';
      final key = switch (code) {
        'invalidWii' => 'invalidWii',
        'invalidWiiFile' => 'filesHelp',
        'invalidIpl' || 'invalidGameCube' => 'invalidIpl',
        'busy' => 'busy',
        'wiiMenuMissing' => 'wiiMenuMissing',
        _ => error is FormatException ? 'invalidIpl' : 'failed',
      };
      _notice(_text(key));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _interaction(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS || !DolphinInternalV2Service.isDolphinSystem(widget.systemFolder)) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: 36.r,
      height: 36.r,
      child: PopupMenuButton<String>(
        key: const ValueKey('dolphin-import-menu'),
        tooltip: _text('import'),
        enabled: !_busy,
        padding: EdgeInsets.zero,
        onOpened: _opened,
        onCanceled: () => _interaction(false),
        onSelected: _selected,
        icon: _busy
            ? SizedBox(width: 18.r, height: 18.r, child: const CircularProgressIndicator(strokeWidth: 2))
            : Icon(Icons.file_upload_outlined, size: 18.r),
        itemBuilder: (context) => [
          PopupMenuItem(value: 'games', child: Text(_text('games'))),
          const PopupMenuDivider(),
          if (!_isGameCube) ...[
            PopupMenuItem(
              value: 'wiiMenu',
              child: Text(_text('launchWiiMenu')),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'folder', child: Text(_text('wiiFolder'))),
            PopupMenuItem(value: 'wiiFiles', child: Text(_text('wiiFiles'))),
          ] else ...[
            PopupMenuItem(value: 'folder', child: Text(_text('gcFolder'))),
            for (final region in DolphinIplRegion.values)
              PopupMenuItem(
                value: 'ipl:${region.name}',
                child: Text('${_regions.contains(region) ? '✓ ' : ''}${_text('ipl').replaceAll('{region}', region.name.toUpperCase())}'),
              ),
          ],
          const PopupMenuDivider(),
          PopupMenuItem(value: 'shared', child: Text(_text('shared'))),
        ],
      ),
    );
  }
}
