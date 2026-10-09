import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/libretro_locale.dart';
import '../../services/gamepad/gamepad_navigation_manager.dart';
import '../../services/libretro_core_catalog.dart';
import '../../services/libretro_skin_service.dart';
import '../../services/logger_service.dart';
import '../../utils/gamepad_nav.dart';
import '../../widgets/confirm_action_dialog.dart';
import 'libretro_skin_catalog_screen.dart';

/// Controller, D-pad and keyboard navigation of the embedded-console pages.
///
/// The page registers its own [GamepadNavigationManager] layer (after the
/// first frame, like the app's dialogs), so the screen underneath stops
/// reacting while it is shown. Directions move Flutter's focus between the
/// page's buttons and fields, A (or Enter) activates the focused one through
/// its [ActivateIntent], B (or Backspace) goes back. The layer is removed with
/// the page, which reactivates the screen underneath. Each page wraps its
/// Scaffold in [libretroPage].
mixin LibretroPageNavigation<T extends StatefulWidget> on State<T> {
  late final String _navigationLayer = 'libretro_page_${identityHashCode(this)}';
  late final GamepadNavigation _navigation = GamepadNavigation(
    onNavigateUp: () => _moveFocus(TraversalDirection.up),
    onNavigateDown: () => _moveFocus(TraversalDirection.down),
    onNavigateLeft: () => _moveFocus(TraversalDirection.left),
    onNavigateRight: () => _moveFocus(TraversalDirection.right),
    onSelectItem: _activateFocus,
    onBack: () {
      if (mounted) Navigator.of(context).maybePop();
    },
  );
  final FocusNode _pageFocus = FocusNode(debugLabel: 'Libretro page', skipTraversal: true);
  bool _navigationLayerPushed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _navigation.initialize();
      GamepadNavigationManager.pushLayer(
        _navigationLayer,
        onActivate: _navigation.activate,
        onDeactivate: _navigation.deactivate,
      );
      _navigationLayerPushed = true;
    });
  }

  @override
  void dispose() {
    if (_navigationLayerPushed) {
      GamepadNavigationManager.popLayer(_navigationLayer);
      _navigation.dispose();
    }
    _pageFocus.dispose();
    super.dispose();
  }

  /// Wraps the page's Scaffold. The page takes the focus when it opens, and
  /// only its navigation layer answers the arrow keys and Enter (as everywhere
  /// else in NeoStation): Flutter's own directional traversal and Enter
  /// activation are switched off inside the page, so a key never acts twice.
  /// Text fields keep their arrow keys and their Enter (text input).
  Widget libretroPage(Widget child) => Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): DoNothingAndStopPropagationIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): DoNothingAndStopPropagationIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{DirectionalFocusIntent: DoNothingAction()},
          child: Focus(focusNode: _pageFocus, autofocus: true, child: child),
        ),
      );

  /// Stops reacting to the controller while a system sheet (Files picker)
  /// covers the page.
  void pausePageNavigation() {
    if (_navigationLayerPushed) _navigation.deactivate();
  }

  /// Undoes [pausePageNavigation] once the system sheet is closed.
  void resumePageNavigation() {
    if (mounted && _navigationLayerPushed) _navigation.activate();
  }

  /// True when the focus moved; GamepadNavigation then plays its sound and
  /// stops repeating a held direction at the edge of the page.
  bool _moveFocus(TraversalDirection direction) {
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node.context == null) return false;
    // Nothing chosen on the page yet: start on its first control.
    if (node == _pageFocus || (node is FocusScopeNode && node.focusedChild == null)) {
      for (final candidate in _pageFocus.traversalDescendants) {
        if (candidate.context == null) continue;
        FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
          candidate,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
        return true;
      }
      return false;
    }
    return node.focusInDirection(direction);
  }

  void _activateFocus() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return;
    Actions.maybeInvoke<ActivateIntent>(focusContext, const ActivateIntent());
  }
}

/// App bar of the embedded-console pages. Its back button stays out of the
/// focus order: B already goes back, and the D-pad starts on the page's own
/// controls.
AppBar libretroPageAppBar(BuildContext context, String title) => AppBar(
      leading: ModalRoute.of(context)?.impliesAppBarDismissal ?? false
          ? const ExcludeFocus(child: BackButton())
          : null,
      title: Text(title),
    );

/// Outline drawn while a control inside [child] has the focus. Controller and
/// keyboard users see where they are whatever Flutter's highlight mode is;
/// a touch on a button never gives it the focus, so touch users see nothing.
class LibretroFocusRing extends StatefulWidget {
  const LibretroFocusRing({super.key, required this.child, this.radius = 20});

  final Widget child;
  final double radius;

  @override
  State<LibretroFocusRing> createState() => _LibretroFocusRingState();
}

class _LibretroFocusRingState extends State<LibretroFocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (mounted && focused != _focused) setState(() => _focused = focused);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(
            color: _focused ? color : Colors.transparent,
            width: 2,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}

/// Shows the outcome of a skin import (from Files or from the catalog) and
/// runs the replacement confirmation. True when a skin was installed.
Future<bool> showLibretroSkinImportResult(
  BuildContext context,
  LibretroSkinService skins,
  LibretroSkinImportResult? result,
) async {
  if (result == null) return false;
  if (result is LibretroSkinNeedsReplaceConfirmation) {
    if (!context.mounted) {
      await skins.discard(result);
      return false;
    }
    final replace = await ConfirmActionDialog.show(
      context,
      title: LibretroLocale.text(context, 'skinsReplace'),
      body: LibretroLocale.formatContext(context, 'skinsReplaceConfirm', {
        'name': result.existingName,
      }),
      confirmLabel: LibretroLocale.text(context, 'skinsReplace'),
      cancelLabel: LibretroLocale.text(context, 'cancel'),
      icon: Icons.swap_horiz,
      accentColor: Theme.of(context).colorScheme.primary,
    );
    if (!replace) {
      await skins.discard(result);
      return false;
    }
    final replaced = await skins.replace(result);
    if (!context.mounted) return replaced is LibretroSkinImported;
    return showLibretroSkinImportResult(context, skins, replaced);
  }
  if (result is LibretroSkinImported) {
    if (context.mounted) _showSkinImported(context, result.skin);
    return true;
  }
  if (result is LibretroSkinImportFailed) {
    LoggerService.instance.w(
      'Libretro skin import refused: ${result.messageKey} ${result.technicalDetails}',
    );
    if (context.mounted) _showSkinImportFailed(context, result);
  }
  return false;
}

Locale _localeOf(BuildContext context) =>
    Localizations.maybeLocaleOf(context) ?? const Locale('en');

/// Translated import remarks of a skin (native `SKIN_WARN_*` codes); codes
/// without a translation are left out rather than shown raw.
List<String> libretroSkinRemarks(BuildContext context, LibretroInstalledSkin skin) {
  final locale = _localeOf(context);
  return <String>[
    for (final code in skin.warnings)
      if (LibretroLocale.skinErrorKeys.containsKey(code))
        LibretroLocale.skinMessage(locale, code),
  ];
}

/// Translated reason of a refused import. The service reports LibretroLocale
/// keys; a raw native `SKIN_*` code is translated too, and anything unknown
/// falls back to the generic refusal.
String libretroSkinFailureText(BuildContext context, LibretroSkinImportFailed failure) {
  final key = LibretroLocale.skinErrorKeys[failure.messageKey] ?? failure.messageKey;
  final known = LibretroLocale.values['en']!.containsKey(key);
  return LibretroLocale.formatContext(
    context,
    known ? key : LibretroSkinMessages.importFailed,
    failure.parameters,
  );
}

void _showSkinImported(BuildContext context, LibretroInstalledSkin skin) {
  final remarks = libretroSkinRemarks(context, skin);
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      duration: Duration(seconds: remarks.isEmpty ? 4 : 10),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(LibretroLocale.formatContext(context, 'skinsImported', {'name': skin.name})),
          if (remarks.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(LibretroLocale.text(context, 'skinsImportRemarks')),
            for (final remark in remarks) _SnackLine(text: remark),
          ],
        ],
      ),
    ),
  );
}

void _showSkinImportFailed(BuildContext context, LibretroSkinImportFailed failure) {
  final reason = libretroSkinFailureText(context, failure);
  final generic = LibretroLocale.text(context, LibretroSkinMessages.importFailed);
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(generic),
          if (reason != generic) _SnackLine(text: reason),
        ],
      ),
    ),
  );
}

class _SnackLine extends StatelessWidget {
  const _SnackLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2, right: 6),
              child: Icon(Icons.info_outline, size: 14),
            ),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

/// Skins of one embedded console: the current portrait and landscape
/// choices, NeoStation's default skin and the imported skins that support
/// the console, with previews drawn by the native renderer, import from
/// Files or from the Provenance catalog, and deletion.
class LibretroSkinManagerScreen extends StatefulWidget {
  const LibretroSkinManagerScreen({super.key, required this.console, this.service});

  /// Console id (a key of [LibretroCoreCatalog.consoles]).
  final String console;

  /// Skin service; created from NeoStation's directories when null.
  final LibretroSkinService? service;

  @override
  State<LibretroSkinManagerScreen> createState() => _LibretroSkinManagerScreenState();
}

class _LibretroSkinManagerScreenState extends State<LibretroSkinManagerScreen>
    with LibretroPageNavigation<LibretroSkinManagerScreen> {
  static final _log = LoggerService.instance;

  /// Previews already drawn in this run, shared by every manager page and
  /// kept in insertion order (a map literal), so the oldest goes first.
  static final Map<String, Future<Uint8List?>> _previews = <String, Future<Uint8List?>>{};
  static const int _previewCacheSize = 64;

  /// Previews the renderer could not draw: not asked for again while this
  /// page is open, asked for again on the next visit.
  final Map<String, Future<Uint8List?>> _missingPreviews = <String, Future<Uint8List?>>{};

  LibretroSkinService? _skins;
  List<LibretroInstalledSkin> _installed = const <LibretroInstalledSkin>[];
  Map<String, String?> _selected = const <String, String?>{};
  bool _loading = true;
  bool _busy = false;

  String _t(String key) => LibretroLocale.text(context, key);
  String _f(String key, Map<String, Object?> values) =>
      LibretroLocale.formatContext(context, key, values);

  String get _consoleName => LibretroCoreCatalog.consoles[widget.console]?.name ?? widget.console;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      _skins = widget.service ?? await LibretroSkinService.create();
    } catch (error) {
      _log.w('Libretro skin manager unavailable: $error');
    }
    await _reload();
  }

  Future<void> _reload() async {
    final skins = _skins;
    var installed = const <LibretroInstalledSkin>[];
    var selected = const <String, String?>{};
    if (skins != null) {
      try {
        installed = await skins.installedSkins(console: widget.console);
      } catch (error) {
        _log.w('Libretro installed skins unreadable: $error');
      }
      try {
        selected = await skins.selectedSkins(widget.console);
      } catch (error) {
        _log.w('Libretro skin selections unreadable for ${widget.console}: $error');
      }
    }
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _selected = selected;
      _loading = false;
    });
  }

  Future<void> _run(Future<void> Function(LibretroSkinService skins) action) async {
    final skins = _skins;
    if (skins == null || _busy) return;
    setState(() => _busy = true);
    try {
      await action(skins);
    } catch (error) {
      _log.w('Libretro skin action failed for ${widget.console}: $error');
    }
    await _reload();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _use(LibretroInstalledSkin? skin, List<String> orientations) => _run((skins) async {
        for (final orientation in orientations) {
          final stored = skin == null
              ? await skins.resetToDefault(console: widget.console, orientation: orientation)
              : await skins.select(console: widget.console, orientation: orientation, skinId: skin.id);
          if (!stored) _log.w('Libretro skin choice refused: ${skin?.id} $orientation');
        }
      });

  Future<void> _delete(LibretroInstalledSkin skin) async {
    if (_skins == null || _busy) return;
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: _t('skinsDelete'),
      body: _f('skinsDeleteConfirm', {'name': skin.name}),
      confirmLabel: _t('skinsDelete'),
      cancelLabel: _t('cancel'),
      icon: Icons.delete_outline,
    );
    if (!confirmed || !mounted) return;
    await _run((skins) async {
      await skins.delete(skin.id);
      _previews.removeWhere((key, _) => key.startsWith('${skin.directory}|'));
    });
  }

  Future<void> _importFromFiles() async {
    final skins = _skins;
    if (skins == null || _busy) return;
    setState(() => _busy = true);
    LibretroSkinImportResult? result;
    pausePageNavigation();
    try {
      result = await skins.pickAndImport();
    } catch (error) {
      result = LibretroSkinImportFailed(LibretroSkinMessages.importFailed, technicalDetails: '$error');
    } finally {
      resumePageNavigation();
    }
    if (mounted) {
      await showLibretroSkinImportResult(context, skins, result);
    } else if (result is LibretroSkinNeedsReplaceConfirmation) {
      await skins.discard(result);
    }
    await _reload();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _browseCatalog() async {
    final skins = _skins;
    if (skins == null || _busy) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LibretroSkinCatalogScreen(console: widget.console, skins: skins),
      ),
    );
    await _reload();
  }

  Future<Uint8List?> _preview(LibretroInstalledSkin? skin, String orientation, Size view, double scale) {
    final skins = _skins;
    if (skins == null) return Future<Uint8List?>.value();
    final key = '${skin?.directory ?? LibretroSkinService.defaultSkinId}|${widget.console}|$orientation|'
        '${view.width.round()}x${view.height.round()}@${scale.toStringAsFixed(2)}';
    final cached = _previews[key] ?? _missingPreviews[key];
    if (cached != null) return cached;
    final request = skins
        .preview(
          skin: skin,
          console: widget.console,
          orientation: orientation,
          width: view.width,
          height: view.height,
          scale: scale,
        )
        .then((image) {
      if (image == null) {
        _previews.remove(key);
        _missingPreviews[key] = Future<Uint8List?>.value();
      }
      return image;
    });
    _previews[key] = request;
    while (_previews.length > _previewCacheSize) {
      _previews.remove(_previews.keys.first);
    }
    return request;
  }

  String _skinName(String? id) {
    if (id == null || id == LibretroSkinService.defaultSkinId) return _t('skinDefaultName');
    for (final skin in _installed) {
      if (skin.id == id) return skin.name;
    }
    // A selection naming a skin that is no longer installed: the native
    // session draws the default skin instead.
    return _t('skinDefaultName');
  }

  bool _isSelected(LibretroInstalledSkin? skin, String orientation) {
    final id = _selected[orientation];
    if (skin == null) {
      return id == null ||
          id == LibretroSkinService.defaultSkinId ||
          !_installed.any((installed) => installed.id == id);
    }
    return id == skin.id;
  }

  @override
  Widget build(BuildContext context) {
    return libretroPage(Scaffold(
      appBar: libretroPageAppBar(context, _f('skinsTitle', {'console': _consoleName})),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  // Every card is built (no lazy list), so the D-pad can
                  // always reach the next one.
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_busy) const LinearProgressIndicator(),
                        _buildSelections(context),
                        const SizedBox(height: 12),
                        _buildHeaderActions(),
                        const SizedBox(height: 12),
                        _buildSkinCard(context, null),
                        if (_installed.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                            child: Text(
                              _t('skinsInstalled'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          for (final skin in _installed) _buildSkinCard(context, skin),
                        ],
                        const SizedBox(height: 16),
                        _footer(context, _t('skinFallbackFooter')),
                        const SizedBox(height: 8),
                        _footer(context, _t('skinsLicenseNotice')),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    ));
  }

  Widget _footer(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }

  Widget _buildSelections(BuildContext context) {
    final theme = Theme.of(context);
    Widget line(IconData icon, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: theme.textTheme.bodyLarge)),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            line(
              Icons.stay_current_portrait,
              _f('skinsSelectedPortrait', {'name': _skinName(_selected[LibretroSkinService.portrait])}),
            ),
            line(
              Icons.stay_current_landscape,
              _f('skinsSelectedLandscape', {'name': _skinName(_selected[LibretroSkinService.landscape])}),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderActions() {
    final enabled = _skins != null && !_busy;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        LibretroFocusRing(
          child: FilledButton.icon(
            onPressed: enabled ? _importFromFiles : null,
            icon: const Icon(Icons.file_upload_outlined),
            label: Text(_t('skinsImportFromFiles')),
          ),
        ),
        LibretroFocusRing(
          child: OutlinedButton.icon(
            onPressed: enabled ? _browseCatalog : null,
            icon: const Icon(Icons.travel_explore),
            label: Text(_t('skinsBrowseCatalog')),
          ),
        ),
      ],
    );
  }

  Widget _buildSkinCard(BuildContext context, LibretroInstalledSkin? skin) {
    final theme = Theme.of(context);
    final iPad = MediaQuery.sizeOf(context).shortestSide >= 600;
    final portrait = skin?.supports(LibretroSkinService.portrait, iPad: iPad) ?? true;
    final landscape = skin?.supports(LibretroSkinService.landscape, iPad: iPad) ?? true;
    final remarks = skin == null ? const <String>[] : libretroSkinRemarks(context, skin);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final enabled = _skins != null && !_busy;

    final orientationLabel = portrait && landscape
        ? _t('skinBothOrientations')
        : portrait
            ? _t('skinPortraitOnly')
            : landscape
                ? _t('skinLandscapeOnly')
                : null;

    final details = <Widget>[
      Text(skin?.name ?? _t('skinDefaultName'), style: theme.textTheme.titleMedium),
      if (skin != null) ...[
        const SizedBox(height: 4),
        Text(
          _f('skinsCredits', {
            'author': skin.author ?? _t('skinsAuthorUnknown'),
            'source': skin.source == LibretroSkinService.sourceFile ? _t('skinsSourceFiles') : skin.source,
          }),
          style: muted,
        ),
        if (skin.license != null) Text(_f('skinsLicense', {'license': skin.license}), style: muted),
        Text(
          _f('skinsForConsoles', {
            'consoles': skin.consoles.map((id) => LibretroCoreCatalog.consoles[id]?.name ?? id).join(', '),
          }),
          style: muted,
        ),
      ],
      if (orientationLabel != null) Text(orientationLabel, style: muted),
      for (final remark in remarks)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1, right: 6),
                child: Icon(Icons.info_outline, size: 16, color: theme.colorScheme.tertiary),
              ),
              Expanded(child: Text(remark, style: theme.textTheme.bodySmall)),
            ],
          ),
        ),
    ];

    final badges = <Widget>[
      if (_isSelected(skin, LibretroSkinService.portrait))
        _badge(context, Icons.stay_current_portrait, _t('orientationPortrait')),
      if (_isSelected(skin, LibretroSkinService.landscape))
        _badge(context, Icons.stay_current_landscape, _t('orientationLandscape')),
    ];

    final actions = <Widget>[
      LibretroFocusRing(
        child: FilledButton.tonalIcon(
          onPressed: enabled && portrait ? () => _use(skin, const [LibretroSkinService.portrait]) : null,
          icon: const Icon(Icons.stay_current_portrait),
          label: Text(_t('skinsUseForPortrait')),
        ),
      ),
      LibretroFocusRing(
        child: FilledButton.tonalIcon(
          onPressed: enabled && landscape ? () => _use(skin, const [LibretroSkinService.landscape]) : null,
          icon: const Icon(Icons.stay_current_landscape),
          label: Text(_t('skinsUseForLandscape')),
        ),
      ),
      if (skin != null)
        LibretroFocusRing(
          child: FilledButton.tonalIcon(
            onPressed: enabled && portrait && landscape
                ? () => _use(skin, LibretroSkinService.orientationNames)
                : null,
            icon: const Icon(Icons.screen_rotation),
            label: Text(_t('skinsUseBoth')),
          ),
        )
      else
        LibretroFocusRing(
          child: FilledButton.tonalIcon(
            onPressed: enabled ? () => _use(null, LibretroSkinService.orientationNames) : null,
            icon: const Icon(Icons.restart_alt),
            label: Text(_t('skinsResetDefault')),
          ),
        ),
      if (skin != null)
        LibretroFocusRing(
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
            onPressed: enabled ? () => _delete(skin) : null,
            icon: const Icon(Icons.delete_outline),
            label: Text(_t('skinsDelete')),
          ),
        ),
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: details),
                ),
                if (badges.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: badges),
                ],
              ],
            ),
            const SizedBox(height: 12),
            _buildPreviews(context, skin, portrait: portrait, landscape: landscape),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ),
      ),
    );
  }

  Widget _badge(BuildContext context, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check, size: 14, color: scheme.onPrimaryContainer),
          const SizedBox(width: 2),
          Icon(icon, size: 14, color: scheme.onPrimaryContainer),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 12)),
        ],
      ),
    );
  }

  /// Portrait and landscape thumbnails, drawn natively at the size of this
  /// device's screen (iPhone or iPad) and shown scaled down.
  Widget _buildPreviews(
    BuildContext context,
    LibretroInstalledSkin? skin, {
    required bool portrait,
    required bool landscape,
  }) {
    final media = MediaQuery.of(context);
    final shortest = media.size.shortestSide <= 0 ? 390.0 : media.size.shortestSide;
    final longest = media.size.longestSide <= 0 ? 844.0 : media.size.longestSide;
    final ratio = media.devicePixelRatio <= 0 ? 2.0 : media.devicePixelRatio;
    const portraitHeight = 168.0;
    const landscapeHeight = 112.0;
    final portraitBox = Size(portraitHeight * shortest / longest, portraitHeight);
    final landscapeBox = Size(landscapeHeight * longest / shortest, landscapeHeight);

    Widget thumbnail(String orientation, Size box) {
      final view = orientation == LibretroSkinService.portrait ? Size(shortest, longest) : Size(longest, shortest);
      final scale = (box.width * ratio / view.width).clamp(0.1, 3.0).toDouble();
      return _SkinPreview(image: _preview(skin, orientation, view, scale), size: box);
    }

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        if (portrait) thumbnail(LibretroSkinService.portrait, portraitBox),
        if (landscape) thumbnail(LibretroSkinService.landscape, landscapeBox),
      ],
    );
  }
}

class _SkinPreview extends StatelessWidget {
  const _SkinPreview({required this.image, required this.size});

  final Future<Uint8List?> image;
  final Size size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size.width,
      height: size.height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder<Uint8List?>(
        future: image,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          final bytes = snapshot.data;
          if (bytes == null) {
            return Center(child: Icon(Icons.image_not_supported_outlined, color: scheme.onSurfaceVariant));
          }
          return Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) =>
                Center(child: Icon(Icons.image_not_supported_outlined, color: scheme.onSurfaceVariant)),
          );
        },
      ),
    );
  }
}
