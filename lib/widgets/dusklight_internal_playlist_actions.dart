import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../services/dusklight_internal_service.dart';
import '../services/logger_service.dart';
import '../l10n/dusklight_locale.dart';

class DusklightInternalPlaylistActions extends StatefulWidget {
  const DusklightInternalPlaylistActions({
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
  State<DusklightInternalPlaylistActions> createState() =>
      _DusklightInternalPlaylistActionsState();
}

class _DusklightInternalPlaylistActionsState
    extends State<DusklightInternalPlaylistActions> {
  bool _busy = false;

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _import() async {
    if (_busy) return;
    final locale = Localizations.localeOf(context);
    setState(() => _busy = true);
    widget.onInteractionChanged?.call(true);
    try {
      final result = await DusklightInternalService.importGames();
      if (result.imported > 0) {
        await widget.onLibraryChanged();
        final enrich = widget.onGamesImported;
        if (enrich != null) unawaited(enrich(result.importedPaths));
        _notice(DusklightLocale.forLocale(locale, 'imported', count: result.imported));
      }
      if (result.rejected > 0) {
        if (result.errors.isEmpty) {
          _notice(DusklightLocale.forLocale(locale, 'rejected'));
        } else {
          final issue = result.errors.first;
          _notice('${issue.fileName}: ${DusklightLocale.forLocale(locale, issue.messageKey)}');
          for (final error in result.errors) {
            LoggerService.instance.w('[Dusklight import] ${error.fileName}: '
                '${error.messageKey} ${error.details ?? ""}');
          }
        }
      }
    } catch (error) {
      LoggerService.instance.w('[Dusklight import] $error');
      _notice(DusklightLocale.forLocale(locale, 'importFailed'));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
      // The first import replaces the empty-view action with the tab action.
      // Release the parent's navigation even if that replacement disposed us.
      widget.onInteractionChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final button = SizedBox(
      width: 100.r,
      height: 36.r,
      child: TextButton.icon(
        key: const ValueKey('dusklight-internal-import'),
        style: TextButton.styleFrom(
          padding: EdgeInsets.symmetric(horizontal: 8.r),
          foregroundColor: widget.embedded ? scheme.onSurface : scheme.onTertiaryFixed,
        ),
        onPressed: _busy ? null : _import,
        icon: _busy
            ? SizedBox(
                width: 18.r,
                height: 18.r,
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(Icons.file_upload_outlined, size: 18.r),
        label: Text('Dusklight', maxLines: 1, style: TextStyle(fontSize: 12.r)),
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
