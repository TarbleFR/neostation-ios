import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../services/armsx2_internal_service.dart';
import '../services/stikjit_armsx2_service.dart';

class Armsx2InternalPlaylistActions extends StatefulWidget {
  const Armsx2InternalPlaylistActions({
    super.key,
    required this.onLibraryChanged,
    this.onInteractionChanged,
    this.embedded = false,
  });

  final Future<void> Function() onLibraryChanged;
  final ValueChanged<bool>? onInteractionChanged;
  final bool embedded;

  @override
  State<Armsx2InternalPlaylistActions> createState() =>
      _Armsx2InternalPlaylistActionsState();
}

class _Armsx2InternalPlaylistActionsState
    extends State<Armsx2InternalPlaylistActions> {
  bool _busy = false;

  bool get _fr => Localizations.localeOf(context).languageCode == 'fr';

  void _interaction(bool active) => widget.onInteractionChanged?.call(active);

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _selected(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    _interaction(true);
    try {
      if (action == 'games') {
        final result = await Armsx2InternalService.importGames();
        if (result.imported > 0) {
          await widget.onLibraryChanged();
          _notice(
            _fr
                ? '${result.imported} jeu(x) PS2 importé(s).'
                : '${result.imported} PS2 game(s) imported.',
          );
        }
        if (result.rejected > 0) {
          _notice(
            result.errors.isNotEmpty
                ? result.errors.first
                : (_fr ? 'Certains jeux ont été rejetés.' : 'Some games were rejected.'),
          );
        }
      } else if (action == 'boot_bios') {
        final launched = await StikJitArmsx2Service.launchBios();
        if (!launched) {
          _notice(
            StikJitArmsx2Service.lastError ??
                (_fr ? 'Impossible de démarrer le BIOS PS2.' : 'Could not boot the PS2 BIOS.'),
          );
        }
      } else if (action == 'bios') {
        final result = await Armsx2InternalService.importBios();
        if (result.imported > 0) {
          _notice(
            _fr
                ? 'BIOS importé dans Sur mon iPhone → NeoStation → ARMSX2 → BIOS.'
                : 'BIOS imported to On My iPhone → NeoStation → ARMSX2 → BIOS.',
          );
        } else if (result.rejected > 0) {
          _notice(result.errors.isNotEmpty ? result.errors.first : 'BIOS import failed.');
        }
      }
    } catch (error) {
      _notice(_fr ? 'Échec de l’import ARMSX2 : $error' : 'ARMSX2 import failed: $error');
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
        key: const ValueKey('armsx2-internal-import-menu'),
        tooltip: _fr ? 'ARMSX2 / Importer' : 'ARMSX2 / Import',
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
          PopupMenuItem(
            value: 'games',
            child: Text(_fr ? 'Importer des jeux' : 'Import games'),
          ),
          PopupMenuItem(
            value: 'bios',
            child: Text(_fr ? 'Importer le BIOS' : 'Import BIOS'),
          ),
          PopupMenuItem(
            value: 'boot_bios',
            child: Text(
              _fr ? 'Démarrer le BIOS PS2' : 'Boot PS2 BIOS',
            ),
          ),
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
