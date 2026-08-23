import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'library_addon_service.dart';
import 'library_catalog_service.dart';

class LibraryAidokuChapter {
  const LibraryAidokuChapter({
    required this.id,
    required this.title,
    required this.chapter,
    required this.language,
    required this.url,
  });

  final String id;
  final String title;
  final String chapter;
  final String language;
  final String url;

  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    if (chapter.trim().isNotEmpty) return 'Chapitre ${chapter.trim()}';
    return 'Chapitre';
  }
}

class LibraryAidokuCatalogPage {
  const LibraryAidokuCatalogPage({
    required this.items,
    required this.page,
    required this.hasMore,
  });

  final List<LibraryCatalogItem> items;
  final int page;
  final bool hasMore;
}

class _AidokuPageLoad {
  const _AidokuPageLoad(this.items, this.hasMore);

  final List<LibraryCatalogItem> items;
  final bool hasMore;
}

enum _AidokuWebKind { madara, mangaStream, lelscan, phenix }

class _AidokuWebConfig {
  const _AidokuWebConfig({
    required this.sourceId,
    required this.name,
    required this.kind,
    required this.baseUrl,
    this.sourcePath = 'manga',
    this.traversePath = 'manga',
    this.altAjax = false,
    this.altPages = false,
  });

  final String sourceId;
  final String name;
  final _AidokuWebKind kind;
  final String baseUrl;
  final String sourcePath;
  final String traversePath;
  final bool altAjax;
  final bool altPages;
}

/// Native HTTP/HTML bridge for the French Aidoku source list used by NeoStation.
///
/// The .aix packages themselves are not executed. Instead, the compatible web
/// templates used by the source repository (Madara, MangaStream and the two
/// standalone French sources) are implemented directly in Dart. This keeps the
/// Library native on iOS while letting imported source titles appear beside
/// MangaDex and Gallica and participate in the same language/source filters.
class LibraryAidokuNativeService {
  LibraryAidokuNativeService._();

  static final LibraryAidokuNativeService instance =
      LibraryAidokuNativeService._();

  static const Duration _timeout = Duration(seconds: 18);
  static const int _maxHtmlBytes = 10 * 1024 * 1024;
  static const int _maxJsonBytes = 10 * 1024 * 1024;
  static const String _userAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
      'Mobile/15E148 Safari/604.1 NeoStation/1.0';

  static const Map<String, _AidokuWebConfig> _configs = {
    'fr.astralmanga': _AidokuWebConfig(
      sourceId: 'fr.astralmanga',
      name: 'Astral Manga',
      kind: _AidokuWebKind.madara,
      baseUrl: 'https://astral-manga.fr',
      altAjax: true,
    ),
    'fr.mangascantrad': _AidokuWebConfig(
      sourceId: 'fr.mangascantrad',
      name: 'Manga Scantrad',
      kind: _AidokuWebKind.madara,
      baseUrl: 'https://manga-scantrad.io',
      altAjax: true,
    ),
    'fr.mangasorigines': _AidokuWebConfig(
      sourceId: 'fr.mangasorigines',
      name: 'Mangas Origines',
      kind: _AidokuWebKind.madara,
      baseUrl: 'https://mangas-origines.fr',
      sourcePath: 'oeuvre',
      altAjax: true,
    ),
    'fr.lelscanfr': _AidokuWebConfig(
      sourceId: 'fr.lelscanfr',
      name: 'LelscanFR',
      kind: _AidokuWebKind.lelscan,
      baseUrl: 'https://lelscanfr.com',
    ),
    'fr.phenixscans': _AidokuWebConfig(
      sourceId: 'fr.phenixscans',
      name: 'PhenixScans',
      kind: _AidokuWebKind.phenix,
      baseUrl: 'https://phenix-scans.com',
    ),
    'fr.sushiscan': _AidokuWebConfig(
      sourceId: 'fr.sushiscan',
      name: 'SushiScan',
      kind: _AidokuWebKind.mangaStream,
      baseUrl: 'https://sushiscan.net',
      traversePath: 'catalogue',
      altPages: true,
    ),
    'fr.sushiscans': _AidokuWebConfig(
      sourceId: 'fr.sushiscans',
      name: 'Sushi Scans',
      kind: _AidokuWebKind.mangaStream,
      baseUrl: 'https://sushiscan.fr',
      traversePath: 'catalogue',
      altPages: true,
    ),
  };

  String? sourceIdFor(LibraryAddon addon) {
    if (!addon.isAidokuRepositorySource) return null;
    final provider = addon.manifest['provider'];
    if (provider is Map) {
      final value = provider['sourceId']?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    if (addon.id.startsWith('aidoku.')) {
      return addon.id.substring('aidoku.'.length);
    }
    return null;
  }

  bool supports(LibraryAddon addon) {
    final sourceId = sourceIdFor(addon);
    return sourceId != null && _configs.containsKey(sourceId);
  }

  String? unsupportedReason(LibraryAddon addon) {
    if (!addon.isAidokuRepositorySource) return null;
    final sourceId = sourceIdFor(addon);
    if (sourceId == null || _configs.containsKey(sourceId)) return null;
    return switch (sourceId) {
      'fr.reaperscans' => 'Source currently marked non-working upstream.',
      'fr.mangascan' => 'Source website is currently marked offline upstream.',
      'fr.legacyscans' => 'Source currently marked non-working upstream.',
      _ => 'This Aidoku source does not yet have a native NeoStation adapter.',
    };
  }

  Map<String, String> imageHeaders(LibraryAddon addon) {
    final config = _config(addon);
    return <String, String>{
      'User-Agent': _userAgent,
      'Referer': '${config.baseUrl}/',
    };
  }

  Future<LibraryAidokuCatalogPage> loadCatalogPage(
    LibraryAddon addon, {
    int page = 1,
    String query = '',
  }) async {
    final config = _config(addon);
    final safePage = page < 1 ? 1 : page;
    final normalizedQuery = query.trim();
    final result = switch (config.kind) {
      _AidokuWebKind.madara =>
        await _loadMadaraCatalog(config, safePage, normalizedQuery),
      _AidokuWebKind.mangaStream =>
        await _loadMangaStreamCatalog(config, safePage, normalizedQuery),
      _AidokuWebKind.lelscan =>
        await _loadLelscanCatalog(config, safePage, normalizedQuery),
      _AidokuWebKind.phenix =>
        await _loadPhenixCatalog(config, safePage, normalizedQuery),
    };
    return LibraryAidokuCatalogPage(
      items: List<LibraryCatalogItem>.unmodifiable(result.items),
      page: safePage,
      hasMore: result.hasMore,
    );
  }

  Future<List<LibraryCatalogItem>> loadCatalog(
    LibraryAddon addon, {
    int limit = 24,
  }) async {
    final page = await loadCatalogPage(addon);
    final safeLimit = limit.clamp(1, 100).toInt();
    return List<LibraryCatalogItem>.unmodifiable(page.items.take(safeLimit));
  }

  Future<LibraryCatalogItem> loadDetails(
    LibraryAddon addon,
    LibraryCatalogItem item,
  ) async {
    final config = _config(addon);
    return switch (config.kind) {
      _AidokuWebKind.madara => _loadMadaraDetails(config, item),
      _AidokuWebKind.mangaStream => _loadMangaStreamDetails(config, item),
      _AidokuWebKind.lelscan => _loadLelscanDetails(config, item),
      _AidokuWebKind.phenix => _loadPhenixDetails(config, item),
    };
  }

  Future<List<LibraryAidokuChapter>> loadChapters(
    LibraryAddon addon,
    LibraryCatalogItem item,
  ) async {
    final config = _config(addon);
    final chapters = switch (config.kind) {
      _AidokuWebKind.madara => await _loadMadaraChapters(config, item),
      _AidokuWebKind.mangaStream =>
        await _loadMangaStreamChapters(config, item),
      _AidokuWebKind.lelscan => await _loadLelscanChapters(config, item),
      _AidokuWebKind.phenix => await _loadPhenixChapters(config, item),
    };
    return List.unmodifiable(chapters);
  }

  Future<List<String>> loadPages(
    LibraryAddon addon,
    LibraryCatalogItem item,
    LibraryAidokuChapter chapter,
  ) async {
    final config = _config(addon);
    final pages = switch (config.kind) {
      _AidokuWebKind.madara => await _loadMadaraPages(config, chapter),
      _AidokuWebKind.mangaStream =>
        await _loadMangaStreamPages(config, chapter),
      _AidokuWebKind.lelscan => await _loadLelscanPages(config, chapter),
      _AidokuWebKind.phenix => await _loadPhenixPages(config, item, chapter),
    };
    if (pages.isEmpty) {
      throw LibraryAddonException(
        '${config.name} returned no readable chapter pages.',
      );
    }
    return List.unmodifiable(pages);
  }

  _AidokuWebConfig _config(LibraryAddon addon) {
    final sourceId = sourceIdFor(addon);
    final config = sourceId == null ? null : _configs[sourceId];
    if (config == null) {
      throw LibraryAddonException(
        unsupportedReason(addon) ?? 'Unsupported Aidoku source.',
      );
    }
    return config;
  }

  Future<_AidokuPageLoad> _loadMadaraCatalog(
    _AidokuWebConfig config,
    int page,
    String query,
  ) async {
    Document document;
    List<Element> nodes;

    if (query.isNotEmpty) {
      final uri = Uri.parse(config.baseUrl).replace(
        queryParameters: <String, String>{
          's': query,
          'post_type': 'wp-manga',
          if (page > 1) 'paged': page.toString(),
        },
      );
      document = html_parser.parse(await _getText(uri));
      nodes = document.querySelectorAll(
        'div.c-tabs-item__content, div.row.c-tabs-item__content, div.page-item-detail',
      );
    } else {
      final uri = Uri.parse('${config.baseUrl}/wp-admin/admin-ajax.php');
      final response = await _postForm(
        uri,
        <String, String>{
          'action': 'madara_load_more',
          'page': (page - 1).toString(),
          'template': 'madara-core/content/content-archive',
          'vars[paged]': page.toString(),
          'vars[orderby]': 'meta_value_num',
          'vars[template]': 'archive',
          'vars[sidebar]': 'full',
          'vars[post_type]': 'wp-manga',
          'vars[post_status]': 'publish',
          'vars[meta_key]': '_latest_update',
          'vars[order]': 'desc',
          'vars[meta_query][relation]': 'OR',
          'vars[manga_archives_item_layout]': 'big_thumbnail',
        },
        referer: config.baseUrl,
      );
      document = html_parser.parse(response);
      nodes = document.querySelectorAll('div.page-item-detail');

      if (nodes.isEmpty) {
        final fallbackUri = page <= 1
            ? Uri.parse('${config.baseUrl}/${config.sourcePath}/')
            : Uri.parse('${config.baseUrl}/${config.sourcePath}/page/$page/');
        document = html_parser.parse(await _getText(fallbackUri));
        nodes = document.querySelectorAll(
          'div.page-item-detail, div.c-tabs-item__content',
        );
      }
    }

    final items = _parseListingNodes(
      config,
      nodes,
      titleSelectors: const ['h3.h5 > a', 'h3 a', 'a'],
    );
    return _AidokuPageLoad(items, items.isNotEmpty);
  }

  Future<_AidokuPageLoad> _loadMangaStreamCatalog(
    _AidokuWebConfig config,
    int page,
    String query,
  ) async {
    final Uri uri;
    if (query.isNotEmpty) {
      uri = Uri.parse(
        '${config.baseUrl}/${config.traversePath}/page/$page',
      ).replace(queryParameters: <String, String>{'s': query});
    } else if (page <= 1) {
      uri = Uri.parse(
        '${config.baseUrl}/${config.traversePath}/?order=update',
      );
    } else {
      uri = Uri.parse(
        '${config.baseUrl}/${config.traversePath}/?page=$page&order=update',
      );
    }
    final document = html_parser.parse(await _getText(uri));
    final nodes = document.querySelectorAll('.listupd .bsx');
    final items = _parseListingNodes(
      config,
      nodes,
      titleSelectors: const ['a'],
    );
    return _AidokuPageLoad(items, items.isNotEmpty);
  }

  Future<_AidokuPageLoad> _loadLelscanCatalog(
    _AidokuWebConfig config,
    int page,
    String query,
  ) async {
    final uri = Uri.parse('${config.baseUrl}/manga').replace(
      queryParameters: <String, String>{
        'page': page.toString(),
        if (query.isNotEmpty) 'title': query,
      },
    );
    final document = html_parser.parse(await _getText(uri));
    final items = <LibraryCatalogItem>[];
    for (final node in document.querySelectorAll('div[id="card-real"]')) {
      final link = node.querySelector('a');
      final href = link?.attributes['href']?.trim() ?? '';
      final title = node.querySelector('h2')?.text.trim() ?? '';
      final id = _mangaIdFromUrl(config, href);
      if (title.isEmpty || id.isEmpty) continue;
      final cover = _resolveHttps(
        config.baseUrl,
        node.querySelector('img')?.attributes['data-src'] ??
            node.querySelector('img')?.attributes['src'],
      );
      final categories = _listingCategories(node);
      items.add(
        _catalogItem(
          config,
          id,
          title,
          href,
          coverUrl: cover,
          categories: categories,
          explicitContent: _listingLooksExplicit(node, categories),
        ),
      );
    }
    final nextDisabled =
        document.querySelector('.pagination-disabled[aria-label*="Next"]') != null;
    return _AidokuPageLoad(items, items.isNotEmpty && !nextDisabled);
  }

  Future<_AidokuPageLoad> _loadPhenixCatalog(
    _AidokuWebConfig config,
    int page,
    String query,
  ) async {
    final Uri uri;
    if (query.isNotEmpty) {
      uri = Uri.parse('https://api.phenix-scans.com/front/manga/search').replace(
        queryParameters: <String, String>{'query': query},
      );
    } else {
      uri = Uri.parse('https://api.phenix-scans.com/front/manga').replace(
        queryParameters: <String, String>{
          'sort': 'updatedAt',
          'page': page.toString(),
          'limit': '30',
        },
      );
    }
    final decoded = await _getJson(uri);
    final rawMangas = decoded['mangas'];
    if (rawMangas is! List) return const _AidokuPageLoad([], false);
    final items = <LibraryCatalogItem>[];
    for (final raw in rawMangas) {
      if (raw is! Map) continue;
      final manga = Map<String, dynamic>.from(raw);
      final id = manga['slug']?.toString().trim() ?? '';
      final title = manga['title']?.toString().trim() ?? '';
      if (id.isEmpty || id == 'unknown' || title.isEmpty) continue;
      final coverPath = manga['coverImage']?.toString().trim();
      final cover = coverPath == null || coverPath.isEmpty
          ? null
          : _resolveHttps('https://api.phenix-scans.com', coverPath);
      final categories = <String>[];
      final rawGenres = manga['genres'];
      if (rawGenres is List) {
        for (final rawGenre in rawGenres) {
          if (rawGenre is Map) {
            final name = rawGenre['name']?.toString().trim() ?? '';
            if (name.isNotEmpty) categories.add(name);
          } else {
            final name = rawGenre?.toString().trim() ?? '';
            if (name.isNotEmpty) categories.add(name);
          }
        }
      }
      final explicitContent =
          manga['nsfw'] == true ||
          manga['adult'] == true ||
          manga['isAdult'] == true ||
          RegExp(
            r'(hentai|doujin|porn|nsfw|adult|explicit|smut|erotic|ecchi|18\+|r-?18)',
            caseSensitive: false,
          ).hasMatch(<String>[
            title,
            manga['contentRating']?.toString() ?? '',
            ...categories,
          ].join(' '));
      items.add(
        _catalogItem(
          config,
          id,
          title,
          '${config.baseUrl}/manga/$id',
          coverUrl: cover,
          description: manga['synopsis']?.toString().trim() ?? '',
          categories: categories,
          explicitContent: explicitContent,
        ),
      );
    }
    if (query.isNotEmpty) return _AidokuPageLoad(items, false);
    final pagination = decoded['pagination'];
    final hasMore = pagination is Map && pagination['hasNextPage'] == true;
    return _AidokuPageLoad(items, hasMore);
  }

  List<LibraryCatalogItem> _parseListingNodes(
    _AidokuWebConfig config,
    List<Element> nodes, {
    required List<String> titleSelectors,
  }) {
    final items = <LibraryCatalogItem>[];
    for (final node in nodes) {
      Element? link;
      for (final selector in titleSelectors) {
        final candidate = node.querySelector(selector);
        if (candidate != null && candidate.attributes['href'] != null) {
          link = candidate;
          break;
        }
      }
      link ??= node.querySelector('a');
      final href = link?.attributes['href']?.trim() ?? '';
      var title = link?.attributes['title']?.trim() ?? '';
      if (title.isEmpty) title = link?.text.trim() ?? '';
      title = title
          .replaceAll(RegExp(r'\b(HOT|NEW)\b', caseSensitive: false), '')
          .trim();
      final id = _mangaIdFromUrl(config, href);
      if (title.isEmpty || id.isEmpty) continue;
      final image = node.querySelector('img');
      final cover = _resolveHttps(
        config.baseUrl,
        image?.attributes['data-src'] ??
            image?.attributes['data-lazy-src'] ??
            image?.attributes['src'],
      );
      final categories = _listingCategories(node);
      items.add(
        _catalogItem(
          config,
          id,
          title,
          href,
          coverUrl: cover,
          categories: categories,
          explicitContent: _listingLooksExplicit(node, categories),
        ),
      );
    }
    return items;
  }

  Future<LibraryCatalogItem> _loadMadaraDetails(
    _AidokuWebConfig config,
    LibraryCatalogItem item,
  ) async {
    final document = html_parser.parse(
      await _getText(
        Uri.parse('${config.baseUrl}/${config.sourcePath}/${item.id}'),
      ),
    );
    var title = document.querySelector('div.post-title h1')?.text.trim() ?? '';
    if (title.isEmpty) title = item.title;
    final cover = _imageFromElement(
          config,
          document.querySelector('div.summary_image img'),
        ) ??
        item.coverUrl;
    final description =
        document.querySelector('div.manga-excerpt p')?.text.trim() ??
        document.querySelector('div.description-summary .summary__content')?.text.trim() ??
        document.querySelector('div.description-summary div p')?.text.trim() ??
        document.querySelector('div.summary__content p')?.text.trim() ??
        item.description;
    final author = _textAfterLabel(document, const ['Author', 'Auteur']);
    return _catalogItem(
      config,
      item.id,
      title,
      '${config.baseUrl}/${config.sourcePath}/${item.id}',
      coverUrl: cover,
      description: description,
      subtitle: author.isEmpty ? config.name : author,
    );
  }

  Future<LibraryCatalogItem> _loadMangaStreamDetails(
    _AidokuWebConfig config,
    LibraryCatalogItem item,
  ) async {
    final document = html_parser.parse(
      await _getText(
        Uri.parse('${config.baseUrl}/${config.traversePath}/${item.id}'),
      ),
    );
    final title =
        document.querySelector('h1.entry-title')?.text.trim().isNotEmpty == true
        ? document.querySelector('h1.entry-title')!.text.trim()
        : item.title;
    final cover = _imageFromElement(
          config,
          document.querySelector('.infomanga [itemprop="image"] img, .thumb img'),
        ) ??
        item.coverUrl;
    final description = document
            .querySelector('div.desc p, div.entry-content p, div[itemprop="description"]')
            ?.text
            .trim() ??
        item.description;
    final author = _tableValue(document, const ['Auteur', 'Author']);
    return _catalogItem(
      config,
      item.id,
      title,
      '${config.baseUrl}/${config.traversePath}/${item.id}',
      coverUrl: cover,
      description: description,
      subtitle: author.isEmpty ? config.name : author,
    );
  }

  Future<LibraryCatalogItem> _loadLelscanDetails(
    _AidokuWebConfig config,
    LibraryCatalogItem item,
  ) async {
    final document = html_parser.parse(
      await _getText(Uri.parse('${config.baseUrl}/manga/${item.id}')),
    );
    final image = document.querySelector('main img');
    final title = image?.attributes['alt']?.trim().isNotEmpty == true
        ? image!.attributes['alt']!.trim()
        : item.title;
    final description = document.querySelector('#description + p')?.text.trim() ??
        document.querySelector('main .card p')?.text.trim() ??
        item.description;
    final author = _textAfterLabel(document, const ['Auteur', 'Author']);
    return _catalogItem(
      config,
      item.id,
      title,
      '${config.baseUrl}/manga/${item.id}',
      coverUrl: _imageFromElement(config, image) ?? item.coverUrl,
      description: description,
      subtitle: author.isEmpty ? config.name : author,
    );
  }

  Future<LibraryCatalogItem> _loadPhenixDetails(
    _AidokuWebConfig config,
    LibraryCatalogItem item,
  ) async {
    final decoded = await _getJson(
      Uri.parse('https://api.phenix-scans.com/front/manga/${item.id}'),
    );
    final raw = decoded['manga'];
    if (raw is! Map) return item;
    final manga = Map<String, dynamic>.from(raw);
    final coverPath = manga['coverImage']?.toString().trim();
    final cover = coverPath == null || coverPath.isEmpty
        ? item.coverUrl
        : _resolveHttps('https://api.phenix-scans.com', coverPath);
    return _catalogItem(
      config,
      item.id,
      manga['title']?.toString().trim().isNotEmpty == true
          ? manga['title'].toString().trim()
          : item.title,
      '${config.baseUrl}/manga/${item.id}',
      coverUrl: cover,
      description: manga['synopsis']?.toString().trim() ?? item.description,
    );
  }

  Future<List<LibraryAidokuChapter>> _loadMadaraChapters(
    _AidokuWebConfig config,
    LibraryCatalogItem item,
  ) async {
    final uri = config.altAjax
        ? Uri.parse(
            '${config.baseUrl}/${config.sourcePath}/${item.id}/ajax/chapters',
          )
        : Uri.parse('${config.baseUrl}/wp-admin/admin-ajax.php');
    final body = config.altAjax
        ? const <String, String>{}
        : <String, String>{'action': 'manga_get_chapters', 'manga': item.id};
    final raw = await _postForm(uri, body, referer: config.baseUrl);
    final document = html_parser.parse(raw);
    final chapters = <LibraryAidokuChapter>[];
    for (final node in document.querySelectorAll('li.wp-manga-chapter')) {
      final link = node.querySelector('a');
      final href = _resolveHttps(config.baseUrl, link?.attributes['href']);
      if (href == null) continue;
      final title = link?.text.trim() ?? '';
      chapters.add(
        LibraryAidokuChapter(
          id: Uri.parse(href).path,
          title: title,
          chapter: _chapterNumber(title.isEmpty ? href : title),
          language: 'fr',
          url: href,
        ),
      );
    }
    return chapters;
  }

  Future<List<LibraryAidokuChapter>> _loadMangaStreamChapters(
    _AidokuWebConfig config,
    LibraryCatalogItem item,
  ) async {
    final document = html_parser.parse(
      await _getText(
        Uri.parse('${config.baseUrl}/${config.traversePath}/${item.id}'),
      ),
    );
    final chapters = <LibraryAidokuChapter>[];
    for (final node in document.querySelectorAll('#chapterlist li')) {
      final link = node.querySelector('a');
      final href = _resolveHttps(config.baseUrl, link?.attributes['href']);
      if (href == null) continue;
      final title = node.querySelector('span.chapternum')?.text.trim() ??
          link?.text.trim() ??
          '';
      chapters.add(
        LibraryAidokuChapter(
          id: Uri.parse(href).path.replaceFirst(RegExp(r'^/'), ''),
          title: title,
          chapter: _chapterNumber(title.isEmpty ? href : title),
          language: 'fr',
          url: href,
        ),
      );
    }
    return chapters;
  }

  Future<List<LibraryAidokuChapter>> _loadLelscanChapters(
    _AidokuWebConfig config,
    LibraryCatalogItem item,
  ) async {
    final document = html_parser.parse(
      await _getText(Uri.parse('${config.baseUrl}/manga/${item.id}')),
    );
    final chapters = <LibraryAidokuChapter>[];
    for (final link in document.querySelectorAll('#chapters-list a')) {
      final href = _resolveHttps(config.baseUrl, link.attributes['href']);
      if (href == null) continue;
      final title = link.text.trim();
      chapters.add(
        LibraryAidokuChapter(
          id: Uri.parse(href).pathSegments.isEmpty
              ? href
              : Uri.parse(href).pathSegments.last,
          title: title,
          chapter: _chapterNumber(title.isEmpty ? href : title),
          language: 'fr',
          url: href,
        ),
      );
    }
    return chapters;
  }

  Future<List<LibraryAidokuChapter>> _loadPhenixChapters(
    _AidokuWebConfig config,
    LibraryCatalogItem item,
  ) async {
    final decoded = await _getJson(
      Uri.parse('https://api.phenix-scans.com/front/manga/${item.id}'),
    );
    final raw = decoded['chapters'];
    if (raw is! List) return const [];
    final chapters = <LibraryAidokuChapter>[];
    for (final value in raw) {
      if (value is! Map) continue;
      final chapter = Map<String, dynamic>.from(value);
      final number = chapter['number']?.toString().trim() ?? '';
      if (number.isEmpty) continue;
      chapters.add(
        LibraryAidokuChapter(
          id: number,
          title: '',
          chapter: number,
          language: 'fr',
          url: '${config.baseUrl}/manga/${item.id}/chapitre/$number',
        ),
      );
    }
    return chapters;
  }

  Future<List<String>> _loadMadaraPages(
    _AidokuWebConfig config,
    LibraryAidokuChapter chapter,
  ) async {
    final uri = Uri.parse(chapter.url).replace(
      queryParameters: <String, String>{
        ...Uri.parse(chapter.url).queryParameters,
        'style': 'list',
      },
    );
    final document = html_parser.parse(
      await _getText(uri, referer: config.baseUrl),
    );
    return _imageUrlsFromElements(
      config,
      document.querySelectorAll('div.page-break > img, .reading-content img'),
    );
  }

  Future<List<String>> _loadMangaStreamPages(
    _AidokuWebConfig config,
    LibraryAidokuChapter chapter,
  ) async {
    final document = html_parser.parse(
      await _getText(Uri.parse(chapter.url), referer: config.baseUrl),
    );
    if (config.altPages) {
      final scripts = document.querySelectorAll('script').map((e) => e.text).join('\n');
      for (final match in RegExp(
        r'"images"\s*:\s*(\[[^\]]*\])',
        dotAll: true,
      ).allMatches(scripts)) {
        try {
          final decoded = jsonDecode(match.group(1)!);
          if (decoded is List) {
            final pages = decoded
                .map((value) => _resolveHttps(config.baseUrl, value))
                .whereType<String>()
                .where((value) => !value.startsWith('data:'))
                .toList();
            if (pages.isNotEmpty) return pages;
          }
        } catch (_) {
          // Continue with the regular reader-area parser.
        }
      }
    }
    return _imageUrlsFromElements(
      config,
      document.querySelectorAll('#readerarea img, .reading-content img'),
    );
  }

  Future<List<String>> _loadLelscanPages(
    _AidokuWebConfig config,
    LibraryAidokuChapter chapter,
  ) async {
    final document = html_parser.parse(
      await _getText(Uri.parse(chapter.url), referer: config.baseUrl),
    );
    return _imageUrlsFromElements(
      config,
      document.querySelectorAll('#chapter-container .chapter-image'),
    );
  }

  Future<List<String>> _loadPhenixPages(
    _AidokuWebConfig config,
    LibraryCatalogItem item,
    LibraryAidokuChapter chapter,
  ) async {
    final decoded = await _getJson(
      Uri.parse(
        'https://api.phenix-scans.com/front/manga/${item.id}/chapter/${chapter.id}',
      ),
    );
    final rawChapter = decoded['chapter'];
    if (rawChapter is! Map) return const [];
    final images = rawChapter['images'];
    if (images is! List) return const [];
    return images
        .map((value) => _resolveHttps('https://api.phenix-scans.com', value))
        .whereType<String>()
        .toList();
  }

  LibraryCatalogItem _catalogItem(
    _AidokuWebConfig config,
    String id,
    String title,
    String url, {
    String? coverUrl,
    String description = '',
    String? subtitle,
    List<String> categories = const <String>[],
    bool explicitContent = false,
  }) {
    return LibraryCatalogItem(
      id: id,
      title: title,
      mediaType: LibraryMediaType.manga,
      subtitle: subtitle ?? config.name,
      description: description,
      coverUrl: coverUrl,
      content: null,
      contentUrl: null,
      pageUrls: const [],
      raw: Map<String, dynamic>.unmodifiable(<String, dynamic>{
        'nativeProvider': 'aidoku-web',
        'aidokuSourceId': config.sourceId,
        'sourceName': config.name,
        'mangaId': id,
        'mangaUrl': _resolveHttps(config.baseUrl, url) ?? url,
        'language': 'fr',
        if (categories.isNotEmpty) 'categories': List<String>.unmodifiable(categories),
        if (explicitContent) 'explicitContent': true,
        'imageHeaders': <String, String>{
          'User-Agent': _userAgent,
          'Referer': '${config.baseUrl}/',
        },
      }),
    );
  }

  List<String> _listingCategories(Element node) {
    final categories = <String>{};
    for (final element in node.querySelectorAll(
      '.genres a, .mgen a, .seriestugenre a, [class*="genre"] a, '
      '.post-content_item .summary-content a, [class*="tag"] a, '
      'a[href*="/genre/"], a[href*="/genres/"], a[href*="/tag/"], '
      'a[href*="/tags/"], .badge, .label, .tag, .genre',
    )) {
      final value = element.text.trim();
      if (value.isNotEmpty && value.length <= 80) categories.add(value);
    }
    return categories.toList(growable: false);
  }

  bool _listingLooksExplicit(Element node, List<String> categories) {
    if (node.querySelector(
          '.adult, .nsfw, .manga-title-badges.adult, [class*="adult"], '
          '[class*="nsfw"], [class*="explicit"], [class*="hentai"], '
          '[class*="doujin"], [class*="mature"], [data-content-rating="adult"], '
          '[data-nsfw="true"], [data-adult="true"]',
        ) !=
        null) {
      return true;
    }
    final image = node.querySelector('img');
    final link = node.querySelector('a[href]');
    final metadata = <String>[
      node.attributes['class'] ?? '',
      node.attributes['data-content-rating'] ?? '',
      node.attributes['data-nsfw'] ?? '',
      node.attributes['data-adult'] ?? '',
      link?.attributes['href'] ?? '',
      link?.attributes['title'] ?? '',
      image?.attributes['alt'] ?? '',
      image?.attributes['title'] ?? '',
      image?.attributes['src'] ?? '',
      node.text,
      ...categories,
    ].join(' ');
    return RegExp(
      r'(^|[^a-z0-9])(hentai|doujinshi|doujin|porn|porno|pornographic|pornography|xxx|nsfw|r[ -]?18|18\+|18 plus|adult(?:s)?(?:[ -]?only|[ -]?content)?|mature(?:[ -]?content)?|explicit(?:[ -]?content)?|uncensored|smut|erotic|erotica|ecchi|sexual(?:[ -]?content)?|sex|hardcore|fetish|bdsm|ahegao|futanari|lolicon|shotacon|oppai|netorare|ntr|incest|rape|non[ -]?consensual|tentacle|milf|nudity|nude)([^a-z0-9]|$)',
      caseSensitive: false,
    ).hasMatch(metadata);
  }

  String _mangaIdFromUrl(_AidokuWebConfig config, String rawUrl) {
    final resolved = _resolveHttps(config.baseUrl, rawUrl);
    if (resolved == null) return '';
    final uri = Uri.tryParse(resolved);
    if (uri == null) return '';
    final parts = uri.pathSegments.where((value) => value.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    final expected = config.kind == _AidokuWebKind.mangaStream
        ? config.traversePath
        : config.sourcePath;
    final index = parts.indexOf(expected);
    if (index >= 0 && index + 1 < parts.length) return parts[index + 1];
    return parts.last;
  }

  String _chapterNumber(String value) {
    final normalized = value.replaceAll(',', '.');
    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(normalized);
    return match?.group(1) ?? '';
  }

  String _textAfterLabel(Document document, List<String> labels) {
    for (final element in document.querySelectorAll('div.post-content_item, span')) {
      final text = element.text.trim();
      if (!labels.any((label) => text.toLowerCase().contains(label.toLowerCase()))) {
        continue;
      }
      final summary = element.querySelector('.summary-content');
      if (summary != null && summary.text.trim().isNotEmpty) {
        return summary.text.trim();
      }
      final sibling = element.nextElementSibling;
      if (sibling != null && sibling.text.trim().isNotEmpty) {
        return sibling.text.trim();
      }
    }
    return '';
  }

  String _tableValue(Document document, List<String> labels) {
    for (final row in document.querySelectorAll('tr')) {
      final cells = row.querySelectorAll('td, th');
      if (cells.length < 2) continue;
      final key = cells.first.text.trim().toLowerCase();
      if (labels.any((label) => key.contains(label.toLowerCase()))) {
        return cells[1].text.trim();
      }
    }
    return '';
  }

  String? _imageFromElement(_AidokuWebConfig config, Element? element) {
    if (element == null) return null;
    return _resolveHttps(
      config.baseUrl,
      element.attributes['data-src'] ??
          element.attributes['data-lazy-src'] ??
          element.attributes['src'],
    );
  }

  List<String> _imageUrlsFromElements(
    _AidokuWebConfig config,
    List<Element> elements,
  ) {
    final pages = <String>[];
    final seen = <String>{};
    for (final element in elements) {
      final url = _imageFromElement(config, element);
      if (url == null || url.startsWith('data:') || !seen.add(url)) continue;
      pages.add(url);
    }
    return pages;
  }

  String? _resolveHttps(String baseUrl, dynamic raw) {
    var value = raw?.toString().trim() ?? '';
    if (value.isEmpty || value.startsWith('data:')) return null;
    value = value.replaceAll(r'\/', '/');
    if (value.startsWith('//')) value = 'https:$value';
    final base = Uri.tryParse(baseUrl);
    final parsed = Uri.tryParse(value);
    if (base == null || parsed == null) return null;
    var resolved = parsed.hasScheme ? parsed : base.resolve(value);
    if (resolved.scheme == 'http') {
      resolved = resolved.replace(scheme: 'https');
    }
    if (resolved.scheme != 'https' || resolved.host.isEmpty) return null;
    return resolved.toString();
  }

  Future<String> _getText(Uri uri, {String? referer}) async {
    final response = await _request(
      () => http.get(
        uri,
        headers: <String, String>{
          'Accept': 'text/html,application/xhtml+xml',
          'User-Agent': _userAgent,
          if (referer != null) 'Referer': referer,
        },
      ),
      uri,
      maxBytes: _maxHtmlBytes,
    );
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  Future<String> _postForm(
    Uri uri,
    Map<String, String> body, {
    String? referer,
  }) async {
    final response = await _request(
      () => http.post(
        uri,
        headers: <String, String>{
          'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': _userAgent,
          if (referer != null) 'Referer': referer,
        },
        body: body,
      ),
      uri,
      maxBytes: _maxHtmlBytes,
    );
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final response = await _request(
      () => http.get(
        uri,
        headers: const <String, String>{'Accept': 'application/json'},
      ),
      uri,
      maxBytes: _maxJsonBytes,
    );
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw LibraryAddonException('${uri.host} returned invalid JSON.');
    }
    if (decoded is! Map) {
      throw LibraryAddonException('${uri.host} returned an invalid JSON object.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<http.Response> _request(
    Future<http.Response> Function() request,
    Uri uri, {
    required int maxBytes,
  }) async {
    http.Response response;
    try {
      response = await request().timeout(_timeout);
    } catch (error) {
      throw LibraryAddonException('Unable to load ${uri.host}: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LibraryAddonException(
        '${uri.host} returned HTTP ${response.statusCode}.',
      );
    }
    if (response.bodyBytes.length > maxBytes) {
      throw LibraryAddonException('${uri.host} response is too large.');
    }
    return response;
  }
}
