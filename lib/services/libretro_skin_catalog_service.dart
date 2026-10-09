import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'libretro_core_catalog.dart';
import 'libretro_internal_service.dart';
import 'libretro_skin_service.dart';
import 'logger_service.dart';

/// One skin listed by the Provenance skin catalog. The catalog only links
/// to files hosted by their authors; nothing is downloaded until the user
/// installs an entry.
class LibretroSkinCatalogEntry {
  const LibretroSkinCatalogEntry({
    required this.id,
    required this.name,
    this.author,
    this.systems = const <String>[],
    this.gameTypeIdentifier,
    required this.downloadURL,
    this.thumbnailURL,
    this.downloadCount,
    this.source,
    this.description,
  });

  final String id;
  final String name;
  final String? author;

  /// Catalog system codes as published ("gbc", "genesis", "threeDS"...).
  final List<String> systems;
  final String? gameTypeIdentifier;
  final String downloadURL;
  final String? thumbnailURL;
  final int? downloadCount;

  /// Where the catalog found the skin (a site or a repository).
  final String? source;
  final String? description;

  /// Null when the entry lacks an id, a name or a download link.
  static LibretroSkinCatalogEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _optionalText(json['id']);
    final name = _optionalText(json['name']);
    final downloadURL = _optionalText(json['downloadURL']);
    if (id == null || name == null || downloadURL == null) return null;
    final systems = json['systems'];
    final downloads = json['downloadCount'];
    return LibretroSkinCatalogEntry(
      id: id,
      name: name,
      author: _optionalText(json['author']),
      systems: systems is List ? <String>[for (final code in systems) if (code is String) code] : const <String>[],
      gameTypeIdentifier: _optionalText(json['gameTypeIdentifier']),
      downloadURL: downloadURL,
      thumbnailURL: _optionalText(json['thumbnailURL']),
      downloadCount: downloads is num ? downloads.toInt() : null,
      source: _optionalText(json['source']),
      description: _optionalText(json['description']),
    );
  }

  /// NeoStation consoles this entry is listed for.
  List<String> get consoles => <String>[
        for (final console in LibretroCoreCatalog.consoles.values)
          if (isForConsole(console.id)) console.id,
      ];

  bool isForConsole(String console) {
    final codes = LibretroCoreCatalog.consoles[console]?.catalogSystems ?? const <String>[];
    return systems.any((code) => codes.contains(code.toLowerCase()));
  }

  /// HTTPS link to fetch. Some published links contain a raw '#' or space
  /// that belongs to the file name.
  Uri? get downloadUri {
    final uri = Uri.tryParse(downloadURL.trim().replaceAll('#', '%23').replaceAll(' ', '%20'));
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty ? uri : null;
  }

  /// True when the link points at a skin file (or at a Google Drive direct
  /// download) rather than at a store or web page.
  bool get isDirectDownload {
    final uri = downloadUri;
    if (uri == null) return false;
    final file = uri.path.toLowerCase();
    if (file.endsWith('.deltaskin') || file.endsWith('.manicskin') || file.endsWith('.zip')) return true;
    return uri.host == 'drive.google.com' && uri.path == '/uc' && uri.queryParameters['export'] == 'download';
  }
}

/// The Provenance skin catalog (`catalog.json`), cached for 24 hours in
/// `Caches/Libretro/skin-catalog.json`, and the download of its entries
/// into [LibretroSkinService].
class LibretroSkinCatalogService {
  LibretroSkinCatalogService({
    required this.cacheDirectory,
    required this.skins,
    http.Client? client,
    DateTime Function()? clock,
    this.maxDownloadBytes = LibretroSkinService.maxArchiveBytes,
    this.downloadIdleTimeout = requestTimeout,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _clock = clock ?? DateTime.now;

  static Future<LibretroSkinCatalogService> create({http.Client? client}) async => LibretroSkinCatalogService(
        cacheDirectory: (await LibretroInternalService.cacheDirectory()).path,
        skins: await LibretroSkinService.create(),
        client: client,
      );

  static final _log = LoggerService.instance;

  static const String catalogUrl = 'https://provenance-emu.com/skins/catalog.json';
  static const String fallbackCatalogUrl =
      'https://raw.githubusercontent.com/Provenance-Emu/skins/main/catalog.json';
  static const Duration cacheLifetime = Duration(hours: 24);
  static const Duration requestTimeout = Duration(seconds: 30);
  static const String cacheFileName = 'skin-catalog.json';
  static const String downloadsFolderName = 'SkinDownloads';

  /// Caches/Libretro.
  final String cacheDirectory;
  final LibretroSkinService skins;
  final int maxDownloadBytes;

  /// Longest wait for the next part of a download body once the response
  /// has started: a body that stops arriving (stalled host, lost mobile
  /// connection) fails instead of keeping the entry installing forever.
  final Duration downloadIdleTimeout;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _clock;

  File get _cacheFile => File(path.join(cacheDirectory, cacheFileName));

  /// Catalog entries: the cached copy while younger than [cacheLifetime]
  /// (unless [refresh]), else a fresh download (provenance-emu.com, then
  /// GitHub), else the older cached copy. Null when none can be read.
  Future<List<LibretroSkinCatalogEntry>?> load({bool refresh = false}) async {
    if (!refresh) {
      final cached = await _readCache(maxAge: cacheLifetime);
      if (cached != null) return cached;
    }
    for (final url in const <String>[catalogUrl, fallbackCatalogUrl]) {
      try {
        final response = await _client.get(Uri.parse(url)).timeout(requestTimeout);
        if (response.statusCode != 200) {
          _log.w('Skin catalog $url answered HTTP ${response.statusCode}');
          continue;
        }
        final body = utf8.decode(response.bodyBytes);
        final entries = parse(body);
        await _writeCache(body);
        return entries;
      } catch (error) {
        _log.w('Skin catalog $url unavailable: $error');
      }
    }
    return _readCache();
  }

  /// Entries of a `catalog.json` body ({"skins": [...]}); entries without an
  /// id, a name or a download link are skipped.
  static List<LibretroSkinCatalogEntry> parse(String body) {
    final json = jsonDecode(body);
    final skins = json is Map ? json['skins'] : json;
    if (skins is! List) throw const FormatException('The skin catalog has no skin list.');
    return skins.map(LibretroSkinCatalogEntry.fromJson).whereType<LibretroSkinCatalogEntry>().toList();
  }

  static List<LibretroSkinCatalogEntry> forConsole(Iterable<LibretroSkinCatalogEntry> entries, String console) =>
      entries.where((entry) => entry.isForConsole(console)).toList();

  /// Case-insensitive search in names and authors.
  static List<LibretroSkinCatalogEntry> search(Iterable<LibretroSkinCatalogEntry> entries, String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return entries.toList();
    return entries
        .where((entry) =>
            entry.name.toLowerCase().contains(needle) || (entry.author?.toLowerCase().contains(needle) ?? false))
        .toList();
  }

  /// Downloads an entry (at most [maxDownloadBytes]) and installs it with
  /// its download link as source and the catalog author.
  Future<LibretroSkinImportResult> download(LibretroSkinCatalogEntry entry) async {
    final uri = entry.downloadUri;
    if (uri == null || !entry.isDirectDownload) {
      return const LibretroSkinImportFailed(LibretroSkinMessages.notDirect);
    }
    final folder = Directory(path.join(cacheDirectory, downloadsFolderName));
    final file = File(path.join(folder.path, '${_randomName()}.download'));
    try {
      await folder.create(recursive: true);
      final refusal = await _fetch(uri, file);
      if (refusal != null) return refusal;
      return await skins.importFromFile(file.path, source: entry.downloadURL, author: entry.author);
    } catch (error) {
      _log.w('Skin download failed for ${entry.downloadURL}: $error');
      return LibretroSkinImportFailed(LibretroSkinMessages.download, technicalDetails: '$error');
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (error) {
        _log.w('Skin download not removed ${file.path}: $error');
      }
    }
  }

  /// Closes the HTTP client this service created.
  void dispose() {
    if (_ownsClient) _client.close();
  }

  Future<LibretroSkinImportFailed?> _fetch(Uri uri, File file) async {
    final tooLarge = LibretroSkinImportFailed(
      LibretroSkinMessages.tooLarge,
      parameters: <String, Object>{'limit': maxDownloadBytes ~/ (1024 * 1024)},
    );
    final response = await _client.send(http.Request('GET', uri)).timeout(requestTimeout);
    // A body that will not be used is not read (an error page or an
    // oversized file could also stall or run long): its subscription is
    // cancelled, which closes the connection.
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      return LibretroSkinImportFailed(
        LibretroSkinMessages.download,
        technicalDetails: 'HTTP ${response.statusCode} ${uri.host}',
      );
    }
    final declared = response.contentLength;
    if (declared != null && declared > maxDownloadBytes) {
      await response.stream.listen(null).cancel();
      return tooLarge;
    }
    // Inactivity limit between two parts of the body: leaving the loop on
    // the timeout error cancels the HTTP subscription, and download() reports
    // the failure and removes the partial file.
    final body = response.stream.timeout(
      downloadIdleTimeout,
      onTimeout: (events) {
        events.addError(TimeoutException('Skin download stalled', downloadIdleTimeout));
        events.close();
      },
    );
    final sink = file.openWrite();
    final head = <int>[];
    var received = 0;
    try {
      await for (final chunk in body) {
        received += chunk.length;
        if (received > maxDownloadBytes) return tooLarge;
        if (head.length < 4) {
          head.addAll(chunk.take(4 - head.length));
          if (head.length == 4 && !LibretroSkinService.isZipSignature(head)) {
            return const LibretroSkinImportFailed(LibretroSkinMessages.notArchive);
          }
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    if (!LibretroSkinService.isZipSignature(head)) {
      return const LibretroSkinImportFailed(LibretroSkinMessages.notArchive);
    }
    return null;
  }

  Future<List<LibretroSkinCatalogEntry>?> _readCache({Duration? maxAge}) async {
    try {
      final file = _cacheFile;
      if (!await file.exists()) return null;
      if (maxAge != null && _clock().difference(await file.lastModified()) > maxAge) return null;
      return parse(await file.readAsString());
    } catch (error) {
      _log.w('Skin catalog cache unreadable: $error');
      return null;
    }
  }

  Future<void> _writeCache(String body) async {
    try {
      final file = _cacheFile;
      await file.parent.create(recursive: true);
      final partial = File('${file.path}.part');
      await partial.writeAsString(body, flush: true);
      await partial.rename(file.path);
    } catch (error) {
      _log.w('Skin catalog cache not written: $error');
    }
  }

  static String _randomName() {
    final random = Random.secure();
    return List<String>.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

String? _optionalText(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;
