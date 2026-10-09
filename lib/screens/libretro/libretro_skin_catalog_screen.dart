import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/libretro_locale.dart';
import '../../services/libretro_skin_catalog_service.dart';
import '../../services/libretro_skin_service.dart';
import '../../services/logger_service.dart';
import 'libretro_skin_manager_screen.dart';

/// Provenance skin catalog for one embedded console: the entries listed for
/// that console, searchable by name or author. Installing an entry downloads
/// its archive and runs the same checks and messages as an import from Files.
class LibretroSkinCatalogScreen extends StatefulWidget {
  const LibretroSkinCatalogScreen({
    super.key,
    required this.console,
    required this.skins,
    this.catalog,
  });

  /// Console id (a key of LibretroCoreCatalog.consoles).
  final String console;
  final LibretroSkinService skins;

  /// Catalog service; created on top of [skins] when null.
  final LibretroSkinCatalogService? catalog;

  @override
  State<LibretroSkinCatalogScreen> createState() => _LibretroSkinCatalogScreenState();
}

class _LibretroSkinCatalogScreenState extends State<LibretroSkinCatalogScreen>
    with LibretroPageNavigation<LibretroSkinCatalogScreen> {
  static final _log = LoggerService.instance;

  late final LibretroSkinCatalogService _catalog =
      widget.catalog ?? LibretroSkinCatalogService(cacheDirectory: widget.skins.cacheDirectory, skins: widget.skins);
  final TextEditingController _search = TextEditingController();

  List<LibretroSkinCatalogEntry> _entries = const <LibretroSkinCatalogEntry>[];
  final Set<String> _installed = <String>{};
  bool _loading = true;
  bool _failed = false;
  String _query = '';
  String? _installing;

  String _t(String key) => LibretroLocale.text(context, key);
  String _f(String key, Map<String, Object?> values) =>
      LibretroLocale.formatContext(context, key, values);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (widget.catalog == null) _catalog.dispose();
    _search.dispose();
    super.dispose();
  }

  void _retry() {
    setState(() {
      _loading = true;
      _failed = false;
    });
    unawaited(_load(refresh: true));
  }

  Future<void> _load({bool refresh = false}) async {
    List<LibretroSkinCatalogEntry>? entries;
    try {
      entries = await _catalog.load(refresh: refresh);
    } catch (error) {
      _log.w('Libretro skin catalog failed: $error');
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = entries == null;
      _entries = entries == null
          ? const <LibretroSkinCatalogEntry>[]
          : LibretroSkinCatalogService.forConsole(entries, widget.console);
    });
  }

  Future<void> _install(LibretroSkinCatalogEntry entry) async {
    if (_installing != null) return;
    final skins = widget.skins;
    setState(() => _installing = entry.id);
    LibretroSkinImportResult result;
    try {
      result = await _catalog.download(entry);
    } catch (error) {
      result = LibretroSkinImportFailed(LibretroSkinMessages.download, technicalDetails: '$error');
    }
    if (!mounted) {
      if (result is LibretroSkinNeedsReplaceConfirmation) await skins.discard(result);
      return;
    }
    final installed = await showLibretroSkinImportResult(context, skins, result);
    if (!mounted) return;
    setState(() {
      if (installed) _installed.add(entry.id);
      _installing = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = LibretroSkinCatalogService.search(_entries, _query);
    return libretroPage(Scaffold(
      appBar: libretroPageAppBar(context, _t('catalogTitle')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: LibretroFocusRing(
                    radius: 8,
                    child: TextField(
                      controller: _search,
                      enabled: !_loading && !_failed,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        labelText: _t('catalogSearch'),
                        prefixIcon: const Icon(Icons.search),
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                  ),
                ),
                Expanded(child: _buildBody(context, shown)),
              ],
            ),
          ),
        ),
      ),
    ));
  }

  Widget _buildBody(BuildContext context, List<LibretroSkinCatalogEntry> shown) {
    final theme = Theme.of(context);
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(_t('catalogLoading')),
          ],
        ),
      );
    }
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 40, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(_t('catalogFailed'), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              LibretroFocusRing(
                child: FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: Text(_t('catalogRetry')),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (shown.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_t('catalogEmpty'), textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: shown.length,
      itemBuilder: (context, index) => _buildEntry(context, shown[index]),
    );
  }

  Widget _buildEntry(BuildContext context, LibretroSkinCatalogEntry entry) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final direct = entry.isDirectDownload;
    final installing = _installing == entry.id;
    final installed = _installed.contains(entry.id);
    final downloads = entry.downloadCount;

    final Widget button;
    if (installing) {
      button = FilledButton.tonal(
        onPressed: null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Flexible(child: Text(_t('catalogInstalling'))),
          ],
        ),
      );
    } else {
      button = LibretroFocusRing(
        child: FilledButton.tonalIcon(
          onPressed: direct && _installing == null ? () => _install(entry) : null,
          icon: Icon(installed ? Icons.check : Icons.download),
          label: Text(_t('catalogInstall')),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Thumbnail(url: entry.thumbnailURL),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.name, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(entry.author ?? _t('skinsAuthorUnknown'), style: muted),
                  if (downloads != null) Text(_f('catalogDownloads', {'count': downloads}), style: muted),
                  if (!direct)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _t('catalogNotDirect'),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                  const SizedBox(height: 8),
                  button,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Catalog thumbnail: only https images, a neutral placeholder otherwise or
/// when the image cannot be loaded.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url});

  final String? url;

  static const double _size = 76;

  Uri? get _uri {
    final raw = url;
    if (raw == null) return null;
    final uri = Uri.tryParse(raw.trim().replaceAll(' ', '%20').replaceAll('#', '%23'));
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty ? uri : null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Center(child: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant));
    final uri = _uri;
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: uri == null
          ? placeholder
          : Image.network(
              uri.toString(),
              fit: BoxFit.cover,
              cacheWidth: (_size * MediaQuery.devicePixelRatioOf(context)).round(),
              errorBuilder: (context, error, stackTrace) => placeholder,
            ),
    );
  }
}
