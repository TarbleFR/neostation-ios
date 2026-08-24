import 'dart:convert';

import 'package:http/http.dart' as http;

import 'library_addon_service.dart';
import 'library_catalog_service.dart';

class LibraryMangaDexChapter {
  const LibraryMangaDexChapter({
    required this.id,
    required this.title,
    required this.chapter,
    required this.volume,
    required this.language,
    required this.publishedAt,
  });

  final String id;
  final String title;
  final String chapter;
  final String volume;
  final String language;
  final DateTime? publishedAt;

  String get displayTitle {
    if (title.isNotEmpty) return title;
    if (chapter.isNotEmpty) return 'Chapitre $chapter';
    return 'Chapitre';
  }
}

/// First native network adapter for NeoStation's reading Library.
///
/// This adapter talks directly to MangaDex's public JSON API. The provider is
/// never opened in a browser or a WebView: titles, chapters and page images are
/// normalized into NeoStation models and rendered by NeoStation itself.
class LibraryMangaDexService {
  LibraryMangaDexService._();

  static final LibraryMangaDexService instance = LibraryMangaDexService._();

  static const String providerId = 'native.mangadex';
  static const String providerName = 'MangaDex';
  static const String _apiHost = 'api.mangadex.org';
  static const String _uploadsHost = 'uploads.mangadex.org';
  static const Duration _timeout = Duration(seconds: 15);
  static const int _maxJsonBytes = 8 * 1024 * 1024;

  Future<List<LibraryCatalogItem>> loadPopular({int limit = 32}) async {
    final safeLimit = limit.clamp(1, 100).toInt();
    final uri = Uri.https(_apiHost, '/manga', <String, dynamic>{
      'limit': safeLimit.toString(),
      'includes[]': <String>['cover_art', 'author'],
      'contentRating[]': <String>['safe'],
      'order[followedCount]': 'desc',
      'hasAvailableChapters': 'true',
    });
    final decoded = await _getJson(uri);
    final data = decoded['data'];
    if (data is! List) {
      throw const LibraryAddonException('MangaDex returned no title list.');
    }

    final items = <LibraryCatalogItem>[];
    for (final raw in data) {
      if (raw is! Map) continue;
      final item = _parseManga(Map<String, dynamic>.from(raw));
      if (item != null) items.add(item);
    }
    return List.unmodifiable(items);
  }

  Future<List<LibraryCatalogItem>> searchTitles(
    String query, {
    int limit = 40,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];
    final safeLimit = limit.clamp(1, 100).toInt();
    final uri = Uri.https(_apiHost, '/manga', <String, dynamic>{
      'title': normalized,
      'limit': safeLimit.toString(),
      'includes[]': <String>['cover_art', 'author'],
      'contentRating[]': <String>['safe'],
      'hasAvailableChapters': 'true',
    });
    final decoded = await _getJson(uri);
    final data = decoded['data'];
    if (data is! List) return const [];
    final items = <LibraryCatalogItem>[];
    for (final raw in data) {
      if (raw is! Map) continue;
      final item = _parseManga(Map<String, dynamic>.from(raw));
      if (item != null) items.add(item);
    }
    return List<LibraryCatalogItem>.unmodifiable(items);
  }

  Future<List<LibraryMangaDexChapter>> loadChapters(
    String mangaId, {
    required List<String> languages,
  }) async {
    final normalizedLanguages = languages
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
    if (normalizedLanguages.isEmpty) normalizedLanguages.add('en');

    final uri = Uri.https(_apiHost, '/manga/$mangaId/feed', <String, dynamic>{
      'limit': '100',
      'translatedLanguage[]': normalizedLanguages,
      'order[chapter]': 'desc',
      'includeFutureUpdates': '0',
      'includeEmptyPages': '0',
      'includeExternalUrl': '0',
    });
    final decoded = await _getJson(uri);
    final data = decoded['data'];
    if (data is! List) {
      throw const LibraryAddonException('MangaDex returned no chapter list.');
    }

    final chapters = <LibraryMangaDexChapter>[];
    for (final raw in data) {
      if (raw is! Map) continue;
      final value = Map<String, dynamic>.from(raw);
      final id = value['id']?.toString().trim() ?? '';
      final attributes = value['attributes'];
      if (id.isEmpty || attributes is! Map) continue;
      final attrs = Map<String, dynamic>.from(attributes);
      chapters.add(
        LibraryMangaDexChapter(
          id: id,
          title: attrs['title']?.toString().trim() ?? '',
          chapter: attrs['chapter']?.toString().trim() ?? '',
          volume: attrs['volume']?.toString().trim() ?? '',
          language: attrs['translatedLanguage']?.toString().trim() ?? '',
          publishedAt: DateTime.tryParse(
            attrs['publishAt']?.toString() ??
                attrs['readableAt']?.toString() ??
                '',
          ),
        ),
      );
    }
    return List.unmodifiable(chapters);
  }

  Future<List<String>> loadChapterPages(String chapterId) async {
    final uri = Uri.https(_apiHost, '/at-home/server/$chapterId');
    final decoded = await _getJson(uri);
    final baseUrl = decoded['baseUrl']?.toString().trim() ?? '';
    final chapter = decoded['chapter'];
    if (baseUrl.isEmpty || chapter is! Map) {
      throw const LibraryAddonException(
        'MangaDex did not provide a page server for this chapter.',
      );
    }

    final baseUri = Uri.tryParse(baseUrl);
    if (baseUri == null || baseUri.scheme != 'https' || baseUri.host.isEmpty) {
      throw const LibraryAddonException('MangaDex returned an unsafe page URL.');
    }

    final chapterMap = Map<String, dynamic>.from(chapter);
    final hash = chapterMap['hash']?.toString().trim() ?? '';
    final files = chapterMap['data'];
    if (hash.isEmpty || files is! List || files.isEmpty) {
      throw const LibraryAddonException(
        'This MangaDex chapter contains no readable pages.',
      );
    }

    final pages = <String>[];
    for (final rawFile in files) {
      final file = rawFile?.toString().trim() ?? '';
      if (file.isEmpty) continue;
      final page = baseUri.resolve('/data/$hash/$file');
      if (page.scheme == 'https' && page.host.isNotEmpty) {
        pages.add(page.toString());
      }
    }
    if (pages.isEmpty) {
      throw const LibraryAddonException(
        'This MangaDex chapter contains no readable HTTPS pages.',
      );
    }
    return List.unmodifiable(pages);
  }

  LibraryCatalogItem? _parseManga(Map<String, dynamic> value) {
    final id = value['id']?.toString().trim() ?? '';
    final attributes = value['attributes'];
    if (id.isEmpty || attributes is! Map) return null;
    final attrs = Map<String, dynamic>.from(attributes);

    final title = _localizedText(attrs['title']);
    if (title.isEmpty) return null;
    final description = _localizedText(attrs['description']);

    String author = '';
    String? coverFile;
    final relationships = value['relationships'];
    if (relationships is List) {
      for (final rawRelationship in relationships) {
        if (rawRelationship is! Map) continue;
        final relationship = Map<String, dynamic>.from(rawRelationship);
        final type = relationship['type']?.toString();
        final relAttributes = relationship['attributes'];
        if (relAttributes is! Map) continue;
        final rel = Map<String, dynamic>.from(relAttributes);
        if (type == 'cover_art' && coverFile == null) {
          final filename = rel['fileName']?.toString().trim();
          if (filename != null && filename.isNotEmpty) coverFile = filename;
        } else if (type == 'author' && author.isEmpty) {
          author = rel['name']?.toString().trim() ?? '';
        }
      }
    }

    final coverUrl = coverFile == null
        ? null
        : Uri.https(
            _uploadsHost,
            '/covers/$id/$coverFile.256.jpg',
          ).toString();

    return LibraryCatalogItem(
      id: id,
      title: title,
      mediaType: LibraryMediaType.manga,
      subtitle: author,
      description: description,
      coverUrl: coverUrl,
      content: null,
      contentUrl: null,
      pageUrls: const [],
      raw: Map<String, dynamic>.unmodifiable(<String, dynamic>{
        ...value,
        'nativeProvider': providerId,
        'mangadexId': id,
      }),
    );
  }

  static String _localizedText(dynamic value) {
    if (value is! Map || value.isEmpty) return '';
    final map = Map<dynamic, dynamic>.from(value);
    for (final key in const ['fr', 'en', 'ja-ro', 'ja']) {
      final text = map[key]?.toString().trim();
      if (text != null && text.isNotEmpty) return text;
    }
    for (final raw in map.values) {
      final text = raw?.toString().trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return '';
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    http.Response response;
    try {
      response = await http
          .get(
            uri,
            headers: const <String, String>{
              'Accept': 'application/json',
              'User-Agent': 'NeoStation-iOS-Native-Library/1.0',
            },
          )
          .timeout(_timeout);
    } catch (error) {
      throw LibraryAddonException(
        'Unable to load $providerName: $error',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LibraryAddonException(
        '$providerName returned HTTP ${response.statusCode}.',
      );
    }
    if (response.bodyBytes.length > _maxJsonBytes) {
      throw const LibraryAddonException('MangaDex response is too large.');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const LibraryAddonException('MangaDex returned invalid JSON.');
    }
    if (decoded is! Map) {
      throw const LibraryAddonException('MangaDex returned an invalid response.');
    }
    return Map<String, dynamic>.from(decoded);
  }
}
