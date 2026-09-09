import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../services/rpcs3_internal_service.dart';

class Rpcs3InternalPlaylistActions extends StatefulWidget {
  const Rpcs3InternalPlaylistActions({
    super.key,
    required this.onLibraryChanged,
    this.onInteractionChanged,
  });

  final Future<void> Function() onLibraryChanged;
  final ValueChanged<bool>? onInteractionChanged;

  @override
  State<Rpcs3InternalPlaylistActions> createState() =>
      _Rpcs3InternalPlaylistActionsState();
}

class _Rpcs3InternalPlaylistActionsState
    extends State<Rpcs3InternalPlaylistActions> {
  bool _busy = false;
  String _firmwareVersion = '';

  bool get _fr => Localizations.localeOf(context).languageCode == 'fr';
  String get _import => _fr ? 'Importer' : 'Import';
  String get _games => _fr ? 'Importer des jeux' : 'Import games';
  String get _folder =>
      _fr ? 'Importer un dossier de jeu' : 'Import game folder';
  String get _firmware =>
      _fr ? 'Importer le firmware PS3' : 'Import PS3 firmware';
  String get _firmwareMissing => _fr ? 'Firmware requis' : 'Firmware required';
  String get _failed =>
      _fr ? 'Échec de l’importation RPCS3.' : 'RPCS3 import failed.';

  void _interaction(bool active) => widget.onInteractionChanged?.call(active);

  Future<void> _opened() async {
    _interaction(true);
    try {
      if (await Rpcs3InternalService.hasFirmware() && mounted) {
        final version = await Rpcs3InternalService.firmwareVersion();
        if (mounted) setState(() => _firmwareVersion = version);
      }
    } catch (_) {}
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _selected(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (action == 'games') {
        final result = await Rpcs3InternalService.importGames();
        if (result.imported > 0) await widget.onLibraryChanged();
        if (result.rejected > 0) {
          _notice(result.errors.isNotEmpty ? result.errors.first : _failed);
        }
      } else if (action == 'folder') {
        if (await Rpcs3InternalService.importExtractedGameFolder()) {
          await widget.onLibraryChanged();
        }
      } else if (action == 'firmware') {
        if (await Rpcs3InternalService.importFirmware()) {
          _firmwareVersion = await Rpcs3InternalService.firmwareVersion();
          if (mounted) setState(() {});
        }
      }
    } on Rpcs3InternalException catch (error) {
      _notice(error.message);
    } catch (error) {
      _notice('$_failed $error');
    } finally {
      if (mounted) setState(() => _busy = false);
      _interaction(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final firmwareLabel = _firmwareVersion.isEmpty
        ? _firmwareMissing
        : '${_fr ? 'Firmware installé' : 'Firmware installed'}: $_firmwareVersion';

    return Container(
      width: 36.r,
      height: 36.r,
      decoration: BoxDecoration(
        color: scheme.tertiaryFixed,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: scheme.tertiaryFixed, width: 2.r),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.3),
            blurRadius: 3.r,
            offset: Offset(1.5.r, 1.5.r),
          ),
        ],
      ),
      child: PopupMenuButton<String>(
        key: const ValueKey('rpcs3-internal-import-menu'),
        tooltip: _import,
        enabled: !_busy,
        padding: EdgeInsets.zero,
        onOpened: _opened,
        onCanceled: () => _interaction(false),
        onSelected: _selected,
        icon: _busy
            ? SizedBox(
                width: 18.r,
                height: 18.r,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onTertiaryFixed,
                ),
              )
            : Icon(
                Icons.file_upload_outlined,
                size: 18.r,
                color: scheme.onTertiaryFixed,
              ),
        itemBuilder: (context) => [
          PopupMenuItem(
            enabled: false,
            child: Row(
              children: [
                Icon(
                  _firmwareVersion.isEmpty
                      ? Icons.warning_amber_rounded
                      : Icons.check_circle_outline,
                  size: 18.r,
                ),
                SizedBox(width: 8.r),
                Expanded(child: Text(firmwareLabel)),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(value: 'games', child: Text(_games)),
          PopupMenuItem(value: 'folder', child: Text(_folder)),
          const PopupMenuDivider(),
          PopupMenuItem(value: 'firmware', child: Text(_firmware)),
        ],
      ),
    );
  }
}
