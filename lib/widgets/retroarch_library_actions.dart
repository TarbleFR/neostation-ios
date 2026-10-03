import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../l10n/retroarch_locale.dart';
import '../services/retroarch_core_catalog.dart';
import '../services/retroarch_core_preferences.dart';
import '../services/retroarch_import_service.dart';
import '../services/retroarch_internal_service.dart';

typedef RetroArchPackagedCoreProbe = Future<Set<String>> Function();
typedef RetroArchLibraryImporter =
    Future<RetroArchImportResult> Function({
      required String systemFolder,
      bool bios,
      bool replace,
    });

/// Console-wide core selection sits beside the existing library Import action.
/// Only signed cores actually present in the application are selectable.
class RetroArchLibraryActions extends StatefulWidget {
  const RetroArchLibraryActions({
    super.key,
    required this.systemFolder,
    required this.onLibraryChanged,
    this.onInteractionChanged,
    this.embedded = false,
    this.packagedCoreProbe,
    this.fileImporter,
    this.folderImporter,
  });

  final String systemFolder;
  final Future<void> Function() onLibraryChanged;
  final ValueChanged<bool>? onInteractionChanged;
  final bool embedded;
  final RetroArchPackagedCoreProbe? packagedCoreProbe;
  final RetroArchLibraryImporter? fileImporter;
  final RetroArchLibraryImporter? folderImporter;

  /// Existing Files sharing exposes every user directory, including saves and
  /// editable configurations; no external app grant or undocumented URL needed.
  static Future<void> showFolders(BuildContext context) async {
    await RetroArchInternalService.ensureLayout();
    final root = await RetroArchInternalService.rootDirectory();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(RetroArchLocale.text(context, 'managedFolders')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(RetroArchLocale.text(context, 'folderHelp')),
              const SizedBox(height: 16),
              for (final folder in const [
                'games',
                'system',
                'saves',
                'states',
                'config',
                'shaders',
                'overlays',
                'cheats',
                'logs',
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SelectableText('${root.path}/$folder'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(RetroArchLocale.text(context, 'back')),
          ),
        ],
      ),
    );
  }

  @override
  State<RetroArchLibraryActions> createState() =>
      _RetroArchLibraryActionsState();
}

class _RetroArchLibraryActionsState extends State<RetroArchLibraryActions> {
  bool _busy = false;
  bool _interacting = false;
  bool _loaded = false;
  bool _replace = false;
  RetroArchCoreDescriptor? _selected;
  List<RetroArchCoreDescriptor> _cores = const [];
  String? _details;

  String _text(String key) => RetroArchLocale.text(context, key);

  @override
  void initState() {
    super.initState();
    _loadCores();
  }

  @override
  void didUpdateWidget(RetroArchLibraryActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.systemFolder != widget.systemFolder) _loadCores();
  }

  @override
  void dispose() {
    if (_interacting) widget.onInteractionChanged?.call(false);
    super.dispose();
  }

  void _interaction(bool active) {
    _interacting = active;
    widget.onInteractionChanged?.call(active);
  }

  Future<void> _loadCores() async {
    final folder = widget.systemFolder;
    try {
      final packaged =
          await (widget.packagedCoreProbe ??
              RetroArchInternalService.packagedCoreIdentifiers)();
      final cores = RetroArchCoreCatalog.coresForSystem(
        folder,
      ).where((core) => packaged.contains(core.identifier)).toList();
      RetroArchCoreDescriptor? selected;
      String? details;
      try {
        selected = await RetroArchCorePreferences.preferredCore(folder);
      } catch (error) {
        details = error.toString();
      }
      if (!mounted || folder != widget.systemFolder) return;
      setState(() {
        _cores = cores;
        _selected = selected;
        _details = details;
        _loaded = true;
      });
    } catch (error) {
      if (!mounted || folder != widget.systemFolder) return;
      setState(() {
        _cores = const [];
        _details = error.toString();
        _loaded = true;
      });
    }
  }

  bool get _selectedAvailable =>
      _selected != null &&
      _cores.any((core) => core.identifier == _selected!.identifier);

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _problem(String key, String details) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_text(key)),
        content: SingleChildScrollView(
          child: ExpansionTile(
            title: Text(_text('technicalDetails')),
            children: [SelectableText(details)],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_text('back')),
          ),
        ],
      ),
    );
  }

  Future<void> _chooseCore(String identifier) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Recheck the package after the menu opens; catalogue rows alone do not
      // authorize a core absent from the signed application.
      final packaged =
          await (widget.packagedCoreProbe ??
              RetroArchInternalService.packagedCoreIdentifiers)();
      if (!packaged.contains(identifier)) {
        throw StateError('RETROARCH_CORE_UNAVAILABLE: $identifier');
      }
      await RetroArchCorePreferences.setPreferredCore(
        widget.systemFolder,
        identifier,
      );
      await _loadCores();
      _notice(_text('coreSaved'));
    } catch (error) {
      await _problem('coreUnavailable', error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
      _interaction(false);
    }
  }

  Future<void> _action(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    _interaction(true);
    try {
      if (action == 'files') {
        await RetroArchLibraryActions.showFolders(context);
      } else if (action == 'scan') {
        await widget.onLibraryChanged();
      } else if (action == 'replace') {
        if (_replace) {
          if (mounted) setState(() => _replace = false);
        } else {
          final accepted =
              await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(_text('replaceTitle')),
                  content: Text(_text('replaceHelp')),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(_text('cancel')),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(_text('confirm')),
                    ),
                  ],
                ),
              ) ??
              false;
          if (mounted) setState(() => _replace = accepted);
        }
      } else if (action == 'details') {
        await _problem(
          'coreUnavailable',
          _details ?? 'RETROARCH_CORE_UNAVAILABLE',
        );
      } else {
        final importer = action.endsWith('Folder')
            ? widget.folderImporter ?? RetroArchImportService.importFolder
            : widget.fileImporter ?? RetroArchImportService.importFiles;
        final bios = action.startsWith('bios');
        final result = await importer(
          systemFolder: widget.systemFolder,
          bios: bios,
          replace: _replace,
        );
        if (!bios && result.imported > 0) await widget.onLibraryChanged();
        if (!mounted) return;
        if (result.imported > 0 || result.skipped > 0) {
          _notice(
            RetroArchLocale.format(context, 'migrationCopied', {
              'count': result.imported,
              'skipped': result.skipped,
            }),
          );
        }
        if (result.errors.isNotEmpty) {
          await _problem('importFailed', result.errors.join('\n'));
        }
      }
    } catch (error) {
      await _problem('importFailed', error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
      _interaction(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!RetroArchCoreCatalog.supportsSystem(widget.systemFolder)) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 144.r,
          height: 36.r,
          child: PopupMenuButton<String>(
            key: const ValueKey('retroarch-core-menu'),
            tooltip:
                '${_text('coreChoice')}: ${_selected?.displayName ?? _text('coreUnavailable')}',
            enabled: !_busy && _loaded && _cores.isNotEmpty,
            padding: EdgeInsets.zero,
            onOpened: () => _interaction(true),
            onCanceled: () => _interaction(false),
            onSelected: _chooseCore,
            itemBuilder: (context) => [
              for (final core in _cores)
                CheckedPopupMenuItem(
                  value: core.identifier,
                  checked: core.identifier == _selected?.identifier,
                  child: Text(core.displayName),
                ),
            ],
            child: Row(
              children: [
                const SizedBox(width: 6),
                if (_loaded && !_selectedAvailable)
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 16.r,
                    color: scheme.error,
                  ),
                Expanded(
                  child: Text(
                    !_loaded
                        ? _text('loading')
                        : _selected?.displayName ?? _text('core'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.r, color: scheme.onSurface),
                  ),
                ),
                Icon(Icons.arrow_drop_down, size: 18.r),
              ],
            ),
          ),
        ),
        SizedBox(
          width: 36.r,
          height: 36.r,
          child: PopupMenuButton<String>(
            key: const ValueKey('retroarch-import-menu'),
            tooltip: _text('import'),
            enabled: !_busy,
            padding: EdgeInsets.zero,
            onOpened: () => _interaction(true),
            onCanceled: () => _interaction(false),
            onSelected: _action,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.file_upload_outlined,
                    size: 18.r,
                    color: scheme.onSurface,
                  ),
            itemBuilder: (context) => [
              PopupMenuItem(value: 'games', child: Text(_text('games'))),
              PopupMenuItem(
                value: 'gamesFolder',
                child: Text(_text('gamesFolder')),
              ),
              PopupMenuItem(value: 'bios', child: Text(_text('bios'))),
              PopupMenuItem(
                value: 'biosFolder',
                child: Text(_text('biosFolder')),
              ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                value: 'replace',
                checked: _replace,
                child: Text(_text('replaceTitle')),
              ),
              PopupMenuItem(value: 'files', child: Text(_text('files'))),
              PopupMenuItem(value: 'scan', child: Text(_text('scan'))),
              if (_loaded && !_selectedAvailable)
                PopupMenuItem(
                  value: 'details',
                  child: Text(_text('technicalDetails')),
                ),
            ],
          ),
        ),
      ],
    );
    if (widget.embedded) return controls;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12.r),
      elevation: 2,
      child: controls,
    );
  }
}
