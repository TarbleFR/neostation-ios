import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../l10n/dusklight_locale.dart';
import '../l10n/ports_locale.dart';
import '../services/dusklight_internal_service.dart';
import '../services/kartpad_internal_service.dart';
import '../services/logger_service.dart';

enum _PortsImportTarget { dusklight, kartPad }

class PortsInternalPlaylistActions extends StatefulWidget {
  const PortsInternalPlaylistActions({
    super.key,
    required this.onLibraryChanged,
    this.onInteractionChanged,
    this.embedded = false,
    this.onGamesImported,
  });

  final Future<void> Function() onLibraryChanged;
  final ValueChanged<bool>? onInteractionChanged;
  final bool embedded;
  final Future<void> Function(List<String>)? onGamesImported;

  @override
  State<PortsInternalPlaylistActions> createState() =>
      _PortsInternalPlaylistActionsState();
}

class _PortsInternalPlaylistActionsState
    extends State<PortsInternalPlaylistActions> {
  bool _busy = false;

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _runImport(_PortsImportTarget target) async {
    if (_busy) return;
    final locale = Localizations.localeOf(context);
    setState(() => _busy = true);
    try {
      if (target == _PortsImportTarget.dusklight) {
        final result = await DusklightInternalService.importGames();
        if (result.imported > 0) {
          await widget.onLibraryChanged();
          final enrich = widget.onGamesImported;
          if (enrich != null) unawaited(enrich(result.importedPaths));
          _notice(DusklightLocale.forLocale(
            locale,
            'imported',
            count: result.imported,
          ));
        }
        if (result.rejected > 0) {
          final issue = result.errors.isEmpty ? null : result.errors.first;
          _notice(issue == null
              ? DusklightLocale.forLocale(locale, 'rejected')
              : '${issue.fileName}: ${DusklightLocale.forLocale(locale, issue.messageKey)}');
        }
        return;
      }

      final result = await KartPadInternalService.importGame();
      if (result.imported > 0) {
        await widget.onLibraryChanged();
        final enrich = widget.onGamesImported;
        if (enrich != null) unawaited(enrich(result.importedPaths));
        _notice(PortsLocale.forLocale(locale, 'kartpadImported'));
      }
      if (result.rejected > 0) {
        final issue = result.errors.isEmpty ? null : result.errors.first;
        _notice(issue == null
            ? PortsLocale.forLocale(locale, 'kartpadImportFailed')
            : '${issue.fileName}: ${PortsLocale.forLocale(locale, issue.messageKey)}');
        for (final error in result.errors) {
          LoggerService.instance.w(
            '[KartPad import] ${error.fileName}: '
            '${error.messageKey} ${error.details ?? ""}',
          );
        }
      }
    } catch (error) {
      LoggerService.instance.w('[Ports import] $error');
      _notice(target == _PortsImportTarget.dusklight
          ? DusklightLocale.forLocale(locale, 'importFailed')
          : PortsLocale.forLocale(locale, 'kartpadImportFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onInteractionChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) return const SizedBox.shrink();
    final locale = Localizations.localeOf(context);
    final scheme = Theme.of(context).colorScheme;
    final foreground =
        widget.embedded ? scheme.onSurface : scheme.onTertiaryFixed;
    final popup = PopupMenuButton<_PortsImportTarget>(
      key: const ValueKey('ports-internal-import'),
      enabled: !_busy,
      tooltip: PortsLocale.forLocale(locale, 'import'),
      onOpened: () => widget.onInteractionChanged?.call(true),
      onCanceled: () => widget.onInteractionChanged?.call(false),
      onSelected: (target) => unawaited(_runImport(target)),
      itemBuilder: (context) => <PopupMenuEntry<_PortsImportTarget>>[
        PopupMenuItem(
          value: _PortsImportTarget.dusklight,
          child: Text(PortsLocale.forLocale(locale, 'dusklight')),
        ),
        PopupMenuItem(
          value: _PortsImportTarget.kartPad,
          child: Text(PortsLocale.forLocale(locale, 'kartpad')),
        ),
      ],
      child: SizedBox(
        width: 104.r,
        height: 36.r,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_busy)
              SizedBox(
                width: 18.r,
                height: 18.r,
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(Icons.file_upload_outlined, size: 18.r, color: foreground),
            SizedBox(width: 6.r),
            Flexible(
              child: Text(
                PortsLocale.forLocale(locale, 'import'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.r, color: foreground),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18.r, color: foreground),
          ],
        ),
      ),
    );
    if (widget.embedded) return popup;
    return Material(
      color: scheme.tertiaryFixed,
      borderRadius: BorderRadius.circular(10.r),
      elevation: 2,
      child: popup,
    );
  }
}
