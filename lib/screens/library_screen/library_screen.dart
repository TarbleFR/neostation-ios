import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/library_addon_service.dart';
import 'package:neostation/services/library_aidoku_native_service.dart';
import 'package:neostation/services/library_catalog_service.dart';
import 'package:neostation/services/library_download_service.dart';
import 'package:neostation/services/library_mangadex_service.dart';
import 'package:neostation/services/library_metadata_provider_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/widgets/neo_glass.dart';

import 'library_reader_screen.dart';
import 'library_pdf_reader_screen.dart';

/// Native reading Library for iOS.
///
/// The hub keeps provider management, local-library entry and native content in
/// one controller-friendly surface. Provider websites are never embedded.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  static LibraryScreenState? _currentState;

  static bool navigateLeft() => _currentState?._navigateHorizontal(-1) ?? false;
  static bool navigateRight() => _currentState?._navigateHorizontal(1) ?? false;
  static bool navigateUp() => _currentState?._navigateVertical(-1) ?? false;
  static bool navigateDown() => _currentState?._navigateVertical(1) ?? false;
  static void selectCurrent() => _currentState?._activateSelection();
  static void backCurrent() => _currentState?._back();
  static void deleteCurrent() => _currentState?._deleteSelectedAddon();

  @override
  State<LibraryScreen> createState() => LibraryScreenState();
}

enum _LibraryView { hub, addons, local, manage }

enum _HubFocus { shortcuts, filters, books }

class _NativeLibraryEntry {
  const _NativeLibraryEntry({
    required this.providerId,
    required this.item,
    this.source,
  });

  final String providerId;
  final LibraryAddon? source;
  final LibraryCatalogItem item;

  bool get isMangaDex => providerId == LibraryMangaDexService.providerId;
}

class LibraryScreenState extends State<LibraryScreen> {
  final LibraryAddonService _addonService = LibraryAddonService.instance;
  final LibraryAidokuNativeService _aidokuNativeService =
      LibraryAidokuNativeService.instance;
  final LibraryCatalogService _catalogService = LibraryCatalogService.instance;
  final LibraryMangaDexService _mangaDexService =
      LibraryMangaDexService.instance;
  final LibraryMetadataProviderService _metadataProviderService =
      LibraryMetadataProviderService.instance;

  final ScrollController _libraryScrollController = ScrollController();
  final Map<String, GlobalKey> _bookKeys = <String, GlobalKey>{};

  _LibraryView _view = _LibraryView.hub;
  _HubFocus _hubFocus = _HubFocus.shortcuts;

  int _hubSelectedIndex = 0;
  int _filterSelectedIndex = 0;
  int _addonSelectedIndex = 0;
  int _librarySelectedIndex = 0;
  int _libraryColumns = 5;
  double _libraryRowExtent = 220;

  String _languageFilter = 'all';
  String _sourceFilter = 'all';
  bool _sortAscending = true;
  String? _alphabetAnchor;

  bool _loadingAddons = true;
  bool _loadingLibrary = true;
  int _catalogFailures = 0;
  List<LibraryAddon> _addons = const [];
  List<_NativeLibraryEntry> _libraryItems = const [];
  List<_NativeLibraryEntry> _remoteSearchEntries = const [];
  final Map<String, int> _aidokuNextPage = <String, int>{};
  final Set<String> _aidokuExhausted = <String>{};
  final Set<String> _aidokuLoading = <String>{};
  int _aidokuRoundRobinCursor = 0;
  String _titleQuery = '';
  final TextEditingController _titleSearchController = TextEditingController();
  final FocusNode _titleSearchFocusNode = FocusNode(
    debugLabel: 'library_inline_title_search',
  );
  Timer? _titleSearchDebounce;
  bool _titleSearchMode = false;
  bool _titleSearchFiltersExpanded = false;
  bool _hideAdultContent = true;
  bool _searchingTitles = false;
  int _searchGeneration = 0;

  bool get _loadingMoreCatalogs => _aidokuLoading.isNotEmpty;

  int get _addonSelectionCount => 3 + _addons.length;

  String _entryIdentity(_NativeLibraryEntry entry) =>
      '${entry.providerId}|${entry.item.id}';

  List<_NativeLibraryEntry> get _visibleLibraryItems {
    final query = _titleQuery.trim().toLowerCase();
    final seen = <String>{};
    final items = <_NativeLibraryEntry>[];
    for (final entry in <_NativeLibraryEntry>[
      ..._libraryItems,
      ..._remoteSearchEntries,
    ]) {
      if (!seen.add(_entryIdentity(entry))) continue;
      if (query.isNotEmpty && !entry.item.title.toLowerCase().contains(query)) {
        continue;
      }
      if (_hideAdultContent && _isAdultOrDoujinshi(entry)) {
        continue;
      }
      if (_languageFilter != 'all' &&
          !_itemLanguageCodes(entry).contains(_languageFilter)) {
        continue;
      }
      if (_sourceFilter != 'all' && entry.providerId != _sourceFilter) {
        continue;
      }
      items.add(entry);
    }
    items.sort((a, b) {
      final comparison = a.item.title.toLowerCase().compareTo(
        b.item.title.toLowerCase(),
      );
      return _sortAscending ? comparison : -comparison;
    });
    return items;
  }

  List<String> get _languageOptions {
    final languages = <String>{};
    for (final entry in _libraryItems) {
      languages.addAll(_itemLanguageCodes(entry));
    }
    final sorted = languages.toList()..sort();
    final preferred = <String>['fr', 'en'];
    sorted.sort((a, b) {
      final ai = preferred.indexOf(a);
      final bi = preferred.indexOf(b);
      if (ai >= 0 || bi >= 0) {
        if (ai < 0) return 1;
        if (bi < 0) return -1;
        return ai.compareTo(bi);
      }
      return a.compareTo(b);
    });
    return <String>['all', ...sorted];
  }

  Map<String, String> get _sourceOptions {
    final options = <String, String>{
      'all': 'all',
      LibraryMangaDexService.providerId: 'MangaDex',
      ..._metadataProviderService.providerLabels,
    };
    for (final addon in _addons) {
      if (addon.isAidokuRepositorySource &&
          _aidokuNativeService.supports(addon)) {
        options[addon.id] = addon.name;
      } else if (addon.canBrowseOnIos) {
        options[addon.id] = addon.name;
      }
    }
    for (final entry in _libraryItems) {
      final label = entry.isMangaDex
          ? 'MangaDex'
          : (_metadataProviderService.labelFor(entry.providerId) ??
                (entry.source?.name.trim().isNotEmpty == true
                    ? entry.source!.name.trim()
                    : entry.providerId));
      options[entry.providerId] = label;
    }
    final pairs = options.entries.where((entry) => entry.key != 'all').toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return <String, String>{
      'all': 'all',
      for (final entry in pairs) entry.key: entry.value,
    };
  }

  String _sourceLabel(String id) {
    if (id == 'all') {
      return Localizations.localeOf(context).languageCode == 'fr'
          ? 'Toutes les sources'
          : 'All sources';
    }
    return _sourceOptions[id] ?? id;
  }

  @override
  void initState() {
    super.initState();
    LibraryScreen._currentState = this;
    _libraryScrollController.addListener(_onLibraryScroll);
    _titleSearchController.text = _titleQuery;
    _loadAddons();
  }

  @override
  void dispose() {
    if (identical(LibraryScreen._currentState, this)) {
      LibraryScreen._currentState = null;
    }
    _libraryScrollController.removeListener(_onLibraryScroll);
    _libraryScrollController.dispose();
    _titleSearchDebounce?.cancel();
    _titleSearchController.dispose();
    _titleSearchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadAddons() async {
    try {
      await _metadataProviderService.initialize();
    } catch (_) {
      // The native Library remains usable even if the bundled provider registry
      // cannot be loaded for some reason.
    }
    final addons = await _addonService.load();
    if (!mounted) return;
    setState(() {
      _addons = addons;
      _loadingAddons = false;
      if (_addonSelectedIndex >= _addonSelectionCount) {
        _addonSelectedIndex = (_addonSelectionCount - 1).clamp(0, 9999).toInt();
      }
    });
    await _refreshNativeLibrary(addons);
  }

  Future<void> _refreshNativeLibrary([List<LibraryAddon>? installed]) async {
    final addons = installed ?? _addons;
    if (mounted) {
      setState(() {
        _loadingLibrary = true;
        _catalogFailures = 0;
        _remoteSearchEntries = const [];
        _aidokuNextPage.clear();
        _aidokuExhausted.clear();
        _aidokuLoading.clear();
      });
    }

    final entries = <_NativeLibraryEntry>[];
    var failures = 0;

    try {
      final nativeItems = await _mangaDexService.loadPopular();
      for (final item in nativeItems) {
        entries.add(
          _NativeLibraryEntry(
            providerId: LibraryMangaDexService.providerId,
            item: item,
          ),
        );
      }
    } catch (_) {
      failures++;
    }

    final aidokuAddons = addons
        .where(
          (addon) =>
              addon.isAidokuRepositorySource &&
              _aidokuNativeService.supports(addon),
        )
        .toList();
    const initialCatalogConcurrency = 3;
    for (
      var offset = 0;
      offset < aidokuAddons.length;
      offset += initialCatalogConcurrency
    ) {
      final batch = aidokuAddons
          .skip(offset)
          .take(initialCatalogConcurrency)
          .toList();
      final results = await Future.wait(
        batch.map((addon) async {
          try {
            final page = await _aidokuNativeService.loadCatalogPage(
              addon,
              page: 1,
            );
            return MapEntry<LibraryAddon, LibraryAidokuCatalogPage?>(
              addon,
              page,
            );
          } catch (_) {
            return MapEntry<LibraryAddon, LibraryAidokuCatalogPage?>(
              addon,
              null,
            );
          }
        }),
      );
      for (final result in results) {
        final addon = result.key;
        final page = result.value;
        if (page == null) {
          failures++;
          _aidokuExhausted.add(addon.id);
          continue;
        }
        for (final item in page.items) {
          entries.add(
            _NativeLibraryEntry(
              providerId: addon.id,
              source: addon,
              item: item,
            ),
          );
        }
        _aidokuNextPage[addon.id] = 2;
        if (!page.hasMore || page.items.isEmpty) {
          _aidokuExhausted.add(addon.id);
        }
      }
    }

    for (final addon in addons) {
      if (addon.isAidokuRepositorySource &&
          _aidokuNativeService.supports(addon)) {
        continue;
      }
      if (!addon.canBrowseOnIos) continue;
      try {
        final items = await _catalogService.loadCatalog(addon);
        for (final item in items) {
          entries.add(
            _NativeLibraryEntry(
              providerId: addon.id,
              source: addon,
              item: item,
            ),
          );
        }
      } catch (_) {
        failures++;
      }
    }

    if (!mounted) return;
    setState(() {
      _libraryItems = List<_NativeLibraryEntry>.unmodifiable(entries);
      _catalogFailures = failures;
      _loadingLibrary = false;
      _alphabetAnchor = null;
      if (_sourceFilter != 'all' &&
          !_sourceOptions.containsKey(_sourceFilter)) {
        _sourceFilter = 'all';
      }
      final visible = _visibleLibraryItems;
      if (visible.isEmpty) {
        _librarySelectedIndex = 0;
        if (_hubFocus == _HubFocus.books) _hubFocus = _HubFocus.filters;
      } else if (_librarySelectedIndex >= visible.length) {
        _librarySelectedIndex = visible.length - 1;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onLibraryScroll();
    });
    if (_titleQuery.trim().isNotEmpty) {
      unawaited(_runTitleSearch(_titleQuery));
    }
  }

  void _onLibraryScroll() {
    if (!mounted ||
        _loadingLibrary ||
        _titleQuery.trim().isNotEmpty ||
        !_libraryScrollController.hasClients) {
      return;
    }
    final position = _libraryScrollController.position;
    final threshold = position.viewportDimension * 2.2;
    if (position.extentAfter <= (threshold < 900 ? 900 : threshold)) {
      unawaited(_loadMoreAidokuCatalogs());
    }
  }

  Future<void> _loadMoreAidokuCatalogs({String? preferredSourceId}) async {
    if (!mounted || _loadingLibrary || _titleQuery.trim().isNotEmpty) return;
    final capacity = 2 - _aidokuLoading.length;
    if (capacity <= 0) return;

    var candidates = _addons.where((addon) {
      return addon.isAidokuRepositorySource &&
          _aidokuNativeService.supports(addon) &&
          !_aidokuExhausted.contains(addon.id) &&
          !_aidokuLoading.contains(addon.id);
    }).toList();
    if (candidates.isEmpty) return;

    final preferred =
        preferredSourceId ?? (_sourceFilter == 'all' ? null : _sourceFilter);
    if (preferred != null) {
      final matching = candidates
          .where((addon) => addon.id == preferred)
          .toList();
      if (matching.isNotEmpty) candidates = matching;
    } else if (candidates.length > 1) {
      final offset = _aidokuRoundRobinCursor % candidates.length;
      candidates = <LibraryAddon>[
        ...candidates.skip(offset),
        ...candidates.take(offset),
      ];
      _aidokuRoundRobinCursor =
          (_aidokuRoundRobinCursor + capacity) % candidates.length;
    }

    final selected = candidates.take(capacity).toList();
    if (selected.isEmpty) return;
    setState(() {
      for (final addon in selected) {
        _aidokuLoading.add(addon.id);
      }
    });
    await Future.wait(selected.map(_loadAidokuPage));
  }

  Future<void> _loadAidokuPage(LibraryAddon addon) async {
    final pageNumber = _aidokuNextPage[addon.id] ?? 2;
    try {
      final page = await _aidokuNativeService.loadCatalogPage(
        addon,
        page: pageNumber,
      );
      if (!mounted) return;
      final selectedVisible = _visibleLibraryItems;
      final selectedIdentity =
          _librarySelectedIndex >= 0 &&
              _librarySelectedIndex < selectedVisible.length
          ? _entryIdentity(selectedVisible[_librarySelectedIndex])
          : null;
      final existing = _libraryItems.map(_entryIdentity).toSet();
      final additions = <_NativeLibraryEntry>[];
      for (final item in page.items) {
        final entry = _NativeLibraryEntry(
          providerId: addon.id,
          source: addon,
          item: item,
        );
        if (existing.add(_entryIdentity(entry))) additions.add(entry);
      }

      setState(() {
        if (additions.isNotEmpty) {
          _libraryItems = List<_NativeLibraryEntry>.unmodifiable(
            <_NativeLibraryEntry>[..._libraryItems, ...additions],
          );
          _aidokuNextPage[addon.id] = pageNumber + 1;
        }
        if (!page.hasMore || additions.isEmpty) {
          _aidokuExhausted.add(addon.id);
        }
        _aidokuLoading.remove(addon.id);

        if (selectedIdentity != null) {
          final visible = _visibleLibraryItems;
          final index = visible.indexWhere(
            (entry) => _entryIdentity(entry) == selectedIdentity,
          );
          if (index >= 0) _librarySelectedIndex = index;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onLibraryScroll();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _aidokuLoading.remove(addon.id);
        _aidokuExhausted.add(addon.id);
        _catalogFailures++;
      });
    }
  }

  Future<List<_NativeLibraryEntry>> _searchMetadataProviders(
    String query,
  ) async {
    try {
      await _metadataProviderService.initialize();
      Set<String>? providerIds;
      if (_sourceFilter != 'all') {
        if (!_metadataProviderService.isProviderId(_sourceFilter)) {
          return const <_NativeLibraryEntry>[];
        }
        providerIds = <String>{_sourceFilter};
      }

      final groups = await _metadataProviderService.searchAll(
        query,
        providerIds: providerIds,
      );
      final entries = <_NativeLibraryEntry>[];
      for (final group in groups.entries) {
        for (final item in group.value) {
          entries.add(_NativeLibraryEntry(providerId: group.key, item: item));
        }
      }
      return entries;
    } catch (_) {
      return const <_NativeLibraryEntry>[];
    }
  }

  Future<void> _runTitleSearch(String rawQuery) async {
    final query = rawQuery.trim();
    final generation = ++_searchGeneration;
    if (!mounted) return;
    setState(() {
      _titleQuery = query;
      _remoteSearchEntries = const [];
      _searchingTitles = query.isNotEmpty;
      _librarySelectedIndex = 0;
      _alphabetAnchor = null;
    });
    if (query.isEmpty) return;

    final futures = <Future<List<_NativeLibraryEntry>>>[
      () async {
        try {
          final items = await _mangaDexService.searchTitles(query);
          return items
              .map(
                (item) => _NativeLibraryEntry(
                  providerId: LibraryMangaDexService.providerId,
                  item: item,
                ),
              )
              .toList();
        } catch (_) {
          return <_NativeLibraryEntry>[];
        }
      }(),
      _searchMetadataProviders(query),
      for (final addon in _addons.where(
        (addon) =>
            addon.isAidokuRepositorySource &&
            _aidokuNativeService.supports(addon),
      ))
        () async {
          try {
            final page = await _aidokuNativeService.loadCatalogPage(
              addon,
              page: 1,
              query: query,
            );
            return page.items
                .map(
                  (item) => _NativeLibraryEntry(
                    providerId: addon.id,
                    source: addon,
                    item: item,
                  ),
                )
                .toList();
          } catch (_) {
            return <_NativeLibraryEntry>[];
          }
        }(),
    ];

    final groups = await Future.wait(futures);
    if (!mounted || generation != _searchGeneration || _titleQuery != query)
      return;
    final seen = <String>{};
    final results = <_NativeLibraryEntry>[];
    for (final group in groups) {
      for (final entry in group) {
        if (seen.add(_entryIdentity(entry))) results.add(entry);
      }
    }
    setState(() {
      _remoteSearchEntries = List<_NativeLibraryEntry>.unmodifiable(results);
      _searchingTitles = false;
      final visible = _visibleLibraryItems;
      _librarySelectedIndex = visible.isEmpty ? 0 : 0;
    });
  }

  bool _isAdultOrDoujinshi(_NativeLibraryEntry entry) {
    bool explicitFlag(dynamic value) {
      if (value == true) return true;
      if (value is num) return value > 0;
      final raw = value?.toString().trim().toLowerCase() ?? '';
      if (raw.isEmpty) return false;
      if (raw == 'true' ||
          raw == 'yes' ||
          raw == '1' ||
          raw == '2' ||
          raw == '3') {
        return true;
      }
      return _strictAdultPattern.hasMatch(raw);
    }

    final provider = entry.source?.manifest['provider'];
    if (provider is Map) {
      // Repository/source metadata has priority. A source that declares any
      // non-zero NSFW level is excluded as a whole in strict safe mode.
      for (final key in const [
        'nsfw',
        'adult',
        'explicit',
        'isAdult',
        'contentWarning',
        'contentRating',
        'rating',
        'ageRating',
      ]) {
        if (explicitFlag(provider[key])) return true;
      }
    }

    final raw = entry.item.raw;
    for (final key in const [
      'explicitContent',
      'nsfw',
      'adult',
      'isAdult',
      'contentWarning',
      'contentRating',
      'rating',
      'ageRating',
      'genres',
      'genre',
      'categories',
      'tags',
      'labels',
    ]) {
      final value = raw[key];
      if (value is bool || value is num) {
        if (explicitFlag(value)) return true;
      } else if (value != null &&
          _strictAdultPattern.hasMatch(value.toString())) {
        return true;
      }
    }

    String metadata = <String>[
      entry.item.title,
      entry.item.subtitle,
      entry.item.description,
      entry.item.coverUrl ?? '',
      entry.source?.name ?? '',
      entry.source?.description ?? '',
    ].join(' ').toLowerCase();
    try {
      metadata = '$metadata ${jsonEncode(raw).toLowerCase()}';
      if (provider is Map) {
        metadata = '$metadata ${jsonEncode(provider).toLowerCase()}';
      }
    } catch (_) {}

    return _strictAdultPattern.hasMatch(metadata);
  }

  static final RegExp _strictAdultPattern = RegExp(
    r'(^|[^a-z0-9])(hentai|doujinshi|doujin|porn|porno|pornographic|pornography|xxx|nsfw|r[ -]?18|18\+|18 plus|adult(?:s)?(?:[ -]?only|[ -]?content)?|mature(?:[ -]?content)?|explicit(?:[ -]?content)?|uncensored|smut|erotic|erotica|ecchi|sexual(?:[ -]?content)?|sex|hardcore|fetish|bdsm|ahegao|futanari|lolicon|shotacon|oppai|netorare|ntr|incest|rape|non[ -]?consensual|tentacle|milf|nudity|nude)([^a-z0-9]|$)',
    caseSensitive: false,
  );

  String _contentFilterLabel() {
    final fr = Localizations.localeOf(context).languageCode == 'fr';
    if (_hideAdultContent) {
      return fr ? 'Sans Hentai/Doujinshi' : 'Hide Hentai/Doujinshi';
    }
    return fr ? 'Tout afficher' : 'Show all';
  }

  Set<String> _itemLanguageCodes(_NativeLibraryEntry entry) {
    final result = <String>{};

    void addLanguage(dynamic value) {
      if (value == null) return;
      if (value is Iterable) {
        for (final item in value) {
          addLanguage(item);
        }
        return;
      }
      final raw = value.toString().trim().toLowerCase();
      if (raw.isEmpty || raw == 'null') return;
      final normalized = raw.replaceAll('_', '-').split('-').first;
      if (RegExp(r'^[a-z]{2,3}$').hasMatch(normalized)) {
        result.add(normalized);
      }
    }

    final raw = entry.item.raw;
    addLanguage(raw['language']);
    addLanguage(raw['languages']);
    addLanguage(raw['lang']);

    final attributes = raw['attributes'];
    if (attributes is Map) {
      addLanguage(attributes['availableTranslatedLanguages']);
      addLanguage(attributes['translatedLanguage']);
      addLanguage(attributes['originalLanguage']);
      final titles = attributes['title'];
      if (titles is Map) addLanguage(titles.keys);
      final descriptions = attributes['description'];
      if (descriptions is Map) addLanguage(descriptions.keys);
    }

    // Gallica's public-domain OPDS feed is primarily French. Keep its books
    // filterable even when an individual Atom entry omits dc:language.
    if (result.isEmpty && entry.source?.isGallicaSource == true) {
      result.add('fr');
    }

    return result;
  }

  String _languageLabel(String code) {
    if (code == 'all') {
      return Localizations.localeOf(context).languageCode == 'fr'
          ? 'Toutes'
          : 'All';
    }
    const labels = <String, String>{
      'fr': 'Français',
      'en': 'English',
      'es': 'Español',
      'de': 'Deutsch',
      'it': 'Italiano',
      'pt': 'Português',
      'ja': '日本語',
      'ko': '한국어',
      'zh': '中文',
      'ru': 'Русский',
      'id': 'Indonesia',
    };
    return labels[code] ?? code.toUpperCase();
  }

  String _bookKey(_NativeLibraryEntry entry) =>
      '${entry.providerId}|${entry.item.id}|${entry.item.title}';

  GlobalKey _keyForBook(_NativeLibraryEntry entry) =>
      _bookKeys.putIfAbsent(_bookKey(entry), GlobalKey.new);

  void _ensureSelectedBookVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _hubFocus != _HubFocus.books) return;
      final visible = _visibleLibraryItems;
      if (_librarySelectedIndex < 0 ||
          _librarySelectedIndex >= visible.length) {
        return;
      }

      final context = _keyForBook(visible[_librarySelectedIndex])
          .currentContext;
      if (context != null) {
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: 0.22,
        );
        return;
      }

      if (!_libraryScrollController.hasClients) return;
      final row = _librarySelectedIndex ~/ _libraryColumns;
      final top = row * _libraryRowExtent;
      final position = _libraryScrollController.position;
      final viewport = position.viewportDimension;
      final current = position.pixels;
      var target = current;
      if (top < current) {
        target = top;
      } else if (top + _libraryRowExtent > current + viewport) {
        target = top + _libraryRowExtent - viewport;
      }
      target = target.clamp(0.0, position.maxScrollExtent);
      if ((target - current).abs() > 1) {
        _libraryScrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  bool _navigateHorizontal(int delta) {
    if (_view == _LibraryView.addons) {
      if (_addonSelectedIndex > 2) return false;
      final next = (_addonSelectedIndex + delta).clamp(0, 2).toInt();
      if (next == _addonSelectedIndex) return false;
      setState(() => _addonSelectedIndex = next);
      return true;
    }
    if (_view != _LibraryView.hub) return false;

    switch (_hubFocus) {
      case _HubFocus.shortcuts:
        final next = (_hubSelectedIndex + delta).clamp(0, 2).toInt();
        if (next == _hubSelectedIndex) return false;
        setState(() => _hubSelectedIndex = next);
        return true;
      case _HubFocus.filters:
        final next = (_filterSelectedIndex + delta).clamp(0, 5).toInt();
        if (next == _filterSelectedIndex) return false;
        setState(() => _filterSelectedIndex = next);
        return true;
      case _HubFocus.books:
        final visible = _visibleLibraryItems;
        if (visible.isEmpty) return false;
        final next = (_librarySelectedIndex + delta)
            .clamp(0, visible.length - 1)
            .toInt();
        if (next == _librarySelectedIndex) return false;
        setState(() => _librarySelectedIndex = next);
        _ensureSelectedBookVisible();
        return true;
    }
  }

  bool _navigateVertical(int delta) {
    if (_view == _LibraryView.manage) {
      if (_addons.isEmpty) return false;
      final next = (_addonSelectedIndex + delta)
          .clamp(0, _addons.length - 1)
          .toInt();
      if (next == _addonSelectedIndex) return false;
      setState(() => _addonSelectedIndex = next);
      return true;
    }

    if (_view == _LibraryView.addons) {
      if (_addonSelectionCount <= 0) return false;
      final next = (_addonSelectedIndex + delta)
          .clamp(0, _addonSelectionCount - 1)
          .toInt();
      if (next == _addonSelectedIndex) return false;
      setState(() => _addonSelectedIndex = next);
      return true;
    }
    if (_view != _LibraryView.hub) return false;

    final visible = _visibleLibraryItems;
    switch (_hubFocus) {
      case _HubFocus.shortcuts:
        if (delta <= 0 || _loadingLibrary) return false;
        setState(() => _hubFocus = _HubFocus.filters);
        return true;
      case _HubFocus.filters:
        if (delta < 0) {
          setState(() => _hubFocus = _HubFocus.shortcuts);
          return true;
        }
        if (visible.isEmpty) return false;
        setState(() {
          _hubFocus = _HubFocus.books;
          _librarySelectedIndex = _librarySelectedIndex
              .clamp(0, visible.length - 1)
              .toInt();
        });
        _ensureSelectedBookVisible();
        return true;
      case _HubFocus.books:
        if (visible.isEmpty) return false;
        final next = _librarySelectedIndex + (delta * _libraryColumns);
        if (delta < 0 && next < 0) {
          setState(() => _hubFocus = _HubFocus.filters);
          return true;
        }
        final clamped = next.clamp(0, visible.length - 1).toInt();
        if (clamped == _librarySelectedIndex) return false;
        setState(() => _librarySelectedIndex = clamped);
        _ensureSelectedBookVisible();
        return true;
    }
  }

  void _activateSelection() {
    if (_view == _LibraryView.hub) {
      if (_hubFocus == _HubFocus.shortcuts) {
        if (_hubSelectedIndex == 0) {
          setState(() {
            _view = _LibraryView.addons;
            _addonSelectedIndex = 0;
          });
        } else if (_hubSelectedIndex == 1) {
          setState(() => _view = _LibraryView.local);
        } else {
          setState(() {
            _view = _LibraryView.manage;
            _addonSelectedIndex = 0;
          });
        }
        return;
      }

      if (_hubFocus == _HubFocus.filters) {
        if (_filterSelectedIndex == 0) {
          _openLanguageMenu();
        } else if (_filterSelectedIndex == 1) {
          _openSortMenu();
        } else if (_filterSelectedIndex == 2) {
          _openIndexMenu();
        } else if (_filterSelectedIndex == 3) {
          _openSourceMenu();
        } else if (_filterSelectedIndex == 4) {
          _openContentMenu();
        } else {
          _enterTitleSearchMode();
        }
        return;
      }

      final visible = _visibleLibraryItems;
      if (_librarySelectedIndex >= 0 &&
          _librarySelectedIndex < visible.length) {
        _openCatalogItem(visible[_librarySelectedIndex]);
      }
      return;
    }

    if (_view == _LibraryView.local) {
      _backToHub(selectLocal: true);
      return;
    }

    if (_view == _LibraryView.manage) {
      if (_addonSelectedIndex >= 0 && _addonSelectedIndex < _addons.length) {
        _showAddonDetails(_addons[_addonSelectedIndex]);
      }
      return;
    }

    if (_addonSelectedIndex == 0) {
      _backToHub();
    } else if (_addonSelectedIndex == 1) {
      _installFromUrl();
    } else if (_addonSelectedIndex == 2) {
      _installFromLocalManifest();
    } else {
      final addonIndex = _addonSelectedIndex - 3;
      if (addonIndex >= 0 && addonIndex < _addons.length) {
        _showAddonDetails(_addons[addonIndex]);
      }
    }
  }

  void _back() {
    if (_titleSearchMode) {
      if (_titleSearchFocusNode.hasFocus) {
        _titleSearchFocusNode.unfocus();
        unawaited(_dismissSystemKeyboard());
        return;
      }
      setState(() {
        _titleSearchMode = false;
        _titleSearchFiltersExpanded = false;
        _hubFocus = _HubFocus.filters;
        _filterSelectedIndex = 5;
      });
      return;
    }

    if (_view == _LibraryView.addons || _view == _LibraryView.local) {
      _backToHub();
      return;
    }
    if (_view == _LibraryView.manage) {
      _backToHub(selectManage: true);
      return;
    }

    if (_hubFocus == _HubFocus.books) {
      setState(() => _hubFocus = _HubFocus.filters);
    } else if (_hubFocus == _HubFocus.filters) {
      setState(() => _hubFocus = _HubFocus.shortcuts);
    }
  }

  void _backToHub({bool selectLocal = false, bool selectManage = false}) {
    setState(() {
      _view = _LibraryView.hub;
      _hubFocus = _HubFocus.shortcuts;
      _hubSelectedIndex = selectManage ? 2 : (selectLocal ? 1 : 0);
    });
  }

  Future<void> _deleteSelectedAddon() async {
    final int addonIndex;
    if (_view == _LibraryView.addons) {
      if (_addonSelectedIndex < 3) return;
      addonIndex = _addonSelectedIndex - 3;
    } else if (_view == _LibraryView.manage) {
      addonIndex = _addonSelectedIndex;
    } else {
      return;
    }
    if (addonIndex < 0 || addonIndex >= _addons.length) return;
    final addon = _addons[addonIndex];
    if (addon.isBuiltIn) return;
    if (addon.isRepositorySource) {
      await _chooseRemoveSourceOrRepository(addon);
    } else {
      await _confirmRemoveAddon(addon);
    }
  }

  void _cycleLanguageFilter() {
    final options = _languageOptions;
    if (options.isEmpty) return;
    var index = options.indexOf(_languageFilter);
    if (index < 0) index = 0;
    final next = options[(index + 1) % options.length];
    setState(() {
      _languageFilter = next;
      _librarySelectedIndex = 0;
      _alphabetAnchor = null;
    });
  }

  void _toggleAlphabeticalSort() {
    setState(() {
      _sortAscending = !_sortAscending;
      _librarySelectedIndex = 0;
      _alphabetAnchor = null;
    });
  }

  void _jumpToNextLetter() {
    final visible = _visibleLibraryItems;
    if (visible.isEmpty) return;
    final letters =
        visible
            .map((entry) => _firstLetter(entry.item.title))
            .where((letter) => letter.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    if (letters.isEmpty) return;

    final current = _alphabetAnchor;
    final currentIndex = current == null ? -1 : letters.indexOf(current);
    final nextLetter = letters[(currentIndex + 1) % letters.length];
    final itemIndex = visible.indexWhere(
      (entry) => _firstLetter(entry.item.title) == nextLetter,
    );
    if (itemIndex < 0) return;

    setState(() {
      _alphabetAnchor = nextLetter;
      _hubFocus = _HubFocus.books;
      _librarySelectedIndex = itemIndex;
    });
    _ensureSelectedBookVisible();
  }

  String _firstLetter(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return '';
    final first = trimmed.substring(0, 1).toUpperCase();
    return RegExp(r'[A-ZÀ-ÖØ-Þ0-9]').hasMatch(first) ? first : '#';
  }

  RelativeRect _popupPosition() {
    final size = MediaQuery.sizeOf(context);
    final left = 24.r;
    final top = 190.r;
    final right = (size.width - 360.r)
        .clamp(24.0, size.width - 48.0)
        .toDouble();
    return RelativeRect.fromLTRB(left, top, right, 0);
  }

  Future<void> _openLanguageMenu() async {
    final options = _languageOptions;
    if (options.isEmpty) return;
    final selected = await showMenu<String>(
      context: context,
      position: _popupPosition(),
      items: [
        for (final code in options)
          PopupMenuItem<String>(
            value: code,
            child: Row(
              children: [
                SizedBox(
                  width: 28.r,
                  child: code == _languageFilter
                      ? Icon(Symbols.check_rounded, size: 18.r)
                      : null,
                ),
                Text(_languageLabel(code)),
              ],
            ),
          ),
      ],
    );
    if (!mounted || selected == null) return;
    setState(() {
      _languageFilter = selected;
      _librarySelectedIndex = 0;
      _alphabetAnchor = null;
    });
  }

  Future<void> _openSortMenu() async {
    final selected = await showMenu<bool>(
      context: context,
      position: _popupPosition(),
      items: [
        PopupMenuItem<bool>(
          value: true,
          child: Row(
            children: [
              SizedBox(
                width: 28.r,
                child: _sortAscending
                    ? Icon(Symbols.check_rounded, size: 18.r)
                    : null,
              ),
              const Text('A → Z'),
            ],
          ),
        ),
        PopupMenuItem<bool>(
          value: false,
          child: Row(
            children: [
              SizedBox(
                width: 28.r,
                child: !_sortAscending
                    ? Icon(Symbols.check_rounded, size: 18.r)
                    : null,
              ),
              const Text('Z → A'),
            ],
          ),
        ),
      ],
    );
    if (!mounted || selected == null) return;
    setState(() {
      _sortAscending = selected;
      _librarySelectedIndex = 0;
      _alphabetAnchor = null;
    });
  }

  Future<void> _openIndexMenu() async {
    final visible = _visibleLibraryItems;
    if (visible.isEmpty) return;
    final letters =
        visible
            .map((entry) => _firstLetter(entry.item.title))
            .where((letter) => letter.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    if (letters.isEmpty) return;

    final selected = await showMenu<String>(
      context: context,
      position: _popupPosition(),
      items: [
        for (final letter in letters)
          PopupMenuItem<String>(
            value: letter,
            child: Row(
              children: [
                SizedBox(
                  width: 28.r,
                  child: letter == _alphabetAnchor
                      ? Icon(Symbols.check_rounded, size: 18.r)
                      : null,
                ),
                Text(letter),
              ],
            ),
          ),
      ],
    );
    if (!mounted || selected == null) return;
    final itemIndex = visible.indexWhere(
      (entry) => _firstLetter(entry.item.title) == selected,
    );
    if (itemIndex < 0) return;
    setState(() {
      _alphabetAnchor = selected;
      _hubFocus = _HubFocus.books;
      _librarySelectedIndex = itemIndex;
    });
    _ensureSelectedBookVisible();
  }

  Future<void> _openSourceMenu() async {
    final options = _sourceOptions;
    final selected = await showMenu<String>(
      context: context,
      position: _popupPosition(),
      items: [
        for (final entry in options.entries)
          PopupMenuItem<String>(
            value: entry.key,
            child: Row(
              children: [
                SizedBox(
                  width: 28.r,
                  child: entry.key == _sourceFilter
                      ? Icon(Symbols.check_rounded, size: 18.r)
                      : null,
                ),
                Flexible(child: Text(_sourceLabel(entry.key))),
              ],
            ),
          ),
      ],
    );
    if (!mounted || selected == null) return;
    setState(() {
      _sourceFilter = selected;
      _librarySelectedIndex = 0;
      _alphabetAnchor = null;
    });
    if (selected != 'all') {
      unawaited(_loadMoreAidokuCatalogs(preferredSourceId: selected));
    }
  }

  Future<void> _openContentMenu() async {
    final selected = await showMenu<bool>(
      context: context,
      position: _popupPosition(),
      items: [
        PopupMenuItem<bool>(
          value: true,
          child: Row(
            children: [
              SizedBox(
                width: 28.r,
                child: _hideAdultContent
                    ? Icon(Symbols.check_rounded, size: 18.r)
                    : null,
              ),
              Flexible(
                child: Text(
                  Localizations.localeOf(context).languageCode == 'fr'
                      ? 'Masquer Hentai / Doujinshi'
                      : 'Hide Hentai / Doujinshi',
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<bool>(
          value: false,
          child: Row(
            children: [
              SizedBox(
                width: 28.r,
                child: !_hideAdultContent
                    ? Icon(Symbols.check_rounded, size: 18.r)
                    : null,
              ),
              Text(
                Localizations.localeOf(context).languageCode == 'fr'
                    ? 'Tout afficher'
                    : 'Show all',
              ),
            ],
          ),
        ),
      ],
    );
    if (!mounted || selected == null) return;
    setState(() {
      _hideAdultContent = selected;
      _librarySelectedIndex = 0;
      _alphabetAnchor = null;
    });
  }

  Future<void> _dismissSystemKeyboard() async {
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (_) {}
  }

  void _enterTitleSearchMode() {
    _titleSearchDebounce?.cancel();
    _titleSearchController.value = TextEditingValue(
      text: _titleQuery,
      selection: TextSelection.collapsed(offset: _titleQuery.length),
    );
    setState(() {
      _titleSearchMode = true;
      _titleSearchFiltersExpanded = false;
      _hubFocus = _HubFocus.filters;
      _filterSelectedIndex = 5;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _titleSearchFocusNode.requestFocus();
    });
  }

  void _leaveTitleSearchMode() {
    _titleSearchDebounce?.cancel();
    _titleSearchFocusNode.unfocus();
    unawaited(_dismissSystemKeyboard());
    setState(() {
      _titleSearchMode = false;
      _titleSearchFiltersExpanded = false;
      _hubFocus = _HubFocus.filters;
      _filterSelectedIndex = 5;
    });
  }

  void _scheduleInlineTitleSearch(String rawValue) {
    final query = rawValue.trim();
    _titleSearchDebounce?.cancel();
    final generation = ++_searchGeneration;
    setState(() {
      _titleQuery = query;
      _librarySelectedIndex = 0;
      _alphabetAnchor = null;
      if (query.isEmpty) {
        _remoteSearchEntries = const [];
        _searchingTitles = false;
      } else {
        // Local titles filter immediately; remote providers fill in after the
        // short debounce below, mirroring the responsive game-search field.
        _searchingTitles = true;
      }
    });
    if (query.isEmpty) return;
    _titleSearchDebounce = Timer(const Duration(milliseconds: 420), () {
      if (!mounted || generation != _searchGeneration) return;
      unawaited(_runTitleSearch(query));
    });
  }

  Future<void> _submitInlineTitleSearch(String rawValue) async {
    _titleSearchDebounce?.cancel();
    final query = rawValue.trim();
    _titleSearchFocusNode.unfocus();
    await _dismissSystemKeyboard();
    await _runTitleSearch(query);
  }

  void _clearInlineTitleSearch() {
    _titleSearchDebounce?.cancel();
    _titleSearchController.clear();
    ++_searchGeneration;
    setState(() {
      _titleQuery = '';
      _remoteSearchEntries = const [];
      _searchingTitles = false;
      _librarySelectedIndex = 0;
      _alphabetAnchor = null;
    });
    _titleSearchFocusNode.requestFocus();
  }

  void _toggleInlineSearchFilters() {
    _titleSearchFocusNode.unfocus();
    unawaited(_dismissSystemKeyboard());
    setState(() => _titleSearchFiltersExpanded = !_titleSearchFiltersExpanded);
  }

  void _tapHubCard(int index) {
    SfxService().playNavSound();
    setState(() {
      _hubFocus = _HubFocus.shortcuts;
      _hubSelectedIndex = index;
    });
    _activateSelection();
  }

  void _tapAddonSelection(int index) {
    SfxService().playNavSound();
    setState(() => _addonSelectedIndex = index);
    _activateSelection();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  Future<String?> _showUrlDialog() async {
    final controller = TextEditingController();
    const layerId = 'library_addon_url_dialog';
    GamepadNavigationManager.pushLayer(
      layerId,
      onActivate: () {},
      onDeactivate: () {},
      modal: true,
    );
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(AppLocale.libraryAddonUrlTitle.getString(dialogContext)),
          content: SizedBox(
            width: 520.r,
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: 'https://example.com/neostation-library.json',
                helperText: AppLocale.libraryAddonUrlHelp.getString(
                  dialogContext,
                ),
              ),
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  Navigator.of(dialogContext).pop(value.trim());
                }
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(AppLocale.cancel.getString(dialogContext)),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isNotEmpty) Navigator.of(dialogContext).pop(value);
              },
              child: Text(
                AppLocale.libraryAddonInstall.getString(dialogContext),
              ),
            ),
          ],
        ),
      );
    } finally {
      await _dismissSystemKeyboard();
      controller.dispose();
      GamepadNavigationManager.popLayer(layerId);
    }
  }

  Future<void> _installFromUrl() async {
    final url = await _showUrlDialog();
    if (!mounted || url == null || url.isEmpty) return;

    _showMessage(AppLocale.libraryAddonInstalling.getString(context));
    try {
      final result = await _addonService.installDocumentFromUrl(url);
      await _loadAddons();
      if (!mounted) return;
      if (result.format == LibraryAddonDocumentFormat.tachiyomiRepository ||
          result.format == LibraryAddonDocumentFormat.aidokuRepository) {
        _showMessage(
          AppLocale.libraryAddonCount
              .getString(context)
              .replaceFirst('{count}', result.totalCount.toString()),
        );
      } else {
        final addon = result.addons.single;
        _showMessage(
          result.updatedCount > 0
              ? AppLocale.libraryAddonUpdated
                    .getString(context)
                    .replaceFirst('{name}', addon.name)
              : AppLocale.libraryAddonInstalled
                    .getString(context)
                    .replaceFirst('{name}', addon.name),
        );
      }
    } on LibraryAddonException catch (error) {
      _showMessage(
        AppLocale.libraryAddonError
            .getString(context)
            .replaceFirst('{error}', error.message),
      );
    } catch (error) {
      _showMessage(
        AppLocale.libraryAddonError
            .getString(context)
            .replaceFirst('{error}', error.toString()),
      );
    }
  }

  Future<void> _installFromLocalManifest() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      allowMultiple: false,
      withData: true,
    );
    if (!mounted || result == null || result.files.isEmpty) return;

    final picked = result.files.single;
    try {
      final bytes =
          picked.bytes ??
          (picked.path == null ? null : await File(picked.path!).readAsBytes());
      if (bytes == null) {
        throw const LibraryAddonException('Unable to read selected manifest.');
      }
      final rawJson = utf8.decode(bytes);
      final providerCount = await _metadataProviderService
          .importRegistryJsonIfSupported(rawJson);
      if (providerCount != null) {
        if (!mounted) return;
        setState(() {
          _sourceFilter = 'all';
          _librarySelectedIndex = 0;
        });
        final fr = Localizations.localeOf(context).languageCode == 'fr';
        _showMessage(
          fr
              ? '$providerCount source(s) Manga Provider intégrée(s).'
              : '$providerCount Manga Provider source(s) imported.',
        );
        if (_titleQuery.trim().isNotEmpty) {
          unawaited(_runTitleSearch(_titleQuery));
        }
        return;
      }

      final install = await _addonService.installDocumentFromJson(
        rawJson,
        origin: 'file:${picked.name}',
      );
      await _loadAddons();
      if (!mounted) return;
      if (install.format == LibraryAddonDocumentFormat.tachiyomiRepository ||
          install.format == LibraryAddonDocumentFormat.aidokuRepository) {
        _showMessage(
          AppLocale.libraryAddonCount
              .getString(context)
              .replaceFirst('{count}', install.totalCount.toString()),
        );
      } else {
        final addon = install.addons.single;
        _showMessage(
          install.updatedCount > 0
              ? AppLocale.libraryAddonUpdated
                    .getString(context)
                    .replaceFirst('{name}', addon.name)
              : AppLocale.libraryAddonInstalled
                    .getString(context)
                    .replaceFirst('{name}', addon.name),
        );
      }
    } on LibraryAddonException catch (error) {
      _showMessage(
        AppLocale.libraryAddonError
            .getString(context)
            .replaceFirst('{error}', error.message),
      );
    } catch (error) {
      _showMessage(
        AppLocale.libraryAddonError
            .getString(context)
            .replaceFirst('{error}', error.toString()),
      );
    }
  }

  Future<void> _showAddonDetails(LibraryAddon addon) async {
    const layerId = 'library_addon_details_dialog';
    GamepadNavigationManager.pushLayer(
      layerId,
      onActivate: () {},
      onDeactivate: () {},
      modal: true,
    );
    try {
      final location = addon.baseUrl == null
          ? 'local'
          : (Uri.tryParse(addon.baseUrl!)?.host ?? addon.baseUrl!);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(addon.name),
          content: SizedBox(
            width: 520.r,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('v${addon.version} • $location'),
                if (addon.description.isNotEmpty) ...[
                  SizedBox(height: 10.r),
                  Text(addon.description),
                ],
                if (addon.isTachiyomiRepositorySource) ...[
                  SizedBox(height: 10.r),
                  Text(
                    'Tachiyomi/Mihon • ${addon.language ?? 'all'} • iOS metadata',
                    style: Theme.of(dialogContext).textTheme.bodySmall
                        ?.copyWith(
                          color: Theme.of(dialogContext).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  if (addon.androidPackage != null)
                    Text(
                      addon.androidPackage!,
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                ],
                if (addon.isAidokuRepositorySource) ...[
                  SizedBox(height: 10.r),
                  Text(
                    _aidokuNativeService.supports(addon)
                        ? 'Aidoku • ${addon.language ?? 'all'} • catalogue natif NeoStation'
                        : 'Aidoku • ${addon.language ?? 'all'} • métadonnées de source',
                    style: Theme.of(dialogContext).textTheme.bodySmall
                        ?.copyWith(
                          color: Theme.of(dialogContext).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  if (addon.sourceDownloadUrl != null)
                    Text(
                      addon.sourceDownloadUrl!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                ],
                SizedBox(height: 12.r),
                Text(
                  addon.origin,
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                    color: Theme.of(dialogContext).colorScheme.onSurface
                        .withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (!addon.isBuiltIn)
              TextButton.icon(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  if (addon.isRepositorySource) {
                    await _chooseRemoveSourceOrRepository(addon);
                  } else {
                    await _confirmRemoveAddon(addon);
                  }
                },
                icon: const Icon(Symbols.delete_rounded),
                label: Text(AppLocale.delete.getString(dialogContext)),
              ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(AppLocale.close.getString(dialogContext)),
            ),
          ],
        ),
      );
    } finally {
      GamepadNavigationManager.popLayer(layerId);
    }
  }

  Future<void> _openMetadataProviderItem(_NativeLibraryEntry entry) async {
    final item = entry.item;
    final hasReadable =
        item.pageUrls.isNotEmpty ||
        (item.content?.trim().isNotEmpty ?? false) ||
        item.contentUrl != null;
    final acquisitions = item.acquisitionLinks;

    if (acquisitions.isEmpty) {
      if (hasReadable) {
        await _readProviderItem(item);
        return;
      }
      final fr = Localizations.localeOf(context).languageCode == 'fr';
      _showMessage(
        fr
            ? 'Cette source ne fournit pas de pages lisibles pour ce titre.'
            : 'This source does not provide readable pages for this title.',
      );
      return;
    }

    final fr = Localizations.localeOf(context).languageCode == 'fr';
    const layerId = 'library_provider_acquisition_dialog';
    GamepadNavigationManager.pushLayer(
      layerId,
      onActivate: () {},
      onDeactivate: () {},
      modal: true,
    );
    String? choice;
    try {
      choice = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(item.title),
          content: Text(
            fr
                ? 'Choisis une action proposée directement par la source.'
                : 'Choose an action supplied directly by the source.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(fr ? 'Fermer' : 'Close'),
            ),
            if (hasReadable)
              FilledButton.icon(
                onPressed: () => Navigator.of(dialogContext).pop('read'),
                icon: const Icon(Symbols.menu_book_rounded),
                label: Text(fr ? 'Lire maintenant' : 'Read now'),
              ),
            for (var i = 0; i < acquisitions.length; i++)
              if (acquisitions[i].isExternalReader)
                OutlinedButton.icon(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop('external:$i'),
                  icon: const Icon(Symbols.open_in_new_rounded),
                  label: Text(
                    fr
                        ? 'Lire sur ${acquisitions[i].label}'
                        : 'Read on ${acquisitions[i].label}',
                  ),
                )
              else if (acquisitions[i].canDownload)
                FilledButton.tonalIcon(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop('download:$i'),
                  icon: const Icon(Symbols.download_rounded),
                  label: Text(
                    '${fr ? 'Télécharger' : 'Download'} ${acquisitions[i].label}',
                  ),
                ),
          ],
        ),
      );
    } finally {
      GamepadNavigationManager.popLayer(layerId);
    }

    if (!mounted || choice == null) return;
    if (choice == 'read') {
      await _readProviderItem(item);
      return;
    }
    final separator = choice.indexOf(':');
    if (separator <= 0) return;
    final index = int.tryParse(choice.substring(separator + 1));
    if (index == null || index < 0 || index >= acquisitions.length) return;
    final acquisition = acquisitions[index];

    if (choice.startsWith('external:')) {
      final uri = Uri.tryParse(acquisition.url);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return;
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (choice.startsWith('download:')) {
      await _downloadProviderAcquisition(item, acquisition);
    }
  }

  Future<void> _readProviderItem(LibraryCatalogItem item) async {
    if (item.pageUrls.isNotEmpty) {
      await _showPageReader(item.title, item.pageUrls, subtitle: item.subtitle);
      return;
    }
    try {
      final text = await _catalogService.loadReadableText(item);
      if (!mounted) return;
      await _showTextReader(item, text);
    } on LibraryAddonException catch (error) {
      _showMessage(error.message);
    }
  }

  Future<void> _downloadProviderAcquisition(
    LibraryCatalogItem item,
    LibraryAcquisitionLink acquisition,
  ) async {
    final fr = Localizations.localeOf(context).languageCode == 'fr';
    _showMessage(fr ? 'Téléchargement en cours…' : 'Downloading…');
    try {
      final result = await LibraryDownloadService.download(
        acquisition: acquisition,
        title: item.title,
      );
      if (!mounted) return;

      if (result.format == 'epub') {
        try {
          final text = await _catalogService.loadReadableFile(result.filePath);
          if (!mounted) return;
          await _showTextReader(item, text);
          return;
        } on LibraryAddonException catch (error) {
          _showMessage(
            fr
                ? '${result.fileName} téléchargé. ${error.message}'
                : '${result.fileName} downloaded. ${error.message}',
          );
          return;
        }
      }

      if (result.format == 'pdf') {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => LibraryPdfReaderScreen(
              filePath: result.filePath,
              title: item.title,
            ),
          ),
        );
        return;
      }

      _showMessage(
        fr
            ? '${result.fileName} téléchargé dans Library/Downloads.'
            : '${result.fileName} downloaded to Library/Downloads.',
      );
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        fr ? 'Téléchargement impossible : $error' : 'Download failed: $error',
      );
    }
  }

  Future<void> _openCatalogItem(_NativeLibraryEntry entry) async {
    if (_metadataProviderService.isProviderId(entry.providerId)) {
      await _openMetadataProviderItem(entry);
      return;
    }

    if (entry.source != null && _aidokuNativeService.supports(entry.source!)) {
      await _openAidokuTitle(entry);
      return;
    }

    if (entry.isMangaDex) {
      await _openMangaDexTitle(entry.item);
      return;
    }

    final item = entry.item;
    if (item.pageUrls.isNotEmpty) {
      await _showPageReader(item.title, item.pageUrls, subtitle: item.subtitle);
      return;
    }

    String text;
    try {
      _showMessage(
        Localizations.localeOf(context).languageCode == 'fr'
            ? 'Chargement du livre…'
            : 'Loading book…',
      );
      text = await _catalogService.loadReadableText(item);
    } on LibraryAddonException catch (error) {
      if (item.description.isNotEmpty) {
        text = item.description;
      } else {
        _showMessage(error.message);
        return;
      }
    }
    if (!mounted) return;
    await _showTextReader(item, text);
  }

  Future<void> _showTextReader(LibraryCatalogItem item, String text) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LibraryReaderScreen(
          title: item.title,
          subtitle: item.subtitle,
          coverUrl: item.coverUrl,
          text: text,
          bookmarkId: 'book:${item.id}:${item.title}',
        ),
      ),
    );
  }

  Future<void> _showPageReader(
    String title,
    List<String> pages, {
    String subtitle = '',
    Map<String, String>? imageHeaders,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LibraryReaderScreen(
          title: title,
          subtitle: subtitle,
          pages: pages,
          imageHeaders: imageHeaders,
          bookmarkId: 'pages:$title:$subtitle',
        ),
      ),
    );
  }

  Future<void> _openAidokuTitle(_NativeLibraryEntry entry) async {
    final addon = entry.source!;
    final locale = Localizations.localeOf(context).languageCode;
    var item = entry.item;

    _showMessage(
      locale == 'fr' ? 'Chargement des chapitres…' : 'Loading chapters…',
    );

    try {
      item = await _aidokuNativeService.loadDetails(addon, item);
    } catch (_) {
      // Catalog cards already contain enough data to continue if details fail.
    }

    List<LibraryAidokuChapter> chapters;
    try {
      chapters = await _aidokuNativeService.loadChapters(addon, item);
    } on LibraryAddonException catch (error) {
      _showMessage(error.message);
      return;
    }

    if (!mounted || chapters.isEmpty) {
      if (mounted) {
        _showMessage(
          locale == 'fr'
              ? 'Aucun chapitre disponible pour ce manga.'
              : 'No chapters are available for this manga.',
        );
      }
      return;
    }

    const layerId = 'library_aidoku_chapters';
    GamepadNavigationManager.pushLayer(
      layerId,
      onActivate: () {},
      onDeactivate: () {},
      modal: true,
    );
    LibraryAidokuChapter? selectedChapter;
    try {
      selectedChapter = await showDialog<LibraryAidokuChapter>(
        context: context,
        builder: (dialogContext) {
          final size = MediaQuery.sizeOf(dialogContext);
          final theme = Theme.of(dialogContext);
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.symmetric(
              horizontal: 24.r,
              vertical: 18.r,
            ),
            child: NeoGlass(
              role: GlassSurfaceRole.card,
              borderRadius: BorderRadius.circular(18.r),
              enableBackdropBlur: true,
              showSheen: false,
              child: SizedBox(
                width: size.width * 0.92,
                height: size.height * 0.86,
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(18.r, 14.r, 8.r, 8.r),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                Text(
                                  addon.name,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            icon: const Icon(Symbols.close_rounded),
                          ),
                        ],
                      ),
                    ),
                    if (item.description.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.fromLTRB(18.r, 0, 18.r, 10.r),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            item.description,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    Expanded(
                      child: ListView.separated(
                        padding: EdgeInsets.fromLTRB(12.r, 4.r, 12.r, 20.r),
                        itemCount: chapters.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, index) {
                          final chapter = chapters[index];
                          final details = <String>[
                            if (chapter.chapter.isNotEmpty)
                              'Ch. ${chapter.chapter}',
                            chapter.language.toUpperCase(),
                          ].join(' • ');
                          return ListTile(
                            title: Text(chapter.displayTitle),
                            subtitle: details.isEmpty ? null : Text(details),
                            trailing: const Icon(Symbols.menu_book_rounded),
                            onTap: () =>
                                Navigator.of(dialogContext).pop(chapter),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } finally {
      GamepadNavigationManager.popLayer(layerId);
    }

    if (!mounted || selectedChapter == null) return;
    _showMessage(locale == 'fr' ? 'Chargement des pages…' : 'Loading pages…');
    List<String> pages;
    try {
      pages = await _aidokuNativeService.loadPages(
        addon,
        item,
        selectedChapter,
      );
    } on LibraryAddonException catch (error) {
      _showMessage(error.message);
      return;
    }
    if (!mounted) return;
    await _showPageReader(
      '${item.title} — ${selectedChapter.displayTitle}',
      pages,
      subtitle: '${addon.name} • ${selectedChapter.language.toUpperCase()}',
      imageHeaders: _aidokuNativeService.imageHeaders(addon),
    );
  }

  Future<void> _openMangaDexTitle(LibraryCatalogItem item) async {
    final mangaId = item.raw['mangadexId']?.toString().trim() ?? item.id;
    final localeLanguage = Localizations.localeOf(context).languageCode;
    final languages = <String>{
      if (_languageFilter != 'all') _languageFilter,
      localeLanguage,
      'en',
    }.toList();

    _showMessage(
      localeLanguage == 'fr'
          ? 'Chargement des chapitres…'
          : 'Loading chapters…',
    );
    List<LibraryMangaDexChapter> chapters;
    try {
      chapters = await _mangaDexService.loadChapters(
        mangaId,
        languages: languages,
      );
    } on LibraryAddonException catch (error) {
      _showMessage(error.message);
      return;
    }
    if (!mounted || chapters.isEmpty) {
      if (mounted) {
        _showMessage(
          localeLanguage == 'fr'
              ? 'Aucun chapitre disponible dans les langues sélectionnées.'
              : 'No chapters are available in the selected languages.',
        );
      }
      return;
    }

    const layerId = 'library_mangadex_chapters';
    GamepadNavigationManager.pushLayer(
      layerId,
      onActivate: () {},
      onDeactivate: () {},
      modal: true,
    );
    LibraryMangaDexChapter? selectedChapter;
    try {
      selectedChapter = await showDialog<LibraryMangaDexChapter>(
        context: context,
        builder: (dialogContext) {
          final size = MediaQuery.sizeOf(dialogContext);
          final theme = Theme.of(dialogContext);
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.symmetric(
              horizontal: 24.r,
              vertical: 18.r,
            ),
            child: NeoGlass(
              role: GlassSurfaceRole.card,
              borderRadius: BorderRadius.circular(18.r),
              enableBackdropBlur: true,
              showSheen: false,
              child: SizedBox(
                width: size.width * 0.92,
                height: size.height * 0.86,
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(18.r, 14.r, 8.r, 8.r),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            icon: const Icon(Symbols.close_rounded),
                          ),
                        ],
                      ),
                    ),
                    if (item.description.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.fromLTRB(18.r, 0, 18.r, 10.r),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            item.description,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    Expanded(
                      child: ListView.separated(
                        padding: EdgeInsets.fromLTRB(12.r, 4.r, 12.r, 20.r),
                        itemCount: chapters.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, index) {
                          final chapter = chapters[index];
                          final details = <String>[
                            if (chapter.volume.isNotEmpty)
                              'Vol. ${chapter.volume}',
                            if (chapter.chapter.isNotEmpty)
                              'Ch. ${chapter.chapter}',
                            if (chapter.language.isNotEmpty)
                              chapter.language.toUpperCase(),
                          ].join(' • ');
                          return ListTile(
                            title: Text(chapter.displayTitle),
                            subtitle: details.isEmpty ? null : Text(details),
                            trailing: const Icon(Symbols.menu_book_rounded),
                            onTap: () =>
                                Navigator.of(dialogContext).pop(chapter),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } finally {
      GamepadNavigationManager.popLayer(layerId);
    }

    if (!mounted || selectedChapter == null) return;
    final pages = await _mangaDexService.loadChapterPages(selectedChapter.id);
    if (!mounted) return;
    await _showPageReader(
      '${item.title} — ${selectedChapter.displayTitle}',
      pages,
      subtitle: selectedChapter.language.toUpperCase(),
    );
  }

  Future<void> _chooseRemoveSourceOrRepository(LibraryAddon addon) async {
    final locale = Localizations.localeOf(context).languageCode;
    final repositoryCount = _addons
        .where(
          (item) =>
              item.isRepositorySource &&
              item.repositoryOrigin == addon.repositoryOrigin,
        )
        .length;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(locale == 'fr' ? 'Supprimer' : 'Remove'),
        content: Text(
          locale == 'fr'
              ? 'Cette source appartient à un dépôt contenant $repositoryCount source(s).'
              : 'This source belongs to a repository containing $repositoryCount source(s).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(AppLocale.cancel.getString(dialogContext)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('source'),
            child: Text(locale == 'fr' ? 'Cette source' : 'This source'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('repository'),
            child: Text(locale == 'fr' ? 'Tout le dépôt' : 'Entire repository'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'repository') {
      await _confirmRemoveRepository(addon);
    } else {
      await _confirmRemoveAddon(addon);
    }
  }

  Future<void> _confirmRemoveRepository(LibraryAddon addon) async {
    final locale = Localizations.localeOf(context).languageCode;
    final origin = addon.repositoryOrigin;
    final count = _addons
        .where(
          (item) => item.isRepositorySource && item.repositoryOrigin == origin,
        )
        .length;
    final confirmed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              locale == 'fr' ? 'Supprimer le dépôt ?' : 'Remove repository?',
            ),
            content: Text(
              locale == 'fr'
                  ? 'Les $count sources importées depuis ce dépôt seront supprimées. Les autres dépôts ne seront pas modifiés.'
                  : 'All $count sources imported from this repository will be removed. Other repositories will not be changed.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(AppLocale.cancel.getString(dialogContext)),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(AppLocale.delete.getString(dialogContext)),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    final removed = await _addonService.removeRepository(origin);
    await _loadAddons();
    if (!mounted) return;
    setState(() {
      final maxIndex = _view == _LibraryView.manage
          ? (_addons.length - 1).clamp(0, 9999)
          : (_addonSelectionCount - 1).clamp(0, 9999);
      _addonSelectedIndex = _addonSelectedIndex.clamp(0, maxIndex);
    });
    _showMessage(
      locale == 'fr'
          ? '$removed source(s) supprimée(s) avec le dépôt.'
          : '$removed source(s) removed with the repository.',
    );
  }

  Future<void> _confirmRemoveAddon(LibraryAddon addon) async {
    const layerId = 'library_addon_remove_dialog';
    GamepadNavigationManager.pushLayer(
      layerId,
      onActivate: () {},
      onDeactivate: () {},
      modal: true,
    );
    bool confirmed = false;
    try {
      confirmed =
          await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => AlertDialog(
              title: Text(
                AppLocale.libraryAddonRemoveTitle.getString(dialogContext),
              ),
              content: Text(
                AppLocale.libraryAddonRemoveBody
                    .getString(dialogContext)
                    .replaceFirst('{name}', addon.name),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(AppLocale.cancel.getString(dialogContext)),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(AppLocale.delete.getString(dialogContext)),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      GamepadNavigationManager.popLayer(layerId);
    }

    if (!confirmed) return;
    await _addonService.remove(addon.id);
    await _loadAddons();
    if (!mounted) return;
    setState(() {
      final maxIndex = _view == _LibraryView.manage
          ? (_addons.length - 1).clamp(0, 9999)
          : (_addonSelectionCount - 1).clamp(0, 9999);
      _addonSelectedIndex = _addonSelectedIndex.clamp(0, maxIndex);
    });
    _showMessage(
      AppLocale.libraryAddonRemoved
          .getString(context)
          .replaceFirst('{name}', addon.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24.r, 54.r, 24.r, 18.r),
        child: switch (_view) {
          _LibraryView.hub => _buildHub(context),
          _LibraryView.addons => _buildAddons(context),
          _LibraryView.local => _buildLocalLibrary(context),
          _LibraryView.manage => _buildManageSources(context),
        },
      ),
    );
  }

  Widget _buildHeader(BuildContext context, {Widget? trailing}) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 58.r,
          height: 58.r,
          child: Center(
            child: Icon(
              Symbols.menu_book_rounded,
              size: 44.r,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
        SizedBox(width: 14.r),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppLocale.library.getString(context),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 3.r),
              Text(
                AppLocale.libraryIntro.getString(context),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.68),
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _buildHub(BuildContext context) {
    if (_titleSearchMode) return _buildInlineTitleSearchHub(context);

    final theme = Theme.of(context);
    return CustomScrollView(
      controller: _libraryScrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(child: _buildHeader(context)),
        SliverToBoxAdapter(child: SizedBox(height: 20.r)),
        SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(
                child: _LibraryEntryCard(
                  selected:
                      _hubFocus == _HubFocus.shortcuts &&
                      _hubSelectedIndex == 0,
                  icon: Symbols.extension_rounded,
                  title: AppLocale.libraryAddons.getString(context),
                  subtitle: AppLocale.libraryAddonsSubtitle.getString(context),
                  onTap: () => _tapHubCard(0),
                ),
              ),
              SizedBox(width: 14.r),
              Expanded(
                child: _LibraryEntryCard(
                  selected:
                      _hubFocus == _HubFocus.shortcuts &&
                      _hubSelectedIndex == 1,
                  icon: Symbols.folder_open_rounded,
                  title: AppLocale.libraryLocal.getString(context),
                  subtitle: AppLocale.libraryLocalSubtitle.getString(context),
                  onTap: () => _tapHubCard(1),
                ),
              ),
              SizedBox(width: 14.r),
              Expanded(
                child: _LibraryEntryCard(
                  selected:
                      _hubFocus == _HubFocus.shortcuts &&
                      _hubSelectedIndex == 2,
                  icon: Symbols.manage_accounts_rounded,
                  title: Localizations.localeOf(context).languageCode == 'fr'
                      ? 'Gérer les sources'
                      : 'Manage sources',
                  subtitle: Localizations.localeOf(context).languageCode == 'fr'
                      ? 'Supprimer une source ou un dépôt installé.'
                      : 'Remove an installed source or repository.',
                  onTap: () => _tapHubCard(2),
                ),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(child: SizedBox(height: 12.r)),
        SliverToBoxAdapter(child: _buildFilters(context)),
        SliverToBoxAdapter(child: SizedBox(height: 12.r)),
        _buildNativeLibrarySliver(context, theme),
        _buildCatalogProgressSliver(context),
        SliverToBoxAdapter(child: SizedBox(height: 42.r)),
      ],
    );
  }

  Widget _buildInlineTitleSearchHub(BuildContext context) {
    final theme = Theme.of(context);
    // Match the standard game-search architecture: the query band remains
    // fixed and only the results region scrolls. This also guarantees that the
    // iOS keyboard can never cover the field the user is actively typing in.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildInlineTitleSearchRow(context, theme),
        if (_titleSearchFiltersExpanded) ...[
          SizedBox(height: 8.r),
          _buildFilters(context, includeSearch: false),
        ],
        SizedBox(height: 10.r),
        Expanded(
          child: CustomScrollView(
            controller: _libraryScrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              _buildNativeLibrarySliver(context, theme),
              _buildCatalogProgressSliver(context),
              SliverToBoxAdapter(child: SizedBox(height: 42.r)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInlineTitleSearchRow(BuildContext context, ThemeData theme) {
    final locale = Localizations.localeOf(context).languageCode;
    final visible = _visibleLibraryItems;
    final countLabel = locale == 'fr'
        ? '${visible.length} résultat${visible.length > 1 ? 's' : ''}'
        : '${visible.length} result${visible.length == 1 ? '' : 's'}';
    final activeFilters = <bool>[
      _languageFilter != 'all',
      _sourceFilter != 'all',
      _alphabetAnchor != null,
      !_hideAdultContent,
    ].where((value) => value).length;

    return Row(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(
                color: _titleSearchFocusNode.hasFocus
                    ? theme.colorScheme.primary
                    : Colors.transparent,
                width: 2.r,
              ),
            ),
            child: TextField(
              controller: _titleSearchController,
              focusNode: _titleSearchFocusNode,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onTap: () {
                if (mounted) setState(() {});
              },
              onChanged: _scheduleInlineTitleSearch,
              onSubmitted: _submitInlineTitleSearch,
              decoration: InputDecoration(
                hintText: locale == 'fr' ? 'Rechercher…' : 'Search…',
                prefixIcon: const Icon(Symbols.search_rounded),
                suffixIcon: _titleSearchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: locale == 'fr' ? 'Effacer' : 'Clear',
                        onPressed: _clearInlineTitleSearch,
                        icon: const Icon(Symbols.close_rounded),
                      ),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12.r,
                  vertical: 10.r,
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12.r),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: 10.r),
        if (_searchingTitles) ...[
          SizedBox(
            width: 14.r,
            height: 14.r,
            child: const CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 7.r),
        ],
        Text(
          countLabel,
          style: TextStyle(
            fontSize: 12.r,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        SizedBox(width: 10.r),
        GestureDetector(
          onTap: _toggleInlineSearchFilters,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 9.r),
            decoration: BoxDecoration(
              color: _titleSearchFiltersExpanded
                  ? theme.colorScheme.primary.withValues(alpha: 0.18)
                  : (activeFilters > 0
                        ? theme.colorScheme.primary.withValues(alpha: 0.10)
                        : theme.colorScheme.surface.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(
                color: _titleSearchFiltersExpanded
                    ? theme.colorScheme.primary
                    : (activeFilters > 0
                          ? theme.colorScheme.primary.withValues(alpha: 0.5)
                          : Colors.transparent),
                width: 2.r,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Symbols.tune_rounded, size: 18.r),
                SizedBox(width: 6.r),
                Text(
                  locale == 'fr' ? 'Filtres' : 'Filters',
                  style: TextStyle(fontSize: 13.r, fontWeight: FontWeight.w700),
                ),
                if (activeFilters > 0) ...[
                  SizedBox(width: 6.r),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 6.r,
                      vertical: 1.r,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(8.r),
                    ),
                    child: Text(
                      '$activeFilters',
                      style: TextStyle(
                        fontSize: 11.r,
                        fontWeight: FontWeight.w800,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ],
                SizedBox(width: 4.r),
                Icon(
                  _titleSearchFiltersExpanded
                      ? Symbols.expand_less_rounded
                      : Symbols.expand_more_rounded,
                  size: 16.r,
                ),
              ],
            ),
          ),
        ),
        SizedBox(width: 6.r),
        IconButton(
          tooltip: locale == 'fr' ? 'Fermer la recherche' : 'Close search',
          onPressed: _leaveTitleSearchMode,
          icon: const Icon(Symbols.close_rounded),
        ),
      ],
    );
  }

  Widget _buildFilters(BuildContext context, {bool includeSearch = true}) {
    final locale = Localizations.localeOf(context).languageCode;
    final visible = _visibleLibraryItems;
    final countLabel = _titleQuery.isNotEmpty
        ? (locale == 'fr'
              ? '${visible.length} résultat${visible.length > 1 ? 's' : ''}'
              : '${visible.length} result${visible.length == 1 ? '' : 's'}')
        : (locale == 'fr'
              ? '${visible.length} titre${visible.length > 1 ? 's' : ''}'
              : '${visible.length} title${visible.length == 1 ? '' : 's'}');

    Widget control({
      required int index,
      required IconData icon,
      required String label,
      required String value,
      required VoidCallback action,
    }) {
      return Expanded(
        child: SizedBox(
          height: 190.r,
          child: _FilterControl(
            selected:
                _hubFocus == _HubFocus.filters && _filterSelectedIndex == index,
            icon: icon,
            label: label,
            value: value,
            onTap: () {
              setState(() {
                _hubFocus = _HubFocus.filters;
                _filterSelectedIndex = index;
              });
              action();
            },
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            control(
              index: 0,
              icon: Symbols.translate_rounded,
              label: locale == 'fr' ? 'Langue' : 'Language',
              value: _languageLabel(_languageFilter),
              action: _openLanguageMenu,
            ),
            SizedBox(width: 8.r),
            control(
              index: 1,
              icon: Symbols.sort_by_alpha_rounded,
              label: locale == 'fr' ? 'Tri' : 'Sort',
              value: _sortAscending ? 'A → Z' : 'Z → A',
              action: _openSortMenu,
            ),
            SizedBox(width: 8.r),
            control(
              index: 2,
              icon: Symbols.abc_rounded,
              label: 'Index',
              value: _alphabetAnchor == null ? 'A–Z' : _alphabetAnchor!,
              action: _openIndexMenu,
            ),
            SizedBox(width: 8.r),
            control(
              index: 3,
              icon: Symbols.source_rounded,
              label: 'Source',
              value: _sourceLabel(_sourceFilter),
              action: _openSourceMenu,
            ),
            SizedBox(width: 8.r),
            control(
              index: 4,
              icon: Symbols.visibility_off_rounded,
              label: locale == 'fr' ? 'Contenu' : 'Content',
              value: _contentFilterLabel(),
              action: _openContentMenu,
            ),
            if (includeSearch) ...[
              SizedBox(width: 8.r),
              control(
                index: 5,
                icon: Symbols.search_rounded,
                label: locale == 'fr' ? 'Recherche' : 'Search',
                value: _titleQuery.isEmpty
                    ? (locale == 'fr' ? 'Titre' : 'Title')
                    : _titleQuery,
                action: _enterTitleSearchMode,
              ),
            ],
          ],
        ),
        SizedBox(height: 7.r),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_searchingTitles) ...[
              SizedBox(
                width: 13.r,
                height: 13.r,
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 7.r),
              Text(
                locale == 'fr'
                    ? 'Recherche dans les sources…'
                    : 'Searching sources…',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SizedBox(width: 12.r),
            ],
            Text(
              countLabel,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.58),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNativeLibrarySliver(BuildContext context, ThemeData theme) {
    if (_loadingLibrary) {
      return SliverToBoxAdapter(
        child: SizedBox(
          height: 220.r,
          child: const Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final visible = _visibleLibraryItems;
    if (visible.isEmpty) {
      final hasContent =
          _libraryItems.isNotEmpty || _remoteSearchEntries.isNotEmpty;
      return SliverToBoxAdapter(
        child: SizedBox(
          height: 220.r,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_searchingTitles)
                  const CircularProgressIndicator()
                else
                  Icon(
                    Symbols.collections_bookmark_rounded,
                    size: 38.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
                  ),
                SizedBox(height: 8.r),
                Text(
                  _searchingTitles
                      ? (Localizations.localeOf(context).languageCode == 'fr'
                            ? 'Recherche dans les catalogues…'
                            : 'Searching catalogs…')
                      : hasContent
                      ? (Localizations.localeOf(context).languageCode == 'fr'
                            ? 'Aucun livre pour ce filtre'
                            : 'No books match this filter')
                      : AppLocale.libraryEmptyTitle.getString(context),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_catalogFailures > 0) ...[
                  SizedBox(height: 5.r),
                  Text(
                    '$_catalogFailures catalogue(s) n’ont pas pu être chargés.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.crossAxisExtent >= 1200 ? 6 : 5;
        _libraryColumns = columns;
        final spacing = 12.r;
        final totalSpacing = (columns - 1) * spacing;
        final cardWidth =
            (constraints.crossAxisExtent - totalSpacing) / columns;
        final cardHeight = cardWidth / 0.68;
        _libraryRowExtent = cardHeight + spacing;

        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            childAspectRatio: 0.68,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final entry = visible[index];
              final languages = _itemLanguageCodes(entry);
              final languageLabel = languages.isEmpty
                  ? ''
                  : languages
                        .map((code) => code.toUpperCase())
                        .take(2)
                        .join(' • ');
              return KeyedSubtree(
                key: _keyForBook(entry),
                child: _LibraryCatalogCard(
                  item: entry.item,
                  languageLabel: languageLabel,
                  selected:
                      _hubFocus == _HubFocus.books &&
                      _librarySelectedIndex == index,
                  onTap: () {
                    SfxService().playNavSound();
                    setState(() {
                      _hubFocus = _HubFocus.books;
                      _librarySelectedIndex = index;
                    });
                    _openCatalogItem(entry);
                  },
                ),
              );
            },
            childCount: visible.length,
            addAutomaticKeepAlives: false,
          ),
        );
      },
    );
  }

  Map<String, List<LibraryAddon>> get _installedRepositoryGroups {
    final groups = <String, List<LibraryAddon>>{};
    for (final addon in _addons) {
      if (!addon.isRepositorySource || addon.isBuiltIn) continue;
      groups
          .putIfAbsent(addon.repositoryOrigin, () => <LibraryAddon>[])
          .add(addon);
    }
    return groups;
  }

  String _repositoryDisplayName(String origin) {
    final uri = Uri.tryParse(origin);
    if (uri != null && uri.host.isNotEmpty) {
      final path = uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList();
      if (uri.host == 'github.com' && path.length >= 2) {
        return '${path[0]}/${path[1]}';
      }
      return uri.host;
    }
    return origin;
  }

  Widget _buildCatalogProgressSliver(BuildContext context) {
    if (!_loadingMoreCatalogs || _titleQuery.isNotEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 20.r),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 18.r,
              height: 18.r,
              child: const CircularProgressIndicator(strokeWidth: 2.2),
            ),
            SizedBox(width: 10.r),
            Text(
              Localizations.localeOf(context).languageCode == 'fr'
                  ? 'Chargement de la suite du catalogue…'
                  : 'Loading more catalog titles…',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddons(BuildContext context) {
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final repositoryGroups = _installedRepositoryGroups;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(
          context,
          trailing: FilledButton.tonalIcon(
            onPressed: _backToHub,
            icon: const Icon(Symbols.arrow_back_rounded),
            label: Text(AppLocale.back.getString(context)),
          ),
        ),
        SizedBox(height: 18.r),
        Text(
          AppLocale.libraryAddons.getString(context),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 10.r),
        Row(
          children: [
            Expanded(
              child: _LibraryEntryCard(
                selected: _addonSelectedIndex == 0,
                icon: Symbols.arrow_back_rounded,
                title: AppLocale.back.getString(context),
                subtitle: locale == 'fr'
                    ? 'Revenir à la Bibliothèque et choisir une autre section.'
                    : 'Return to the Library and choose another section.',
                onTap: () => _tapAddonSelection(0),
              ),
            ),
            SizedBox(width: 10.r),
            Expanded(
              child: _LibraryEntryCard(
                selected: _addonSelectedIndex == 1,
                icon: Symbols.language_rounded,
                title: AppLocale.libraryAddonAddUrl.getString(context),
                subtitle: AppLocale.libraryAddonAddUrlSubtitle.getString(
                  context,
                ),
                onTap: () => _tapAddonSelection(1),
              ),
            ),
            SizedBox(width: 10.r),
            Expanded(
              child: _LibraryEntryCard(
                selected: _addonSelectedIndex == 2,
                icon: Symbols.file_open_rounded,
                title: AppLocale.libraryAddonImportFile.getString(context),
                subtitle: AppLocale.libraryAddonImportFileSubtitle.getString(
                  context,
                ),
                onTap: () => _tapAddonSelection(2),
              ),
            ),
          ],
        ),
        SizedBox(height: 14.r),
        Expanded(
          child: _loadingAddons
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: EdgeInsets.only(bottom: 26.r),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (repositoryGroups.isNotEmpty) ...[
                        Row(
                          children: [
                            Icon(
                              Symbols.inventory_2_rounded,
                              size: 18.r,
                              color: theme.colorScheme.primary,
                            ),
                            SizedBox(width: 7.r),
                            Text(
                              locale == 'fr'
                                  ? 'Dépôts installés'
                                  : 'Installed repositories',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 5.r),
                        Text(
                          locale == 'fr'
                              ? 'Un dépôt peut être supprimé entièrement, avec toutes les sources qu’il a ajoutées.'
                              : 'A repository can be removed entirely together with every source it installed.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.62,
                            ),
                          ),
                        ),
                        SizedBox(height: 8.r),
                        for (final entry in repositoryGroups.entries) ...[
                          _RepositoryManagementRow(
                            name: _repositoryDisplayName(entry.key),
                            origin: entry.key,
                            sourceCount: entry.value.length,
                            onDelete: () =>
                                _confirmRemoveRepository(entry.value.first),
                          ),
                          SizedBox(height: 8.r),
                        ],
                        SizedBox(height: 8.r),
                      ],
                      Row(
                        children: [
                          Icon(
                            Symbols.extension_rounded,
                            size: 18.r,
                            color: theme.colorScheme.primary,
                          ),
                          SizedBox(width: 7.r),
                          Text(
                            AppLocale.libraryAddonInstalledSources.getString(
                              context,
                            ),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 5.r),
                      Text(
                        locale == 'fr'
                            ? 'Chaque source affichée ici a été ajoutée par l’utilisateur et peut être retirée individuellement.'
                            : 'Every source shown here was added by the user and can be removed individually.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.62,
                          ),
                        ),
                      ),
                      SizedBox(height: 8.r),
                      if (_addons.isEmpty)
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 36.r),
                          child: Center(
                            child: Text(
                              AppLocale.libraryEmptyTitle.getString(context),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.62,
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        for (
                          var index = 0;
                          index < _addons.length;
                          index++
                        ) ...[
                          _AddonRow(
                            addon: _addons[index],
                            selected: _addonSelectedIndex == index + 3,
                            onTap: () => _tapAddonSelection(index + 3),
                            onDelete: _addons[index].isBuiltIn
                                ? null
                                : () => _confirmRemoveAddon(_addons[index]),
                          ),
                          if (index + 1 < _addons.length) SizedBox(height: 8.r),
                        ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildManageSources(BuildContext context) {
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final repositoryGroups = _installedRepositoryGroups;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(
          context,
          trailing: FilledButton.tonalIcon(
            onPressed: () => _backToHub(selectManage: true),
            icon: const Icon(Symbols.arrow_back_rounded),
            label: Text(AppLocale.back.getString(context)),
          ),
        ),
        SizedBox(height: 18.r),
        Row(
          children: [
            Icon(
              Symbols.manage_accounts_rounded,
              size: 24.r,
              color: theme.colorScheme.primary,
            ),
            SizedBox(width: 9.r),
            Text(
              locale == 'fr' ? 'Gérer les sources' : 'Manage sources',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        SizedBox(height: 5.r),
        Text(
          locale == 'fr'
              ? 'Retirez à tout moment une source devenue inutile ou un dépôt complet devenu indisponible.'
              : 'Remove an unused source or an unavailable repository at any time.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.64),
          ),
        ),
        SizedBox(height: 12.r),
        Expanded(
          child: _loadingAddons
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: EdgeInsets.only(bottom: 26.r),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (repositoryGroups.isNotEmpty) ...[
                        Text(
                          locale == 'fr'
                              ? 'Dépôts installés'
                              : 'Installed repositories',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 7.r),
                        for (final entry in repositoryGroups.entries) ...[
                          _RepositoryManagementRow(
                            name: _repositoryDisplayName(entry.key),
                            origin: entry.key,
                            sourceCount: entry.value.length,
                            onDelete: () =>
                                _confirmRemoveRepository(entry.value.first),
                          ),
                          SizedBox(height: 8.r),
                        ],
                        SizedBox(height: 10.r),
                      ],
                      Text(
                        AppLocale.libraryAddonInstalledSources.getString(
                          context,
                        ),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 7.r),
                      if (_addons.isEmpty)
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 36.r),
                          child: Center(
                            child: Text(
                              AppLocale.libraryEmptyTitle.getString(context),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.62,
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        for (
                          var index = 0;
                          index < _addons.length;
                          index++
                        ) ...[
                          _AddonRow(
                            addon: _addons[index],
                            selected: _addonSelectedIndex == index,
                            onTap: () {
                              setState(() => _addonSelectedIndex = index);
                              _showAddonDetails(_addons[index]);
                            },
                            onDelete: _addons[index].isBuiltIn
                                ? null
                                : () => _confirmRemoveAddon(_addons[index]),
                          ),
                          if (index + 1 < _addons.length) SizedBox(height: 8.r),
                        ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildLocalLibrary(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(
          context,
          trailing: FilledButton.tonalIcon(
            onPressed: () => _backToHub(selectLocal: true),
            icon: const Icon(Symbols.arrow_back_rounded),
            label: Text(AppLocale.back.getString(context)),
          ),
        ),
        SizedBox(height: 24.r),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 620.r),
              child: NeoGlass(
                role: GlassSurfaceRole.card,
                borderRadius: BorderRadius.circular(16.r),
                enableBackdropBlur: false,
                showSheen: true,
                padding: EdgeInsets.all(24.r),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Symbols.folder_open_rounded,
                      size: 46.r,
                      color: theme.colorScheme.primary,
                    ),
                    SizedBox(height: 12.r),
                    Text(
                      AppLocale.libraryLocal.getString(context),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 7.r),
                    Text(
                      AppLocale.libraryNextStep.getString(context),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.68,
                        ),
                      ),
                    ),
                    SizedBox(height: 16.r),
                    FilledButton.tonalIcon(
                      onPressed: () => _backToHub(selectLocal: true),
                      icon: const Icon(Symbols.arrow_back_rounded),
                      label: Text(AppLocale.back.getString(context)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LibraryEntryCard extends StatelessWidget {
  const _LibraryEntryCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(12.r);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: selected ? theme.colorScheme.primary : Colors.transparent,
          width: selected ? 2.r : 0,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.18),
                  blurRadius: 12.r,
                  spreadRadius: 1.r,
                ),
              ]
            : null,
      ),
      child: NeoGlass(
        role: GlassSurfaceRole.card,
        borderRadius: radius,
        enableBackdropBlur: false,
        showSheen: true,
        padding: EdgeInsets.all(14.r),
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Row(
            children: [
              Container(
                width: 42.r,
                height: 42.r,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10.r),
                ),
                child: Icon(icon, size: 24.r, color: theme.colorScheme.primary),
              ),
              SizedBox(width: 12.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 3.r),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.62,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 6.r),
              Icon(
                Symbols.chevron_right_rounded,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterControl extends StatelessWidget {
  const _FilterControl({
    required this.selected,
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  List<String> get _verticalCharacters =>
      label.trim().runes.map(String.fromCharCode).toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(10.r);
    final characters = _verticalCharacters;
    return Tooltip(
      message: '$label : $value',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outline.withValues(alpha: 0.16),
            width: selected ? 2.r : 1.r,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 7.r, vertical: 9.r),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20.r, color: theme.colorScheme.primary),
                  SizedBox(height: 7.r),
                  Expanded(
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final character in characters)
                              SizedBox(
                                height: 14.r,
                                width: 18.r,
                                child: Center(
                                  child: Text(
                                    character,
                                    maxLines: 1,
                                    softWrap: false,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      height: 1,
                                      fontWeight: FontWeight.w700,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.72),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: 5.r),
                  SizedBox(
                    width: double.infinity,
                    height: 18.r,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        value,
                        maxLines: 1,
                        softWrap: false,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.62,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Icon(
                    Symbols.expand_more_rounded,
                    size: 17.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryCatalogCard extends StatelessWidget {
  const _LibraryCatalogCard({
    required this.item,
    required this.languageLabel,
    required this.selected,
    required this.onTap,
  });

  final LibraryCatalogItem item;
  final String languageLabel;
  final bool selected;
  final VoidCallback onTap;

  Map<String, String>? get _imageHeaders {
    final raw = item.raw['imageHeaders'];
    if (raw is! Map) return null;
    final result = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key?.toString().trim() ?? '';
      final value = entry.value?.toString().trim() ?? '';
      if (key.isNotEmpty && value.isNotEmpty) result[key] = value;
    }
    return result.isEmpty ? null : result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(10.r);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outline.withValues(alpha: 0.15),
          width: selected ? 2.r : 1.r,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.16),
                  blurRadius: 10.r,
                ),
              ]
            : null,
      ),
      child: NeoGlass(
        role: GlassSurfaceRole.card,
        borderRadius: radius,
        enableBackdropBlur: false,
        showSheen: false,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(
            padding: EdgeInsets.all(8.r),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(7.r),
                        child: item.coverUrl == null
                            ? ColoredBox(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.10,
                                ),
                                child: Icon(
                                  Symbols.menu_book_rounded,
                                  color: theme.colorScheme.primary,
                                  size: 34.r,
                                ),
                              )
                            : Image.network(
                                item.coverUrl!,
                                headers: _imageHeaders,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => ColoredBox(
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.10,
                                  ),
                                  child: Icon(
                                    Symbols.menu_book_rounded,
                                    color: theme.colorScheme.primary,
                                    size: 34.r,
                                  ),
                                ),
                              ),
                      ),
                      if (languageLabel.isNotEmpty)
                        Positioned(
                          top: 6.r,
                          right: 6.r,
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6.r,
                              vertical: 3.r,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.68),
                              borderRadius: BorderRadius.circular(6.r),
                            ),
                            child: Text(
                              languageLabel,
                              style: TextStyle(
                                fontSize: 9.r.clamp(8.0, 12.0),
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: 7.r),
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.05,
                  ),
                ),
                if (item.subtitle.isNotEmpty) ...[
                  SizedBox(height: 3.r),
                  Text(
                    item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.58,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RepositoryManagementRow extends StatelessWidget {
  const _RepositoryManagementRow({
    required this.name,
    required this.origin,
    required this.sourceCount,
    required this.onDelete,
  });

  final String name;
  final String origin;
  final int sourceCount;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fr = Localizations.localeOf(context).languageCode == 'fr';
    final radius = BorderRadius.circular(10.r);
    return NeoGlass(
      role: GlassSurfaceRole.card,
      borderRadius: radius,
      enableBackdropBlur: false,
      showSheen: false,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 9.r),
        child: Row(
          children: [
            Container(
              width: 38.r,
              height: 38.r,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(9.r),
              ),
              child: Icon(
                Symbols.inventory_2_rounded,
                color: theme.colorScheme.primary,
                size: 21.r,
              ),
            ),
            SizedBox(width: 10.r),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 2.r),
                  Text(
                    fr
                        ? '$sourceCount source${sourceCount > 1 ? 's' : ''} • $origin'
                        : '$sourceCount source${sourceCount == 1 ? '' : 's'} • $origin',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.58,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: 10.r),
            OutlinedButton.icon(
              onPressed: onDelete,
              icon: const Icon(Symbols.delete_forever_rounded),
              label: Text(fr ? 'Supprimer le dépôt' : 'Remove repository'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(
                  color: theme.colorScheme.error.withValues(alpha: 0.55),
                ),
                padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 9.r),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddonRow extends StatelessWidget {
  const _AddonRow({
    required this.addon,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  final LibraryAddon addon;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fr = Localizations.localeOf(context).languageCode == 'fr';
    final radius = BorderRadius.circular(10.r);
    final location = addon.baseUrl == null
        ? 'local'
        : (Uri.tryParse(addon.baseUrl!)?.host ?? addon.baseUrl!);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outline.withValues(alpha: 0.14),
          width: selected ? 2.r : 1.r,
        ),
      ),
      child: NeoGlass(
        role: GlassSurfaceRole.card,
        borderRadius: radius,
        enableBackdropBlur: false,
        showSheen: false,
        child: ListTile(
          onTap: onTap,
          leading: addon.iconUrl == null
              ? CircleAvatar(
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.12,
                  ),
                  child: Icon(
                    addon.isTachiyomiRepositorySource
                        ? Symbols.extension_rounded
                        : Symbols.menu_book_rounded,
                    color: theme.colorScheme.primary,
                  ),
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(8.r),
                  child: Image.network(
                    addon.iconUrl!,
                    width: 40.r,
                    height: 40.r,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(
                      Symbols.menu_book_rounded,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
          title: Text(
            addon.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            'v${addon.version} • $location${addon.language == null ? '' : ' • ${addon.language!.toUpperCase()}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: addon.isBuiltIn
              ? Container(
                  padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 5.r),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  child: Text(
                    fr ? 'Native' : 'Built-in',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              : OutlinedButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Symbols.delete_outline_rounded),
                  label: Text(fr ? 'Supprimer la source' : 'Remove source'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(
                      color: theme.colorScheme.error.withValues(alpha: 0.5),
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: 10.r,
                      vertical: 8.r,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
