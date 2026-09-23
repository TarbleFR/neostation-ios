import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../services/dusklight_internal_service.dart';

class DusklightInternalPlaylistActions extends StatefulWidget {
  const DusklightInternalPlaylistActions({
    super.key,
    required this.onLibraryChanged,
    this.onInteractionChanged,
    this.embedded = false,
  });

  final Future<void> Function() onLibraryChanged;
  final ValueChanged<bool>? onInteractionChanged;
  final bool embedded;

  @override
  State<DusklightInternalPlaylistActions> createState() =>
      _DusklightInternalPlaylistActionsState();
}

class _DusklightInternalPlaylistActionsState
    extends State<DusklightInternalPlaylistActions> {
  bool _busy = false;

  bool get _fr => Localizations.localeOf(context).languageCode == 'fr';

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    widget.onInteractionChanged?.call(true);
    try {
      final result = await DusklightInternalService.importGames();
      if (result.imported > 0) {
        await widget.onLibraryChanged();
        _notice(
          _fr
              ? '${result.imported} disque(s) Dusklight importé(s).'
              : '${result.imported} Dusklight disc(s) imported.',
        );
      }
      if (result.rejected > 0) {
        _notice(
          result.errors.isNotEmpty
              ? result.errors.first
              : (_fr ? 'Certains fichiers ont été rejetés.' : 'Some files were rejected.'),
        );
      }
    } catch (error) {
      _notice(
        _fr
            ? 'Échec de l’import Dusklight : $error'
            : 'Dusklight import failed: $error',
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        widget.onInteractionChanged?.call(false);
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
      child: IconButton(
        key: const ValueKey('dusklight-internal-import'),
        tooltip: _fr ? 'Importer un jeu Dusklight' : 'Import a Dusklight game',
        onPressed: _busy ? null : _import,
        icon: _busy
            ? SizedBox(
                width: 18.r,
                height: 18.r,
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(Icons.file_upload_outlined, size: 18.r),
        color: widget.embedded ? scheme.onSurface : scheme.onTertiaryFixed,
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
