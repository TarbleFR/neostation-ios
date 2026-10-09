import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../l10n/libretro_locale.dart';
import '../screens/libretro/libretro_skin_manager_screen.dart';
import '../services/libretro_core_catalog.dart';
import '../services/libretro_internal_service.dart';

/// Import button of the playlists run by the embedded libretro engine: the
/// same floating button and tab action as the other embedded engines. Its
/// menu also opens the skins of the playlist's console.
class LibretroInternalPlaylistActions extends StatefulWidget {
  const LibretroInternalPlaylistActions({
    super.key,
    required this.systemFolder,
    required this.onLibraryChanged,
    this.onInteractionChanged,
    this.embedded = false,
  });

  final String systemFolder;
  final Future<void> Function() onLibraryChanged;
  final ValueChanged<bool>? onInteractionChanged;
  final bool embedded;

  @override
  State<LibretroInternalPlaylistActions> createState() =>
      _LibretroInternalPlaylistActionsState();
}

class _LibretroInternalPlaylistActionsState
    extends State<LibretroInternalPlaylistActions> {
  bool _busy = false;

  String _t(String key) => LibretroLocale.text(context, key);
  String _f(String key, Map<String, Object?> values) =>
      LibretroLocale.formatContext(context, key, values);

  void _interaction(bool active) => widget.onInteractionChanged?.call(active);

  /// Embedded console of the playlist (skins belong to the console, not to
  /// the folder); null when the folder is not bound to one.
  String? get _console => LibretroCoreCatalog.bindingFor(widget.systemFolder)?.console;

  Future<void> _openSkins() async {
    final console = _console;
    _interaction(true);
    try {
      if (console == null) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LibretroSkinManagerScreen(console: console),
        ),
      );
    } finally {
      if (mounted) _interaction(false);
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _selected(String action) async {
    if (_busy) return;
    if (action == 'skins') {
      await _openSkins();
      return;
    }
    setState(() => _busy = true);
    _interaction(true);
    try {
      if (action == 'games') {
        final result = await LibretroInternalService.importGames(widget.systemFolder);
        if (result.imported > 0) {
          await widget.onLibraryChanged();
          _notice(_f('gamesImported', {'count': result.imported}));
        }
        if (result.rejected > 0) _notice(_t('gamesRejected'));
      } else if (action == 'retroarch') {
        final copied = await LibretroInternalService.copyRetroArchData();
        if (copied == null) return;
        _notice(
          copied.total == 0
              ? _t('retroArchNothing')
              : _f('retroArchImported', {
                  'saves': copied.saves,
                  'states': copied.states,
                  'system': copied.system,
                }),
        );
      }
    } catch (error) {
      _notice(_f('importFailed', {'error': error}));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _interaction(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final button = SizedBox(
      width: 36.r,
      height: 36.r,
      child: PopupMenuButton<String>(
        key: const ValueKey('libretro-internal-import-menu'),
        tooltip: _t('importMenu'),
        enabled: !_busy,
        padding: EdgeInsets.zero,
        onOpened: () => _interaction(true),
        onCanceled: () => _interaction(false),
        onSelected: _selected,
        icon: _busy
            ? SizedBox(
                width: 18.r,
                height: 18.r,
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                Icons.file_upload_outlined,
                size: 18.r,
                color: widget.embedded ? scheme.onSurface : scheme.onTertiaryFixed,
              ),
        itemBuilder: (context) => [
          PopupMenuItem(value: 'games', child: Text(_t('importGames'))),
          PopupMenuItem(value: 'retroarch', child: Text(_t('importRetroArch'))),
          if (_console != null)
            PopupMenuItem(value: 'skins', child: Text(_t('skins'))),
        ],
      ),
    );
    if (widget.embedded) return button;
    return Material(
      color: scheme.tertiaryFixed,
      borderRadius: BorderRadius.circular(10.r),
      elevation: 2,
      child: button,
    );
  }
}
