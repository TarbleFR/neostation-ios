import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import 'library_addon_service.dart';

enum LibraryMediaType { book, manga, novel, comic, anime, unknown }

/// A source-declared acquisition action for a Library item.
///
/// NeoStation never discovers alternate copies on its own: every URL in this
/// model must come directly from the selected provider or user-installed
/// Library source.
class LibraryAcquisitionLink {
  const LibraryAcquisitionLink({
    required this.label,
    required this.url,
    required this.action,
    this.format = '',
    this.mimeType = '',
  });

  final String label;
  final String url;

  /// `download` stores the provider-supplied file locally. `read` opens the
  /// provider's official web reader.
  final String action;
  final String format;
  final String mimeType;

  bool get canDownload => action == 'download';
  bool get isExternalReader => action == 'read';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'label': label,
    'url': url,
    'action': action,
    if (format.isNotEmpty) 'format': format,
    if (mimeType.isNotEmpty) 'mimeType': mimeType,
  };
}

class LibraryCatalogItem {
  const LibraryCatalogItem({
    required this.id,
    required this.title,
    required this.mediaType,
    required this.subtitle,
    required this.description,
    required this.coverUrl,
    required this.content,
    required this.contentUrl,
    required this.pageUrls,
    required this.raw,
    this.acquisitionLinks = const <LibraryAcquisitionLink>[],
  });

  final String id;
  final String title;
  final LibraryMediaType mediaType;
  final String subtitle;
  final String description;
  final String? coverUrl;
  final String? content;
  final String? contentUrl;
  final List<String> pageUrls;
  final Map<String, dynamic> raw;
  final List<LibraryAcquisitionLink> acquisitionLinks;

  bool get hasReadableContent =>
      (content != null && content!.trim().isNotEmpty) ||
      contentUrl != null ||
      pageUrls.isNotEmpty;

  factory LibraryCatalogItem.fromJson(
    Map<String, dynamic> raw, {
    required Uri baseUri,
  }) {
    String text(List<String> keys) {
      for (final key in keys) {
        final value = raw[key]?.toString().trim();
        if (value != null && value.isNotEmpty) return value;
      }
      return '';
    }

    String? resolveUrl(dynamic value) {
      final candidate = value?.toString().trim();
      if (candidate == null || candidate.isEmpty) return null;
      final parsed = Uri.tryParse(candidate);
      final resolved = parsed != null && parsed.hasScheme
          ? parsed
          : baseUri.resolve(candidate);
      if (resolved.scheme != 'https' || resolved.host.isEmpty) return null;
      return resolved.toString();
    }

    final title = text(const ['title', 'name']);
    if (title.isEmpty) {
      throw const LibraryAddonException(
        'Catalog item is missing both "title" and "name".',
      );
    }

    final id = text(const ['id', 'slug', 'key', 'url']);
    final type = text(const ['type', 'mediaType', 'media_type']).toLowerCase();
    final mediaType = switch (type) {
      'book' => LibraryMediaType.book,
      'manga' => LibraryMediaType.manga,
      'novel' || 'light-novel' || 'light_novel' => LibraryMediaType.novel,
      'comic' || 'comics' => LibraryMediaType.comic,
      'anime' => LibraryMediaType.anime,
      _ => LibraryMediaType.unknown,
    };

    final pageUrls = <String>[];
    final rawPages = raw['pages'] ?? raw['images'];
    if (rawPages is List) {
      for (final page in rawPages) {
        final resolved = resolveUrl(page);
        if (resolved != null) pageUrls.add(resolved);
      }
    }

    final acquisitionLinks = <LibraryAcquisitionLink>[];
    final acquisitionUrls = <String>{};

    void addAcquisition(
      dynamic value, {
      String fallbackLabel = 'Download',
      String fallbackAction = 'download',
      String fallbackFormat = '',
      String fallbackMimeType = '',
    }) {
      if (value == null) return;
      if (value is Iterable && value is! String) {
        for (final entry in value) {
          addAcquisition(
            entry,
            fallbackLabel: fallbackLabel,
            fallbackAction: fallbackAction,
            fallbackFormat: fallbackFormat,
            fallbackMimeType: fallbackMimeType,
          );
        }
        return;
      }

      dynamic rawUrl = value;
      var label = fallbackLabel;
      var action = fallbackAction;
      var format = fallbackFormat;
      var mimeType = fallbackMimeType;
      if (value is Map) {
        rawUrl = value['url'] ?? value['href'] ?? value['downloadUrl'];
        label = value['label']?.toString().trim() ?? label;
        action = value['action']?.toString().trim().toLowerCase() ?? action;
        format = value['format']?.toString().trim().toLowerCase() ?? format;
        mimeType =
            value['mimeType']?.toString().trim().toLowerCase() ??
            value['type']?.toString().trim().toLowerCase() ??
            mimeType;
      }

      final url = resolveUrl(rawUrl);
      if (url == null || !acquisitionUrls.add(url)) return;
      if (action != 'read' && action != 'download') action = 'download';
      acquisitionLinks.add(
        LibraryAcquisitionLink(
          label: label.isEmpty ? fallbackLabel : label,
          url: url,
          action: action,
          format: format,
          mimeType: mimeType,
        ),
      );
    }

    addAcquisition(raw['acquisitionLinks']);
    addAcquisition(raw['downloadUrl']);
    addAcquisition(raw['downloadUrls']);
    addAcquisition(
      raw['epubUrl'],
      fallbackLabel: 'EPUB',
      fallbackFormat: 'epub',
      fallbackMimeType: 'application/epub+zip',
    );
    addAcquisition(
      raw['pdfUrl'],
      fallbackLabel: 'PDF',
      fallbackFormat: 'pdf',
      fallbackMimeType: 'application/pdf',
    );

    final inlineContent = text(const ['content', 'text', 'body', 'markdown']);

    return LibraryCatalogItem(
      id: id.isEmpty ? title : id,
      title: title,
      mediaType: mediaType,
      subtitle: text(const ['subtitle', 'author', 'creator']),
      description: text(const ['description', 'summary', 'synopsis']),
      coverUrl: resolveUrl(
        raw['coverUrl'] ?? raw['cover'] ?? raw['thumbnail'] ?? raw['image'],
      ),
      content: inlineContent.isEmpty ? null : inlineContent,
      contentUrl: resolveUrl(
        raw['contentUrl'] ?? raw['readerUrl'] ?? raw['readUrl'],
      ),
      pageUrls: List.unmodifiable(pageUrls),
      raw: Map<String, dynamic>.unmodifiable(raw),
      acquisitionLinks: List.unmodifiable(acquisitionLinks),
    );
  }
}

class LibraryCatalogService {
  LibraryCatalogService._();

  static final LibraryCatalogService instance = LibraryCatalogService._();

  static const Duration _timeout = Duration(seconds: 20);
  static const int _maxCatalogBytes = 12 * 1024 * 1024;
  static const int _maxReaderBytes = 32 * 1024 * 1024;

  Future<List<LibraryCatalogItem>> loadCatalog(LibraryAddon addon) async {
    if (addon.sourceKind == LibrarySourceKind.metadataOnly) {
      throw const LibraryAddonException(
        'This Tachiyomi/Mihon source is metadata-only on iOS. '
        'Its Android extension runtime cannot execute inside NeoStation.',
      );
    }
    if (addon.sourceKind == LibrarySourceKind.localLibrary) {
      throw const LibraryAddonException(
        'This is a local library source. A local library location must be '
        'configured before it can be browsed.',
      );
    }

    final baseUrl = addon.baseUrl;
    if (baseUrl == null) {
      throw const LibraryAddonException('Catalog source has no baseUrl.');
    }
    final endpoint = addon.catalogEndpoint;
    if (endpoint == null) {
      throw const LibraryAddonException(
        'This NeoStation source does not expose endpoints.catalog or endpoints.browse.',
      );
    }

    final baseUri = Uri.parse(baseUrl);
    final uri = _resolveHttps(baseUri, endpoint, field: 'catalog endpoint');

    if (addon.isGallicaSource) {
      final response = await _get(
        uri,
        maxBytes: _maxCatalogBytes,
        accept: 'application/atom+xml, application/xml, text/xml',
      );
      return parseGallicaOpdsDocument(
        utf8.decode(response.bodyBytes, allowMalformed: true),
        baseUri: baseUri,
      );
    }

    final response = await _get(uri, maxBytes: _maxCatalogBytes);

    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const LibraryAddonException(
        'Catalog endpoint did not return valid JSON.',
      );
    }

    final rawItems = _extractItems(decoded);
    final items = <LibraryCatalogItem>[];
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      try {
        items.add(
          LibraryCatalogItem.fromJson(
            Map<String, dynamic>.from(raw),
            baseUri: baseUri,
          ),
        );
      } on LibraryAddonException {
        // One malformed entry should not make an otherwise valid catalog fail.
      }
    }
    return List.unmodifiable(items);
  }

  Future<String> loadReadableText(LibraryCatalogItem item) async {
    final inline = item.content?.trim();
    if (inline != null && inline.isNotEmpty) return inline;

    final contentUrl = item.contentUrl;
    if (contentUrl == null) {
      throw const LibraryAddonException(
        'This item does not expose readable text or a content URL.',
      );
    }

    final uri = Uri.parse(contentUrl);
    final contentType = item.raw['contentType']?.toString().toLowerCase() ?? '';
    if (contentType.contains('application/epub+zip') ||
        uri.path.toLowerCase().endsWith('.epub')) {
      return _loadEpubText(uri);
    }

    final response = await _get(
      uri,
      maxBytes: _maxReaderBytes,
      accept: 'application/json, text/plain, text/markdown, text/html',
    );
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);

    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        for (final key in const ['content', 'text', 'body', 'markdown']) {
          final value = decoded[key]?.toString();
          if (value != null && value.trim().isNotEmpty) return value;
        }
      }
    } catch (_) {
      // Plain text/Markdown/HTML is supported below.
    }

    final text = _markupToText(body);
    if (text.isEmpty) {
      throw const LibraryAddonException('Reader response is empty.');
    }
    return text;
  }

  Future<String> loadReadableFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw const LibraryAddonException(
        'Downloaded Library file no longer exists.',
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw const LibraryAddonException('Downloaded Library file is empty.');
    }
    if (bytes.length > _maxReaderBytes) {
      throw const LibraryAddonException(
        'This downloaded item is too large for the integrated text reader.',
      );
    }

    final extension = path.extension(file.path).toLowerCase();
    if (extension == '.epub') {
      return _decodeEpubText(bytes);
    }
    if (extension == '.txt' ||
        extension == '.md' ||
        extension == '.html' ||
        extension == '.htm' ||
        extension == '.xhtml') {
      final body = utf8.decode(bytes, allowMalformed: true);
      final text = _markupToText(body);
      if (text.isNotEmpty) return text;
    }
    throw const LibraryAddonException(
      'This downloaded format is not supported by the integrated text reader.',
    );
  }

  static List<LibraryCatalogItem> parseGallicaOpdsDocument(
    String rawXml, {
    required Uri baseUri,
  }) {
    XmlDocument document;
    try {
      document = XmlDocument.parse(rawXml);
    } catch (_) {
      throw const LibraryAddonException(
        'Gallica did not return a valid OPDS/Atom catalog.',
      );
    }

    final items = <LibraryCatalogItem>[];
    for (final entry in document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'entry',
    )) {
      final title = _directChildText(entry, 'title');
      if (title.isEmpty) continue;

      String author = '';
      final authorElement = entry.children
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'author')
          .firstOrNull;
      if (authorElement != null) {
        author = _directChildText(authorElement, 'name');
      }
      if (author.isEmpty) {
        author = _directChildText(entry, 'creator');
      }

      final id = _directChildText(entry, 'id');
      final summary = _directChildText(entry, 'summary').isNotEmpty
          ? _directChildText(entry, 'summary')
          : _directChildText(entry, 'content');

      String? acquisitionUrl;
      String? coverUrl;
      for (final link in entry.children.whereType<XmlElement>().where(
        (element) => element.name.local == 'link',
      )) {
        final rel = link.getAttribute('rel')?.trim() ?? '';
        final type = link.getAttribute('type')?.trim().toLowerCase() ?? '';
        final href = link.getAttribute('href')?.trim() ?? '';
        if (href.isEmpty) continue;

        final resolved = _safeHttpsUrl(baseUri, href);
        if (resolved == null) continue;

        if (rel == 'http://opds-spec.org/acquisition' &&
            type.contains('application/epub+zip')) {
          acquisitionUrl ??= resolved;
        }
        if (rel == 'http://opds-spec.org/image' ||
            rel == 'http://opds-spec.org/image/thumbnail' ||
            type.startsWith('image/')) {
          coverUrl ??= resolved;
        }
      }

      if (acquisitionUrl == null) {
        continue;
      }

      items.add(
        LibraryCatalogItem(
          id: id.isEmpty ? acquisitionUrl : id,
          title: title,
          mediaType: LibraryMediaType.book,
          subtitle: author,
          description: _normalizeWhitespace(summary),
          coverUrl: coverUrl,
          content: null,
          contentUrl: acquisitionUrl,
          pageUrls: const [],
          raw: Map<String, dynamic>.unmodifiable(<String, dynamic>{
            'provider': LibraryAddon.gallicaProviderType,
            'contentType': 'application/epub+zip',
            'acquisitionUrl': acquisitionUrl,
          }),
        ),
      );
    }

    return List.unmodifiable(items);
  }

  Future<String> _loadEpubText(Uri uri) async {
    final response = await _get(
      uri,
      maxBytes: _maxReaderBytes,
      accept: 'application/epub+zip, application/octet-stream',
    );
    return _decodeEpubText(response.bodyBytes);
  }

  static String _decodeEpubText(List<int> bytes) {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const LibraryAddonException('Unable to open this EPUB.');
    }

    final files = <String, ArchiveFile>{};
    for (final file in archive) {
      if (!file.isFile) continue;
      files[_normalizeArchivePath(file.name)] = file;
    }

    final readingOrder = _epubReadingOrder(files);
    if (readingOrder.isEmpty) {
      throw const LibraryAddonException(
        'The EPUB contains no readable XHTML/HTML pages.',
      );
    }

    final sections = <String>[];
    for (final file in readingOrder.take(400)) {
      try {
        final content = file.content as List<int>;
        final markup = utf8.decode(content, allowMalformed: true);
        final text = _markupToText(markup);
        if (text.isNotEmpty) sections.add(text);
      } catch (_) {
        // Skip one corrupt chapter and keep the rest of the book readable.
      }
    }

    final result = sections.join('\n\n').trim();
    if (result.isEmpty) {
      throw const LibraryAddonException('The EPUB contains no readable text.');
    }
    return result;
  }

  static List<ArchiveFile> _epubReadingOrder(Map<String, ArchiveFile> files) {
    final fallback = files.entries.where((entry) {
      final name = entry.key.toLowerCase();
      return name.endsWith('.xhtml') ||
          name.endsWith('.html') ||
          name.endsWith('.htm');
    }).toList()..sort((a, b) => a.key.compareTo(b.key));

    try {
      final containerFile = files['META-INF/container.xml'];
      if (containerFile == null) {
        return fallback.map((entry) => entry.value).toList();
      }
      final containerXml = utf8.decode(
        containerFile.content as List<int>,
        allowMalformed: true,
      );
      final container = XmlDocument.parse(containerXml);
      final rootfile = container.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'rootfile')
          .firstOrNull;
      final opfPath = rootfile?.getAttribute('full-path')?.trim();
      if (opfPath == null || opfPath.isEmpty) {
        return fallback.map((entry) => entry.value).toList();
      }

      final normalizedOpfPath = _normalizeArchivePath(opfPath);
      final opfFile = files[normalizedOpfPath];
      if (opfFile == null) {
        return fallback.map((entry) => entry.value).toList();
      }

      final opfXml = utf8.decode(
        opfFile.content as List<int>,
        allowMalformed: true,
      );
      final opf = XmlDocument.parse(opfXml);
      final manifest = <String, String>{};
      for (final item in opf.descendants.whereType<XmlElement>().where(
        (element) => element.name.local == 'item',
      )) {
        final id = item.getAttribute('id')?.trim() ?? '';
        final href = item.getAttribute('href')?.trim() ?? '';
        final mediaType = item.getAttribute('media-type')?.trim() ?? '';
        if (id.isEmpty || href.isEmpty) continue;
        if (mediaType.contains('html') ||
            href.toLowerCase().endsWith('.xhtml') ||
            href.toLowerCase().endsWith('.html') ||
            href.toLowerCase().endsWith('.htm')) {
          manifest[id] = href;
        }
      }

      final baseDir = path.posix.dirname(normalizedOpfPath);
      final ordered = <ArchiveFile>[];
      final seen = <String>{};
      for (final itemRef in opf.descendants.whereType<XmlElement>().where(
        (element) => element.name.local == 'itemref',
      )) {
        final idRef = itemRef.getAttribute('idref')?.trim() ?? '';
        final href = manifest[idRef];
        if (href == null) continue;
        final fullPath = _normalizeArchivePath(
          path.posix.join(baseDir == '.' ? '' : baseDir, href),
        );
        final file = files[fullPath];
        if (file != null && seen.add(fullPath)) ordered.add(file);
      }

      if (ordered.isNotEmpty) return ordered;
    } catch (_) {
      // Fall back to sorted HTML/XHTML files for malformed EPUB metadata.
    }

    return fallback.map((entry) => entry.value).toList();
  }

  static String _markupToText(String markup) {
    final trimmed = markup.trim();
    if (trimmed.isEmpty) return '';

    try {
      final document = XmlDocument.parse(trimmed);
      XmlNode root = document;
      final body = document.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'body')
          .firstOrNull;
      if (body != null) root = body;

      final buffer = StringBuffer();
      for (final node in root.descendants) {
        if (node is XmlText) {
          final value = _normalizeWhitespace(node.value);
          if (value.isNotEmpty) {
            if (buffer.isNotEmpty) buffer.write(' ');
            buffer.write(value);
          }
        } else if (node is XmlElement) {
          final tag = node.name.local.toLowerCase();
          if (const {
            'p',
            'div',
            'br',
            'h1',
            'h2',
            'h3',
            'h4',
            'h5',
            'h6',
            'li',
            'blockquote',
          }.contains(tag)) {
            buffer.write('\n');
          }
        }
      }
      return buffer
          .toString()
          .replaceAll(RegExp(r'[ \t]+\n'), '\n')
          .replaceAll(RegExp(r'\n[ \t]+'), '\n')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();
    } catch (_) {
      return _normalizeWhitespace(
        trimmed
            .replaceAll(
              RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
              ' ',
            )
            .replaceAll(
              RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
              ' ',
            )
            .replaceAll(RegExp(r'<[^>]+>'), ' '),
      );
    }
  }

  static String _directChildText(XmlElement element, String localName) {
    for (final child in element.children.whereType<XmlElement>()) {
      if (child.name.local == localName) {
        return child.innerText.trim();
      }
    }
    return '';
  }

  static String? _safeHttpsUrl(Uri baseUri, String value) {
    final parsed = Uri.tryParse(value);
    if (parsed == null) return null;
    var resolved = parsed.hasScheme ? parsed : baseUri.resolveUri(parsed);
    if (resolved.scheme == 'http' &&
        resolved.host.toLowerCase() == 'gallica.bnf.fr') {
      resolved = resolved.replace(scheme: 'https');
    }
    if (resolved.scheme != 'https' || resolved.host.isEmpty) return null;
    return resolved.toString();
  }

  static String _normalizeArchivePath(String value) {
    final normalized = path.posix.normalize(value.replaceAll('\\', '/'));
    return normalized.startsWith('./') ? normalized.substring(2) : normalized;
  }

  static String _normalizeWhitespace(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  static List<dynamic> _extractItems(dynamic decoded) {
    if (decoded is List) return decoded;
    if (decoded is Map) {
      for (final key in const ['items', 'results', 'entries']) {
        final value = decoded[key];
        if (value is List) return value;
      }
      final data = decoded['data'];
      if (data is List) return data;
      if (data is Map) {
        for (final key in const ['items', 'results', 'entries']) {
          final value = data[key];
          if (value is List) return value;
        }
      }
    }
    throw const LibraryAddonException(
      'Catalog JSON must be a list or contain an items/results/entries list.',
    );
  }

  static Uri _resolveHttps(Uri base, String value, {required String field}) {
    final candidate = Uri.tryParse(value.trim());
    if (candidate == null) {
      throw LibraryAddonException('$field is not a valid URL.');
    }
    final resolved = candidate.hasScheme
        ? candidate
        : base.resolveUri(candidate);
    if (resolved.scheme != 'https' || resolved.host.isEmpty) {
      throw LibraryAddonException('$field must resolve to HTTPS.');
    }
    return resolved;
  }

  static Future<http.Response> _get(
    Uri uri, {
    required int maxBytes,
    String accept = 'application/json, text/plain',
  }) async {
    http.Response response;
    try {
      response = await http
          .get(uri, headers: <String, String>{'Accept': accept})
          .timeout(_timeout);
    } catch (error) {
      throw LibraryAddonException('Unable to load ${uri.host}: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LibraryAddonException(
        '${uri.host} returned HTTP ${response.statusCode}.',
      );
    }
    if (response.bodyBytes.length > maxBytes) {
      throw const LibraryAddonException('Library response is too large.');
    }
    return response;
  }
}

extension _FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}
