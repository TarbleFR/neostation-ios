import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:neostation/services/library_catalog_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

class LibraryMetadataProviderDefinition {
  const LibraryMetadataProviderDefinition({
    required this.id,
    required this.name,
    required this.kind,
    required this.transport,
    required this.raw,
  });

  final String id;
  final String name;
  final String kind;
  final String transport;
  final Map<String, dynamic> raw;

  bool get isManga => kind == 'manga_database';
  bool get isBooks => kind == 'books_metadata';

  factory LibraryMetadataProviderDefinition.fromJson(
    Map<String, dynamic> json,
  ) {
    return LibraryMetadataProviderDefinition(
      id: json['id']?.toString().trim() ?? '',
      name: json['name']?.toString().trim() ?? '',
      kind: json['kind']?.toString().trim() ?? '',
      transport: json['transport']?.toString().trim() ?? '',
      raw: Map<String, dynamic>.unmodifiable(json),
    );
  }
}

/// Native adapters for the seven metadata providers declared by
/// `assets/data/manga-providers.json`.
///
/// The provider registry is intentionally metadata-only. Results can enrich the
/// Library with titles, authors, covers, descriptions, identifiers and source
/// links. The service never invents chapter/download URLs and deliberately
/// ignores unrelated video/trailer media.
class LibraryMetadataProviderService {
  LibraryMetadataProviderService._();

  static final LibraryMetadataProviderService instance =
      LibraryMetadataProviderService._();

  static final _log = LoggerService.instance;
  static const String _importedRegistryPrefsKey =
      'neostation_library_metadata_provider_registry_v1';
  static const Duration _timeout = Duration(seconds: 18);
  static const int _maxBodyBytes = 5 * 1024 * 1024;
  static const String _googleBooksApiKey = String.fromEnvironment(
    'GOOGLE_BOOKS_API_KEY',
  );

  bool _initialized = false;
  List<LibraryMetadataProviderDefinition> _providers = const [];

  List<LibraryMetadataProviderDefinition> get providers => _providers;

  Map<String, String> get providerLabels => <String, String>{
    for (final provider in _providers) provider.id: provider.name,
  };

  bool isProviderId(String id) =>
      _providers.any((provider) => provider.id == id);

  String? labelFor(String id) {
    for (final provider in _providers) {
      if (provider.id == id) return provider.name;
    }
    return null;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final imported = prefs.getString(_importedRegistryPrefsKey);
    if (imported?.trim().isNotEmpty != true) {
      _providers = const <LibraryMetadataProviderDefinition>[];
      _initialized = true;
      return;
    }
    _providers = _parseRegistry(imported!);
    _initialized = true;
  }

  /// Imports NeoStation's Manga Provider registry directly from the Library
  /// file picker. Returns null for unrelated JSON so the normal add-on parser
  /// can continue handling NeoStation/Tachiyomi/Aidoku manifests.
  Future<int?> importRegistryJsonIfSupported(String rawJson) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(rawJson);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final object = Map<String, dynamic>.from(decoded);
    if (!object.containsKey('schemaVersion') ||
        !object.containsKey('contentPolicy') ||
        !object.containsKey('providers')) {
      return null;
    }

    final parsed = _parseRegistry(rawJson);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_importedRegistryPrefsKey, rawJson);
    _providers = parsed;
    _initialized = true;
    return parsed.length;
  }

  static List<LibraryMetadataProviderDefinition> _parseRegistry(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException(
        'Metadata provider registry is not an object.',
      );
    }
    final manifest = Map<String, dynamic>.from(decoded);
    if (manifest['schemaVersion'] != 1) {
      throw FormatException(
        'Unsupported metadata provider schema: ${manifest['schemaVersion']}',
      );
    }
    if (manifest['contentPolicy']?.toString() != 'metadata-only') {
      throw const FormatException(
        'NeoStation metadata provider registry must remain metadata-only.',
      );
    }
    final rawProviders = manifest['providers'];
    if (rawProviders is! List) {
      throw const FormatException(
        'Metadata provider registry has no providers.',
      );
    }

    final parsed = <LibraryMetadataProviderDefinition>[];
    final ids = <String>{};
    for (final rawProvider in rawProviders) {
      if (rawProvider is! Map) continue;
      final definition = LibraryMetadataProviderDefinition.fromJson(
        Map<String, dynamic>.from(rawProvider),
      );
      if (definition.id.isEmpty || definition.name.isEmpty) continue;
      if (!ids.add(definition.id)) {
        throw FormatException('Duplicate metadata provider: ${definition.id}');
      }
      parsed.add(definition);
    }
    if (parsed.isEmpty) {
      throw const FormatException(
        'Metadata provider registry contains no providers.',
      );
    }
    return List<LibraryMetadataProviderDefinition>.unmodifiable(parsed);
  }

  /// Searches every requested provider with a small concurrency cap so one
  /// title query cannot fan out into seven simultaneous connections on iOS.
  Future<Map<String, List<LibraryCatalogItem>>> searchAll(
    String query, {
    Set<String>? providerIds,
    int page = 1,
    int limitPerProvider = 8,
  }) async {
    await initialize();
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <String, List<LibraryCatalogItem>>{};

    final selected = _providers
        .where(
          (provider) =>
              providerIds == null || providerIds.contains(provider.id),
        )
        .toList();
    final output = <String, List<LibraryCatalogItem>>{};

    const concurrency = 3;
    for (var offset = 0; offset < selected.length; offset += concurrency) {
      final batch = selected.skip(offset).take(concurrency).toList();
      final results = await Future.wait(
        batch.map((provider) async {
          try {
            final items = await searchProvider(
              provider.id,
              trimmed,
              page: page,
              limit: limitPerProvider,
            );
            return MapEntry(provider.id, items);
          } catch (error) {
            _log.w(
              'LibraryMetadataProviderService: ${provider.id} search failed: $error',
            );
            return MapEntry(provider.id, const <LibraryCatalogItem>[]);
          }
        }),
      );
      output.addEntries(results);
    }
    return Map<String, List<LibraryCatalogItem>>.unmodifiable(output);
  }

  Future<List<LibraryCatalogItem>> searchProvider(
    String providerId,
    String query, {
    int page = 1,
    int limit = 8,
  }) async {
    await initialize();
    final provider = _providers
        .where((item) => item.id == providerId)
        .firstOrNull;
    if (provider == null) return const <LibraryCatalogItem>[];
    final safePage = page < 1 ? 1 : page;
    final safeLimit = limit.clamp(1, 25).toInt();

    return switch (provider.id) {
      'bnf' => _searchBnf(provider, query, safePage, safeLimit),
      'anilist' => _searchAniList(provider, query, safePage, safeLimit),
      'mangaupdates' => _searchMangaUpdates(
        provider,
        query,
        safePage,
        safeLimit,
      ),
      'kitsu' => _searchKitsu(provider, query, safePage, safeLimit),
      'openlibrary' => _searchOpenLibrary(provider, query, safePage, safeLimit),
      'jikan' => _searchJikan(provider, query, safePage, safeLimit),
      'googlebooks' => _searchGoogleBooks(provider, query, safePage, safeLimit),
      _ => const <LibraryCatalogItem>[],
    };
  }

  Future<List<LibraryCatalogItem>> _searchBnf(
    LibraryMetadataProviderDefinition provider,
    String query,
    int page,
    int limit,
  ) async {
    final base = provider.raw['baseURL']?.toString();
    if (base == null) return const [];
    final startRecord = ((page - 1) * limit) + 1;
    final uri = Uri.parse(base).replace(
      queryParameters: <String, String>{
        'version': '1.2',
        'operation': 'searchRetrieve',
        'recordSchema': 'dublincore',
        'query': '(bib.anywhere all "$query") and (bib.recordtype any "mon")',
        'startRecord': '$startRecord',
        'maximumRecords': '$limit',
      },
    );
    final response = await _get(
      uri,
      headers: const <String, String>{
        'Accept': 'application/xml,text/xml;q=0.9,*/*;q=0.8',
      },
    );
    return parseBnfXml(
      utf8.decode(response.bodyBytes, allowMalformed: true),
      providerName: provider.name,
    );
  }

  Future<List<LibraryCatalogItem>> _searchAniList(
    LibraryMetadataProviderDefinition provider,
    String query,
    int page,
    int limit,
  ) async {
    final endpoint = provider.raw['endpoint']?.toString();
    final search = _asMap(provider.raw['search']);
    final body = _asMap(search?['body']);
    final document = body?['query']?.toString();
    if (endpoint == null || document == null) return const [];

    final response = await _post(
      Uri.parse(endpoint),
      headers: const <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'query': document,
        'variables': <String, dynamic>{
          'search': query,
          'page': page,
          'perPage': limit,
        },
      }),
    );
    final decoded = _decodeJson(response);
    final data = _asMap(decoded);
    final pageData = _asMap(_asMap(data?['data'])?['Page']);
    final media = pageData?['media'];
    if (media is! List) return const [];

    final items = <LibraryCatalogItem>[];
    for (final value in media) {
      final raw = _asMap(value);
      if (raw == null) continue;
      final titles = _asMap(raw['title']);
      final title = _firstNonEmpty(<dynamic>[
        titles?['userPreferred'],
        titles?['english'],
        titles?['romaji'],
        titles?['native'],
      ]);
      if (title.isEmpty) continue;

      final authors = <String>[];
      final staffEdges = _asMap(raw['staff'])?['edges'];
      if (staffEdges is List) {
        for (final edgeValue in staffEdges) {
          final edge = _asMap(edgeValue);
          final role = edge?['role']?.toString().toLowerCase() ?? '';
          if (role.isNotEmpty &&
              !role.contains('story') &&
              !role.contains('original') &&
              !role.contains('art')) {
            continue;
          }
          final name = _asMap(
            _asMap(edge?['node'])?['name'],
          )?['full']?.toString();
          if (name != null && name.trim().isNotEmpty) authors.add(name.trim());
        }
      }
      final year = _asMap(raw['startDate'])?['year']?.toString() ?? '';
      final cover = _asMap(raw['coverImage']);
      final sourceUrl = _https(raw['siteUrl']);
      final normalized = <String, dynamic>{
        ...raw,
        'provider': provider.id,
        'providerName': provider.name,
        'metadataOnly': true,
        'sourceUrl': sourceUrl,
        'authors': authors,
        'year': year,
        'genres': _stringList(raw['genres']),
        'isAdult': raw['isAdult'] == true,
        'score': raw['averageScore'],
        'chapters': raw['chapters'],
        'volumes': raw['volumes'],
        'status': raw['status'],
        'alternativeTitles': <String>[
          for (final key in const ['romaji', 'english', 'native'])
            if (titles?[key]?.toString().trim().isNotEmpty == true)
              titles![key].toString().trim(),
          ..._stringList(raw['synonyms']),
        ],
      };
      items.add(
        _item(
          provider: provider,
          id: raw['id']?.toString() ?? title,
          title: title,
          mediaType: LibraryMediaType.manga,
          authors: authors,
          year: year,
          description: _cleanText(raw['description']),
          coverUrl: _firstHttps(<dynamic>[
            cover?['extraLarge'],
            cover?['large'],
            cover?['medium'],
          ]),
          raw: normalized,
        ),
      );
    }
    return List.unmodifiable(items);
  }

  Future<List<LibraryCatalogItem>> _searchMangaUpdates(
    LibraryMetadataProviderDefinition provider,
    String query,
    int page,
    int limit,
  ) async {
    final base = provider.raw['baseURL']?.toString();
    final search = _asMap(provider.raw['search']);
    final endpointPath = search?['path']?.toString();
    if (base == null || endpointPath == null) return const [];

    final response = await _post(
      _joinEndpoint(base, endpointPath),
      headers: const <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'search': query,
        'stype': 'title',
        'page': page,
        'perpage': limit,
      }),
    );
    final decoded = _asMap(_decodeJson(response));
    final results = decoded?['results'];
    if (results is! List) return const [];

    final items = <LibraryCatalogItem>[];
    for (final resultValue in results) {
      final result = _asMap(resultValue);
      if (result == null) continue;
      final record = _asMap(result['record']) ?? result;
      final title = _firstNonEmpty(<dynamic>[
        record['title'],
        result['hit_title'],
        record['name'],
      ]);
      if (title.isEmpty) continue;
      final id = _firstNonEmpty(<dynamic>[
        record['series_id'],
        record['id'],
        result['series_id'],
      ]);
      final authors = _namesFromUnknown(record['authors']);
      final publishers = _namesFromUnknown(record['publishers']);
      final genres = <String>{
        ..._namesFromUnknown(record['genres']),
        ..._namesFromUnknown(record['categories']),
      }.toList();
      final image = _imageFromMangaUpdates(record['image']);
      final sourceUrl = _firstHttps(<dynamic>[record['url'], result['url']]);
      final normalized = <String, dynamic>{
        ...record,
        'provider': provider.id,
        'providerName': provider.name,
        'metadataOnly': true,
        'sourceUrl': sourceUrl,
        'authors': authors,
        'publishers': publishers,
        'genres': genres,
        'year': record['year'],
        'score': record['bayesian_rating'] ?? record['rating'],
        // Release/scanlation fields are intentionally never promoted into
        // normalized NeoStation metadata, matching the supplied manifest.
      };
      items.add(
        _item(
          provider: provider,
          id: id.isEmpty ? title : id,
          title: title,
          mediaType: LibraryMediaType.manga,
          authors: authors,
          year: record['year']?.toString() ?? '',
          description: _cleanText(record['description']),
          coverUrl: image,
          raw: normalized,
        ),
      );
    }
    return List.unmodifiable(items);
  }

  Future<List<LibraryCatalogItem>> _searchKitsu(
    LibraryMetadataProviderDefinition provider,
    String query,
    int page,
    int limit,
  ) async {
    final base = provider.raw['baseURL']?.toString();
    final search = _asMap(provider.raw['search']);
    final endpointPath = search?['path']?.toString();
    if (base == null || endpointPath == null) return const [];
    final offset = (page - 1) * limit;
    final uri = _joinEndpoint(base, endpointPath).replace(
      queryParameters: <String, String>{
        'filter[text]': query,
        'page[limit]': '$limit',
        'page[offset]': '$offset',
      },
    );
    final response = await _get(
      uri,
      headers: const <String, String>{
        'Accept': 'application/vnd.api+json, application/json',
      },
    );
    final decoded = _asMap(_decodeJson(response));
    final data = decoded?['data'];
    if (data is! List) return const [];

    final items = <LibraryCatalogItem>[];
    for (final value in data) {
      final node = _asMap(value);
      final attributes = _asMap(node?['attributes']);
      if (node == null || attributes == null) continue;
      final titles = _asMap(attributes['titles']);
      final title = _firstNonEmpty(<dynamic>[
        attributes['canonicalTitle'],
        titles?['en'],
        titles?['en_jp'],
        titles?['ja_jp'],
      ]);
      if (title.isEmpty) continue;
      final cover = _asMap(attributes['posterImage']);
      final year = _yearFromDate(attributes['startDate']);
      final normalized = <String, dynamic>{
        ...attributes,
        'provider': provider.id,
        'providerName': provider.name,
        'metadataOnly': true,
        'sourceUrl': 'https://kitsu.app/manga/${node['id']}',
        'year': year,
        'genres': _stringList(attributes['categories']),
        'status': attributes['status'],
        'chapters': attributes['chapterCount'],
        'volumes': attributes['volumeCount'],
        'score': attributes['averageRating'],
        'ageRating': attributes['ageRating'],
        'alternativeTitles': <String>[
          ...?titles?.values
              .map((value) => value?.toString().trim())
              .whereType<String>()
              .where((value) => value.isNotEmpty),
        ],
      };
      items.add(
        _item(
          provider: provider,
          id: node['id']?.toString() ?? title,
          title: title,
          mediaType: LibraryMediaType.manga,
          year: year,
          description: _cleanText(
            attributes['synopsis'] ?? attributes['description'],
          ),
          coverUrl: _firstHttps(<dynamic>[
            cover?['original'],
            cover?['large'],
            cover?['medium'],
          ]),
          raw: normalized,
        ),
      );
    }
    return List.unmodifiable(items);
  }

  Future<List<LibraryCatalogItem>> _searchOpenLibrary(
    LibraryMetadataProviderDefinition provider,
    String query,
    int page,
    int limit,
  ) async {
    final base = provider.raw['baseURL']?.toString();
    final search = _asMap(provider.raw['search']);
    final endpointPath = search?['path']?.toString();
    if (base == null || endpointPath == null) return const [];
    final uri = _joinEndpoint(base, endpointPath).replace(
      queryParameters: <String, String>{
        'q': query,
        'page': '$page',
        'limit': '$limit',
        'fields':
            'key,title,subtitle,author_name,author_key,first_publish_year,'
            'publish_date,publisher,isbn,language,subject,cover_i,edition_key',
      },
    );
    final response = await _get(
      uri,
      headers: const <String, String>{
        'Accept': 'application/json',
        'User-Agent': 'NeoStation-iOS/1.0',
      },
    );
    final decoded = _asMap(_decodeJson(response));
    final docs = decoded?['docs'];
    if (docs is! List) return const [];

    final items = <LibraryCatalogItem>[];
    for (final value in docs) {
      final raw = _asMap(value);
      if (raw == null) continue;
      final title = raw['title']?.toString().trim() ?? '';
      if (title.isEmpty) continue;
      final authors = _stringList(raw['author_name']);
      final year = raw['first_publish_year']?.toString() ?? '';
      final key = raw['key']?.toString() ?? '';
      final coverId = raw['cover_i']?.toString();
      final sourceUrl = key.startsWith('/')
          ? 'https://openlibrary.org$key'
          : null;
      final normalized = <String, dynamic>{
        ...raw,
        'provider': provider.id,
        'providerName': provider.name,
        'metadataOnly': true,
        'sourceUrl': sourceUrl,
        'authors': authors,
        'year': year,
        'languages': _stringList(raw['language']),
        'genres': _stringList(raw['subject']),
        'isbn': _stringList(raw['isbn']),
      };
      items.add(
        _item(
          provider: provider,
          id: key.isEmpty ? title : key,
          title: title,
          mediaType: LibraryMediaType.book,
          authors: authors,
          year: year,
          description: raw['subtitle']?.toString().trim() ?? '',
          coverUrl: coverId == null || coverId.isEmpty
              ? null
              : 'https://covers.openlibrary.org/b/id/$coverId-L.jpg',
          raw: normalized,
        ),
      );
    }
    return List.unmodifiable(items);
  }

  Future<List<LibraryCatalogItem>> _searchJikan(
    LibraryMetadataProviderDefinition provider,
    String query,
    int page,
    int limit,
  ) async {
    final base = provider.raw['baseURL']?.toString();
    final search = _asMap(provider.raw['search']);
    final endpointPath = search?['path']?.toString();
    if (base == null || endpointPath == null) return const [];
    final uri = _joinEndpoint(base, endpointPath).replace(
      queryParameters: <String, String>{
        'q': query,
        'page': '$page',
        'limit': '$limit',
        'sfw': 'true',
      },
    );
    final response = await _get(uri);
    final decoded = _asMap(_decodeJson(response));
    final data = decoded?['data'];
    if (data is! List) return const [];

    final items = <LibraryCatalogItem>[];
    for (final value in data) {
      final raw = _asMap(value);
      if (raw == null) continue;
      final title = _firstNonEmpty(<dynamic>[
        raw['title_english'],
        raw['title'],
        raw['title_japanese'],
      ]);
      if (title.isEmpty) continue;
      final authors = _namesFromUnknown(raw['authors']);
      final genres = <String>{
        ..._namesFromUnknown(raw['genres']),
        ..._namesFromUnknown(raw['themes']),
        ..._namesFromUnknown(raw['demographics']),
      }.toList();
      final explicitGenres = _namesFromUnknown(raw['explicit_genres']);
      final published = _asMap(raw['published']);
      final year = _yearFromDate(published?['from']);
      final images = _asMap(raw['images']);
      final webp = _asMap(images?['webp']);
      final jpg = _asMap(images?['jpg']);
      final sourceUrl = _https(raw['url']);
      final normalized = <String, dynamic>{
        ...raw,
        'provider': provider.id,
        'providerName': provider.name,
        'metadataOnly': true,
        'sourceUrl': sourceUrl,
        'authors': authors,
        'year': year,
        'genres': genres,
        'isAdult': explicitGenres.isNotEmpty,
        'score': raw['score'],
        'status': raw['status'],
        'chapters': raw['chapters'],
        'volumes': raw['volumes'],
        'alternativeTitles': <String>[
          ..._stringList(raw['title_synonyms']),
          if (raw['title_japanese']?.toString().trim().isNotEmpty == true)
            raw['title_japanese'].toString().trim(),
        ],
      };
      items.add(
        _item(
          provider: provider,
          id: raw['mal_id']?.toString() ?? title,
          title: title,
          mediaType: LibraryMediaType.manga,
          authors: authors,
          year: year,
          description: _cleanText(raw['synopsis']),
          coverUrl: _firstHttps(<dynamic>[
            webp?['large_image_url'],
            jpg?['large_image_url'],
            webp?['image_url'],
            jpg?['image_url'],
          ]),
          raw: normalized,
        ),
      );
    }
    return List.unmodifiable(items);
  }

  /// Extracts only official acquisition/read links explicitly returned by
  /// Google Books. No alternate-copy lookup is performed.
  static List<LibraryAcquisitionLink> googleBooksAcquisitionsFromAccessInfo(
    Map<String, dynamic>? accessInfo,
  ) {
    if (accessInfo == null) return const <LibraryAcquisitionLink>[];
    final links = <LibraryAcquisitionLink>[];
    final seen = <String>{};

    void addDownload(
      String label,
      String format,
      String mimeType,
      dynamic node,
    ) {
      final map = _asMap(node);
      if (map == null || map['isAvailable'] != true) return;
      final url = _https(map['downloadLink']);
      if (url == null || !seen.add(url)) return;
      links.add(
        LibraryAcquisitionLink(
          label: label,
          url: url,
          action: 'download',
          format: format,
          mimeType: mimeType,
        ),
      );
    }

    addDownload('EPUB', 'epub', 'application/epub+zip', accessInfo['epub']);
    addDownload('PDF', 'pdf', 'application/pdf', accessInfo['pdf']);

    final webReader = _https(accessInfo['webReaderLink']);
    if (webReader != null && seen.add(webReader)) {
      links.add(
        LibraryAcquisitionLink(
          label: 'Google Books',
          url: webReader,
          action: 'read',
        ),
      );
    }
    return List<LibraryAcquisitionLink>.unmodifiable(links);
  }

  Future<List<LibraryCatalogItem>> _searchGoogleBooks(
    LibraryMetadataProviderDefinition provider,
    String query,
    int page,
    int limit,
  ) async {
    final base = provider.raw['baseURL']?.toString();
    final search = _asMap(provider.raw['search']);
    final endpointPath = search?['path']?.toString();
    if (base == null || endpointPath == null) return const [];
    final params = <String, String>{
      'q': query,
      'startIndex': '${(page - 1) * limit}',
      'maxResults': '$limit',
      'printType': 'books',
      'projection': 'full',
    };
    if (_googleBooksApiKey.trim().isNotEmpty) {
      params['key'] = _googleBooksApiKey.trim();
    }
    final uri = _joinEndpoint(
      base,
      endpointPath,
    ).replace(queryParameters: params);
    final response = await _get(uri);
    final decoded = _asMap(_decodeJson(response));
    final rawItems = decoded?['items'];
    if (rawItems is! List) return const [];

    final items = <LibraryCatalogItem>[];
    for (final value in rawItems) {
      final raw = _asMap(value);
      final volume = _asMap(raw?['volumeInfo']);
      if (raw == null || volume == null) continue;
      final title = volume['title']?.toString().trim() ?? '';
      if (title.isEmpty) continue;
      final authors = _stringList(volume['authors']);
      final year = _yearFromDate(volume['publishedDate']);
      final images = _asMap(volume['imageLinks']);
      final accessInfo = _asMap(raw['accessInfo']);
      final acquisitions = googleBooksAcquisitionsFromAccessInfo(accessInfo);
      final epubDownload = acquisitions
          .where((link) => link.canDownload && link.format == 'epub')
          .map((link) => link.url)
          .firstOrNull;
      final sourceUrl = _firstHttps(<dynamic>[
        volume['infoLink'],
        volume['canonicalVolumeLink'],
        volume['previewLink'],
      ]);
      final isbn = <String>[];
      final industry = volume['industryIdentifiers'];
      if (industry is List) {
        for (final identifierValue in industry) {
          final identifier = _asMap(identifierValue);
          final value = identifier?['identifier']?.toString().trim();
          if (value != null && value.isNotEmpty) isbn.add(value);
        }
      }
      final normalized = <String, dynamic>{
        ...raw,
        'provider': provider.id,
        'providerName': provider.name,
        'metadataOnly': true,
        'sourceUrl': sourceUrl,
        'authors': authors,
        'year': year,
        'languages': <String>[
          if (volume['language']?.toString().trim().isNotEmpty == true)
            volume['language'].toString().trim(),
        ],
        'genres': _stringList(volume['categories']),
        'isbn': isbn,
        'publisher': volume['publisher'],
        'previewUrl': _https(volume['previewLink']),
        'webReaderLink': _https(accessInfo?['webReaderLink']),
        'acquisitionLinks': acquisitions.map((link) => link.toJson()).toList(),
      };
      items.add(
        _item(
          provider: provider,
          id: raw['id']?.toString() ?? title,
          title: title,
          mediaType: LibraryMediaType.book,
          authors: authors,
          year: year,
          description: _cleanText(volume['description']),
          coverUrl: _firstHttps(<dynamic>[
            images?['extraLarge'],
            images?['large'],
            images?['medium'],
            images?['small'],
            images?['thumbnail'],
          ]),
          raw: normalized,
          contentUrl: epubDownload,
          contentType: epubDownload == null ? null : 'application/epub+zip',
          acquisitionLinks: acquisitions,
        ),
      );
    }
    return List.unmodifiable(items);
  }

  LibraryCatalogItem _item({
    required LibraryMetadataProviderDefinition provider,
    required String id,
    required String title,
    required LibraryMediaType mediaType,
    required Map<String, dynamic> raw,
    String description = '',
    String? coverUrl,
    List<String> authors = const <String>[],
    String year = '',
    String? contentUrl,
    String? contentType,
    List<LibraryAcquisitionLink> acquisitionLinks =
        const <LibraryAcquisitionLink>[],
  }) {
    final subtitleParts = <String>[
      if (authors.isNotEmpty) authors.take(2).join(', '),
      if (year.trim().isNotEmpty) year.trim(),
    ];
    return LibraryCatalogItem(
      id: id,
      title: title,
      mediaType: mediaType,
      subtitle: subtitleParts.join(' • '),
      description: description,
      coverUrl: _https(coverUrl),
      content: null,
      contentUrl: contentUrl,
      pageUrls: const <String>[],
      acquisitionLinks: List<LibraryAcquisitionLink>.unmodifiable(
        acquisitionLinks,
      ),
      raw: Map<String, dynamic>.unmodifiable(<String, dynamic>{
        ...raw,
        'provider': provider.id,
        'providerName': provider.name,
        'metadataOnly': true,
        if (contentType != null && contentType.isNotEmpty)
          'contentType': contentType,
      }),
    );
  }

  /// Parser is public for deterministic unit tests and to keep the Swift BnF
  /// prototype and the Dart runtime adapter behavior aligned.
  static List<LibraryCatalogItem> parseBnfXml(
    String rawXml, {
    String providerName = 'Bibliothèque nationale de France',
  }) {
    XmlDocument document;
    try {
      document = XmlDocument.parse(rawXml);
    } catch (_) {
      return const <LibraryCatalogItem>[];
    }

    const fields = <String>{
      'title',
      'creator',
      'contributor',
      'publisher',
      'date',
      'subject',
      'description',
      'language',
      'type',
      'format',
      'identifier',
      'source',
      'relation',
      'rights',
      'coverage',
    };
    final items = <LibraryCatalogItem>[];
    final recordData = document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'recordData',
    );

    for (final record in recordData) {
      final values = <String, List<String>>{};
      for (final element in record.descendants.whereType<XmlElement>()) {
        final name = element.name.local;
        if (!fields.contains(name)) continue;
        final text = element.innerText.trim();
        if (text.isNotEmpty)
          values.putIfAbsent(name, () => <String>[]).add(text);
      }
      final titles = values['title'] ?? const <String>[];
      if (titles.isEmpty) continue;
      final title = titles.first;
      final identifiers = values['identifier'] ?? const <String>[];
      final ark = _extractArk(identifiers);
      final isbns = _extractIsbns(<String>[
        ...identifiers,
        ...?values['description'],
      ]);
      final id =
          ark ??
          isbns.where((value) => value.length == 13).firstOrNull ??
          isbns.firstOrNull ??
          identifiers.firstOrNull ??
          title;
      final sourceUrl = ark == null ? null : 'https://catalogue.bnf.fr/$ark';
      final coverUrl = ark != null
          ? Uri.parse(
                  'https://openapi.bnf.fr/couverture/image/image/recupererImage',
                )
                .replace(
                  queryParameters: <String, String>{
                    'idArk': ark,
                    'couverture': '1',
                  },
                )
                .toString()
          : (isbns.isEmpty
                ? null
                : Uri.parse(
                        'https://openapi.bnf.fr/couverture/image/image/recupererImage',
                      )
                      .replace(
                        queryParameters: <String, String>{
                          'ISBN': isbns.first,
                          'couverture': '1',
                        },
                      )
                      .toString());
      final authors = values['creator'] ?? const <String>[];
      final dates = values['date'] ?? const <String>[];
      final raw = <String, dynamic>{
        'provider': 'bnf',
        'providerName': providerName,
        'metadataOnly': true,
        'sourceUrl': sourceUrl,
        'authors': authors,
        'contributors': values['contributor'] ?? const <String>[],
        'publishers': values['publisher'] ?? const <String>[],
        'year': dates.firstOrNull ?? '',
        'publicationDates': dates,
        'languages': values['language'] ?? const <String>[],
        'genres': values['subject'] ?? const <String>[],
        'subjects': values['subject'] ?? const <String>[],
        'formats': values['format'] ?? const <String>[],
        'identifiers': identifiers,
        'isbn': isbns,
        'ark': ark,
        'alternativeTitles': titles.skip(1).toList(),
      };
      items.add(
        LibraryCatalogItem(
          id: id,
          title: title,
          mediaType: LibraryMediaType.book,
          subtitle: <String>[
            if (authors.isNotEmpty) authors.take(2).join(', '),
            if (dates.isNotEmpty) dates.first,
          ].join(' • '),
          description: (values['description'] ?? const <String>[]).join('\n'),
          coverUrl: coverUrl,
          content: null,
          contentUrl: null,
          pageUrls: const <String>[],
          raw: Map<String, dynamic>.unmodifiable(raw),
        ),
      );
    }
    return List<LibraryCatalogItem>.unmodifiable(items);
  }

  static Uri _joinEndpoint(String base, String endpoint) {
    final baseUri = Uri.parse(base);
    final basePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    final suffix = endpoint.startsWith('/') ? endpoint : '/$endpoint';
    return baseUri.replace(path: '$basePath$suffix');
  }

  static String? _extractArk(List<String> values) {
    final pattern = RegExp(r'ark:/12148/cb[^\s?#]+', caseSensitive: false);
    for (final value in values) {
      final match = pattern.firstMatch(value);
      if (match != null) return match.group(0);
    }
    return null;
  }

  static List<String> _extractIsbns(List<String> values) {
    final result = <String>[];
    final seen = <String>{};
    final pattern = RegExp(
      r'(?:ISBN(?:-1[03])?\s*:?\s*)?([0-9X][0-9X\-\s]{8,22}[0-9X])',
      caseSensitive: false,
    );
    for (final value in values) {
      final upper = value.toUpperCase();
      final compact = value.replaceAll(RegExp(r'[^0-9Xx]'), '').toUpperCase();
      String? isbn;
      if (upper.contains('ISBN')) {
        final match = pattern.firstMatch(value);
        final raw = match?.group(1);
        if (raw != null) {
          final candidate = raw
              .replaceAll(RegExp(r'[^0-9Xx]'), '')
              .toUpperCase();
          if (candidate.length == 10 || candidate.length == 13)
            isbn = candidate;
        }
      } else if (compact.length == 10 || compact.length == 13) {
        isbn = compact;
      }
      if (isbn != null && seen.add(isbn)) result.add(isbn);
    }
    return result;
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static String _firstNonEmpty(Iterable<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty && text != 'null') return text;
    }
    return '';
  }

  static String? _firstHttps(Iterable<dynamic> values) {
    for (final value in values) {
      final url = _https(value);
      if (url != null) return url;
    }
    return null;
  }

  static String? _https(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    final normalized = text.startsWith('http://')
        ? 'https://${text.substring('http://'.length)}'
        : text;
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri.toString();
  }

  static List<String> _stringList(dynamic value) {
    if (value is List) {
      return value
          .map((item) => item?.toString().trim() ?? '')
          .where((item) => item.isNotEmpty && item != 'null')
          .toList(growable: false);
    }
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? const <String>[] : <String>[text];
  }

  static List<String> _namesFromUnknown(dynamic value) {
    if (value is! List) return _stringList(value);
    final result = <String>[];
    for (final item in value) {
      if (item is Map) {
        final map = Map<String, dynamic>.from(item);
        final name = _firstNonEmpty(<dynamic>[
          map['name'],
          map['title'],
          map['label'],
          _asMap(map['node'])?['name'],
        ]);
        if (name.isNotEmpty) result.add(name);
      } else {
        final text = item?.toString().trim() ?? '';
        if (text.isNotEmpty) result.add(text);
      }
    }
    return result;
  }

  static String? _imageFromMangaUpdates(dynamic value) {
    if (value is String) return _https(value);
    final image = _asMap(value);
    if (image == null) return null;
    final urls = _asMap(image['url']);
    return _firstHttps(<dynamic>[
      urls?['original'],
      urls?['large'],
      urls?['thumb'],
      image['original'],
      image['large'],
      image['url'],
    ]);
  }

  static String _yearFromDate(dynamic value) {
    final text = value?.toString().trim() ?? '';
    final match = RegExp(r'(^|[^0-9])(19|20)[0-9]{2}([^0-9]|$)')
        .firstMatch(text);
    if (match == null) return '';
    return RegExp(r'(19|20)[0-9]{2}').firstMatch(match.group(0)!)?.group(0) ??
        '';
  }

  static String _cleanText(dynamic value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return '';
    if (!text.contains('<') || !text.contains('>')) return text;
    return (html_parser.parseFragment(text).text ?? '').trim();
  }

  static dynamic _decodeJson(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (error) {
      throw FormatException('Provider returned invalid JSON: $error');
    }
  }

  static Future<http.Response> _get(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final response = await http
        .get(
          uri,
          headers: <String, String>{
            'Accept': 'application/json',
            'User-Agent': 'NeoStation-iOS/1.0',
            ...?headers,
          },
        )
        .timeout(_timeout);
    _validateResponse(uri, response);
    return response;
  }

  static Future<http.Response> _post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) async {
    final response = await http
        .post(
          uri,
          headers: <String, String>{
            'User-Agent': 'NeoStation-iOS/1.0',
            ...headers,
          },
          body: body,
        )
        .timeout(_timeout);
    _validateResponse(uri, response);
    return response;
  }

  static void _validateResponse(Uri uri, http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('${uri.host} returned HTTP ${response.statusCode}.');
    }
    if (response.bodyBytes.length > _maxBodyBytes) {
      throw StateError('${uri.host} returned an unexpectedly large response.');
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
