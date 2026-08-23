import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LibrarySourceKind { catalog, localLibrary, metadataOnly }

class LibraryAddon {
  const LibraryAddon({
    required this.id,
    required this.name,
    required this.version,
    required this.baseUrl,
    required this.description,
    required this.iconUrl,
    required this.origin,
    required this.installedAt,
    required this.manifest,
  });

  static const String schemaV1 = 'neostation.library.v1';
  static const String tachiyomiProviderType = 'tachiyomi-extension-repository';
  static const String aidokuProviderType = 'aidoku-source-repository';
  static const String gallicaProviderType = 'gallica-opds';

  final String id;
  final String name;
  final String version;
  final String? baseUrl;
  final String description;
  final String? iconUrl;
  final String origin;
  final DateTime installedAt;
  final Map<String, dynamic> manifest;

  bool get isTachiyomiRepositorySource {
    final provider = manifest['provider'];
    return provider is Map && provider['type'] == tachiyomiProviderType;
  }

  bool get isAidokuRepositorySource {
    final provider = manifest['provider'];
    return provider is Map && provider['type'] == aidokuProviderType;
  }

  bool get isRepositorySource =>
      isTachiyomiRepositorySource || isAidokuRepositorySource;

  String get repositoryOrigin {
    final provider = manifest['provider'];
    if (provider is Map) {
      final value = provider['repositoryOrigin']?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return origin;
  }

  String? get sourceDownloadUrl {
    final provider = manifest['provider'];
    if (provider is Map) {
      final value = provider['downloadUrl']?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  bool get isGallicaSource {
    final provider = manifest['provider'];
    return provider is Map && provider['type'] == gallicaProviderType;
  }

  bool get isBuiltIn => manifest['builtIn'] == true;

  String? get language {
    final provider = manifest['provider'];
    if (provider is Map) {
      final value = provider['sourceLang']?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  String? get androidPackage {
    final provider = manifest['provider'];
    if (provider is Map) {
      final value = provider['package']?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  String? get androidApk {
    final provider = manifest['provider'];
    if (provider is Map) {
      final value = provider['apk']?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  bool get isMetadataOnlyOnIos =>
      manifest['iosCompatibility']?.toString() == 'metadata-only';

  bool get isRepositoryDeprecationStub {
    final package = androidPackage;
    return package == 'eu.kanade.tachiyomi.extension.all.keiyoushi' ||
        package == 'eu.kanade.tachiyomi.extension.all.mihon';
  }

  String? get minimumAppVersion {
    final value = manifest['minAppVersion']?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  LibrarySourceKind get sourceKind {
    if (isMetadataOnlyOnIos) return LibrarySourceKind.metadataOnly;
    final raw = (manifest['sourceType'] ?? manifest['kind'])
        ?.toString()
        .trim()
        .toLowerCase();
    if (raw == 'local' ||
        raw == 'local-library' ||
        raw == 'local_library' ||
        raw == 'locallibrary') {
      return LibrarySourceKind.localLibrary;
    }
    return LibrarySourceKind.catalog;
  }

  bool get canBrowseOnIos =>
      sourceKind == LibrarySourceKind.catalog && catalogEndpoint != null;

  String? get catalogEndpoint {
    final endpoints = manifest['endpoints'];
    if (endpoints is! Map) return null;
    for (final key in const ['catalog', 'browse']) {
      final value = endpoints[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  String? get searchEndpoint {
    final endpoints = manifest['endpoints'];
    if (endpoints is! Map) return null;
    final value = endpoints['search']?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  factory LibraryAddon.fromManifest(
    Map<String, dynamic> manifest, {
    required String origin,
    DateTime? installedAt,
  }) {
    String requiredString(String key) {
      final value = manifest[key]?.toString().trim() ?? '';
      if (value.isEmpty) {
        throw LibraryAddonException('Missing required manifest field: $key');
      }
      return value;
    }

    final schema = requiredString('schema');
    if (schema != schemaV1) {
      throw LibraryAddonException(
        'Unsupported manifest schema "$schema". Expected $schemaV1.',
      );
    }

    final id = requiredString('id');
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{1,99}$').hasMatch(id)) {
      throw LibraryAddonException('Invalid add-on id: $id');
    }

    final name = requiredString('name');
    final version = requiredString('version');
    final rawKind = (manifest['sourceType'] ?? manifest['kind'])
        ?.toString()
        .trim()
        .toLowerCase();
    final isLocal =
        rawKind == 'local' ||
        rawKind == 'local-library' ||
        rawKind == 'local_library' ||
        rawKind == 'locallibrary';

    final baseUrlValue = manifest['baseUrl']?.toString().trim();
    final baseUrl = baseUrlValue == null || baseUrlValue.isEmpty
        ? null
        : baseUrlValue;
    if (!isLocal && baseUrl == null) {
      throw const LibraryAddonException(
        'Missing required manifest field: baseUrl',
      );
    }
    if (baseUrl != null) {
      _validateHttpsUrl(baseUrl, field: 'baseUrl');
    }

    final iconValue = manifest['icon']?.toString().trim();
    final iconUrl = iconValue == null || iconValue.isEmpty ? null : iconValue;
    if (iconUrl != null) {
      _validateHttpsUrl(iconUrl, field: 'icon');
    }

    final endpoints = manifest['endpoints'];
    if (endpoints != null && endpoints is! Map) {
      throw const LibraryAddonException(
        'Manifest field "endpoints" must be an object.',
      );
    }

    return LibraryAddon(
      id: id,
      name: name,
      version: version,
      baseUrl: baseUrl,
      description: manifest['description']?.toString().trim() ?? '',
      iconUrl: iconUrl,
      origin: origin,
      installedAt: installedAt ?? DateTime.now(),
      manifest: Map<String, dynamic>.from(manifest),
    );
  }

  static void _validateHttpsUrl(String value, {required String field}) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw LibraryAddonException('$field must be a valid HTTPS URL.');
    }
  }

  Map<String, dynamic> toJson() => {
    'origin': origin,
    'installedAt': installedAt.toIso8601String(),
    'manifest': manifest,
  };

  factory LibraryAddon.fromJson(Map<String, dynamic> value) {
    final rawManifest = value['manifest'];
    if (rawManifest is! Map) {
      throw const LibraryAddonException('Stored add-on manifest is invalid.');
    }
    return LibraryAddon.fromManifest(
      Map<String, dynamic>.from(rawManifest),
      origin: value['origin']?.toString() ?? 'local',
      installedAt: DateTime.tryParse(value['installedAt']?.toString() ?? ''),
    );
  }
}

enum LibraryAddonDocumentFormat {
  neoStationManifest,
  tachiyomiRepository,
  aidokuRepository,
}

class LibraryAddonInstallResult {
  const LibraryAddonInstallResult({required this.addon, required this.updated});

  final LibraryAddon addon;
  final bool updated;
}

class LibraryAddonBatchInstallResult {
  const LibraryAddonBatchInstallResult({
    required this.addons,
    required this.addedCount,
    required this.updatedCount,
    required this.format,
  });

  final List<LibraryAddon> addons;
  final int addedCount;
  final int updatedCount;
  final LibraryAddonDocumentFormat format;

  int get totalCount => addons.length;
}

class LibraryAddonException implements Exception {
  const LibraryAddonException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LibraryAddonService {
  LibraryAddonService._();

  static final LibraryAddonService instance = LibraryAddonService._();

  static const String _prefsKey = 'neostation_library_addons_v1';

  static const int _maxDocumentBytes = 20 * 1024 * 1024;
  static const int _maxRepositorySources = 10000;

  final List<LibraryAddon> _addons = [];
  bool _loaded = false;

  List<LibraryAddon> get addons => List.unmodifiable(_addons);

  Future<List<LibraryAddon>> load() async {
    if (_loaded) return addons;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    _addons.clear();
    var needsPersist = false;

    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            try {
              final addon = LibraryAddon.fromJson(
                Map<String, dynamic>.from(item),
              );
              if (addon.isBuiltIn || addon.origin.startsWith('builtin:')) {
                // Migration from older builds: bundled Library sources are
                // removed. Every visible source must now come from an import.
                needsPersist = true;
                continue;
              }
              if (addon.isRepositoryDeprecationStub) {
                needsPersist = true;
                continue;
              }
              _addons.add(addon);
            } catch (_) {
              // Ignore one obsolete or corrupt stored source.
            }
          }
        }
      } catch (_) {
        // Keep a clean list when stored preferences are malformed.
      }
    }

    _sortAddons();
    _loaded = true;
    if (needsPersist) await _persist();
    return addons;
  }

  Future<LibraryAddonBatchInstallResult> installDocumentFromUrl(
    String documentUrl,
  ) async {
    final uri = Uri.tryParse(documentUrl.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const LibraryAddonException('Repository URL must use HTTPS.');
    }

    LibraryAddonException? lastError;
    for (final candidate in _repositoryCandidates(uri)) {
      try {
        var effectiveUri = candidate;
        var response = await _downloadRepository(candidate);

        if (_looksLikeKeiyoushiDeprecationStub(response.bodyBytes) &&
            candidate.path.endsWith('/index.min.json')) {
          final fullPath =
              candidate.path.substring(
                0,
                candidate.path.length - 'index.min.json'.length,
              ) +
              'index.json';
          final fullUri = candidate.replace(path: fullPath);
          try {
            final fullResponse = await _downloadRepository(fullUri);
            if (!_looksLikeKeiyoushiDeprecationStub(fullResponse.bodyBytes)) {
              effectiveUri = fullUri;
              response = fullResponse;
            }
          } on LibraryAddonException {
            // Keep the minified response if the full index is unavailable.
          }
        }

        return await installDocumentFromJson(
          utf8.decode(response.bodyBytes),
          origin: effectiveUri.toString(),
        );
      } on LibraryAddonException catch (error) {
        lastError = error;
      } on FormatException catch (error) {
        lastError = LibraryAddonException(
          'Invalid repository document: $error',
        );
      }
    }

    throw lastError ??
        const LibraryAddonException('Unable to resolve this repository URL.');
  }

  static List<Uri> _repositoryCandidates(Uri original) {
    final values = <String>[];

    void add(String value) {
      final parsed = Uri.tryParse(value);
      if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty) {
        return;
      }
      if (!values.contains(parsed.toString())) values.add(parsed.toString());
    }

    add(original.toString());
    final host = original.host.toLowerCase();
    final lowerPath = original.path.toLowerCase();

    // Old repositories that moved or were archived. Keep accepting the URLs
    // users already have in their source lists and transparently resolve them.
    if ((host == 'raw.githubusercontent.com' || host == 'github.com') &&
        lowerPath.contains('/almightyhak/aniyomi-anime-repo')) {
      add(
        'https://raw.githubusercontent.com/aniyomi-addons/anime-extensions-repo/repo/index.min.json',
      );
      add(
        'https://raw.githubusercontent.com/aniyomi-addons/anime-extensions-repo/repo/index.json',
      );
    }
    if ((host == 'raw.githubusercontent.com' || host == 'github.com') &&
        lowerPath.contains('/komikku-app/extensions')) {
      add(
        'https://raw.githubusercontent.com/yuzono/manga-repo/repo/index.min.json',
      );
    }
    if ((host == 'raw.githubusercontent.com' || host == 'github.com') &&
        lowerPath.contains('/thepbone/tachiyomi-extensions-revived')) {
      add(
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json',
      );
      add(
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.json',
      );
    }
    if ((host == 'raw.githubusercontent.com' || host == 'github.com') &&
        lowerPath.contains('/moomooo95/aidoku-french-sources')) {
      add(
        'https://raw.githubusercontent.com/Moomooo95/aidoku-french-sources/gh-pages/index.min.json',
      );
      add(
        'https://raw.githubusercontent.com/Moomooo95/aidoku-french-sources/gh-pages/index.json',
      );
    }

    // Accept a plain GitHub repository URL. Common source-repository branches
    // are tried in order, so users do not need to know the raw index URL.
    if (host == 'github.com' && original.pathSegments.length >= 2) {
      final owner = original.pathSegments[0];
      final repo = original.pathSegments[1].replaceFirst(RegExp(r'\.git$'), '');
      for (final branch in const ['repo', 'gh-pages', 'main', 'master']) {
        add(
          'https://raw.githubusercontent.com/$owner/$repo/$branch/index.min.json',
        );
        add(
          'https://raw.githubusercontent.com/$owner/$repo/$branch/index.json',
        );
      }
    }

    return values.map(Uri.parse).toList(growable: false);
  }

  Future<http.Response> _downloadRepository(Uri uri) async {
    http.Response response;
    try {
      response = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
    } catch (error) {
      throw LibraryAddonException('Unable to download repository: $error');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LibraryAddonException(
        'Repository server returned HTTP ${response.statusCode}.',
      );
    }
    if (response.bodyBytes.length > _maxDocumentBytes) {
      throw const LibraryAddonException('Repository is larger than 20 MB.');
    }
    return response;
  }

  static bool _looksLikeKeiyoushiDeprecationStub(List<int> bytes) {
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return false;
    }
    if (decoded is! List || decoded.length > 4) return false;

    final packages = <String>{};
    for (final rawEntry in decoded) {
      if (rawEntry is! Map) continue;
      final package = rawEntry['pkg']?.toString().trim();
      if (package != null && package.isNotEmpty) packages.add(package);
    }
    return packages.contains('eu.kanade.tachiyomi.extension.all.keiyoushi') &&
        packages.contains('eu.kanade.tachiyomi.extension.all.mihon');
  }

  Future<LibraryAddonBatchInstallResult> installDocumentFromJson(
    String rawJson, {
    required String origin,
  }) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(rawJson);
    } catch (_) {
      throw const LibraryAddonException('Document is not valid JSON.');
    }

    if (decoded is Map) {
      final object = Map<String, dynamic>.from(decoded);
      object.remove('builtIn');
      final aidokuEntries = _extractAidokuEntries(object);
      if (aidokuEntries != null) {
        final parsed = _parseAidokuRepository(aidokuEntries, origin: origin);
        return _upsertMany(
          parsed,
          format: LibraryAddonDocumentFormat.aidokuRepository,
        );
      }

      final modernEntries = _extractModernKeiyoushiEntries(object);
      if (modernEntries != null) {
        final parsed = _parseTachiyomiRepository(modernEntries, origin: origin);
        return _upsertMany(
          parsed,
          format: LibraryAddonDocumentFormat.tachiyomiRepository,
        );
      }

      _rejectKnownExternalManifest(object);
      final addon = LibraryAddon.fromManifest(object, origin: origin);
      await _validateMinimumAppVersion(addon);
      return _upsertMany([
        addon,
      ], format: LibraryAddonDocumentFormat.neoStationManifest);
    }

    if (decoded is List) {
      if (_looksLikeAidokuEntries(decoded)) {
        final parsed = _parseAidokuRepository(decoded, origin: origin);
        return _upsertMany(
          parsed,
          format: LibraryAddonDocumentFormat.aidokuRepository,
        );
      }
      final parsed = _parseTachiyomiRepository(decoded, origin: origin);
      return _upsertMany(
        parsed,
        format: LibraryAddonDocumentFormat.tachiyomiRepository,
      );
    }

    throw const LibraryAddonException(
      'Document root must be a NeoStation manifest or a supported Tachiyomi/Mihon repository.',
    );
  }

  static List<dynamic>? _extractAidokuEntries(Map<String, dynamic> document) {
    final sources = document['sources'];
    if (sources is List && _looksLikeAidokuEntries(sources)) return sources;
    return null;
  }

  static bool _looksLikeAidokuEntries(List<dynamic> entries) {
    var matches = 0;
    for (final raw in entries) {
      if (raw is! Map) continue;
      final entry = Map<String, dynamic>.from(raw);
      final id = entry['id']?.toString().trim() ?? '';
      final name = entry['name']?.toString().trim() ?? '';
      final hasPackage =
          (entry['file']?.toString().trim().isNotEmpty ?? false) ||
          (entry['downloadURL']?.toString().trim().isNotEmpty ?? false) ||
          (entry['downloadUrl']?.toString().trim().isNotEmpty ?? false);
      if (id.isNotEmpty &&
          name.isNotEmpty &&
          hasPackage &&
          !entry.containsKey('pkg')) {
        matches++;
      }
    }
    return matches > 0;
  }

  List<LibraryAddon> _parseAidokuRepository(
    List<dynamic> entries, {
    required String origin,
  }) {
    final originUri = Uri.tryParse(origin);
    if (originUri == null ||
        originUri.scheme != 'https' ||
        originUri.host.isEmpty) {
      throw const LibraryAddonException(
        'Aidoku repository origin must use HTTPS.',
      );
    }

    final result = <LibraryAddon>[];
    final seenIds = <String>{};

    String? resolveOptional(dynamic raw, {String? legacyFolder}) {
      final value = raw?.toString().trim() ?? '';
      if (value.isEmpty) return null;
      final direct = Uri.tryParse(value);
      if (direct != null && direct.hasScheme) {
        if (direct.scheme != 'https' || direct.host.isEmpty) return null;
        return direct.toString();
      }
      final relative = legacyFolder == null ? value : '$legacyFolder/$value';
      final resolved = originUri.resolve(relative);
      if (resolved.scheme != 'https' || resolved.host.isEmpty) return null;
      return resolved.toString();
    }

    for (final rawEntry in entries) {
      if (rawEntry is! Map) continue;
      if (result.length >= _maxRepositorySources) {
        throw const LibraryAddonException(
          'Repository contains more than 10000 sources.',
        );
      }

      final entry = Map<String, dynamic>.from(rawEntry);
      final sourceId = entry['id']?.toString().trim() ?? '';
      final sourceName = entry['name']?.toString().trim() ?? '';
      if (sourceId.isEmpty || sourceName.isEmpty) continue;

      final version = entry['version']?.toString().trim().isNotEmpty == true
          ? entry['version'].toString().trim()
          : '0';
      final sourceLang = entry['lang']?.toString().trim().isNotEmpty == true
          ? entry['lang'].toString().trim()
          : ((entry['languages'] is List &&
                    (entry['languages'] as List).isNotEmpty)
                ? (entry['languages'] as List).first.toString()
                : 'all');
      final downloadUrl =
          resolveOptional(entry['downloadURL'] ?? entry['downloadUrl']) ??
          resolveOptional(entry['file'], legacyFolder: 'sources');
      if (downloadUrl == null) continue;
      final iconUrl =
          resolveOptional(entry['iconURL'] ?? entry['iconUrl']) ??
          resolveOptional(entry['icon'], legacyFolder: 'icons');
      final explicitBase = entry['baseURL'] ?? entry['baseUrl'];
      final parsedBase = explicitBase == null
          ? null
          : Uri.tryParse(explicitBase.toString().trim());
      final baseUrl =
          parsedBase != null &&
              parsedBase.scheme == 'https' &&
              parsedBase.host.isNotEmpty
          ? parsedBase.toString()
          : originUri.resolve('.').toString();

      final id = _aidokuAddonId(sourceId);
      if (!seenIds.add(id)) continue;
      final manifest = <String, dynamic>{
        'schema': LibraryAddon.schemaV1,
        'id': id,
        'name': sourceName,
        'version': version,
        'baseUrl': baseUrl,
        if (iconUrl != null) 'icon': iconUrl,
        'description': 'Aidoku repository source • $sourceLang',
        'iosCompatibility': 'metadata-only',
        'provider': <String, dynamic>{
          'type': LibraryAddon.aidokuProviderType,
          'sourceId': sourceId,
          'sourceLang': sourceLang,
          'downloadUrl': downloadUrl,
          'file': entry['file'],
          'nsfw': entry['nsfw'],
          'contentRating': entry['contentRating'],
          'repositoryOrigin': origin,
        },
      };
      result.add(LibraryAddon.fromManifest(manifest, origin: origin));
    }

    if (result.isEmpty) {
      throw const LibraryAddonException(
        'No installable Aidoku sources were found in this repository.',
      );
    }
    return result;
  }

  static String _aidokuAddonId(String sourceId) {
    var safe = sourceId
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (safe.length > 92) safe = safe.substring(0, 92);
    if (safe.length < 2) safe = 'source';
    return 'aidoku.$safe';
  }

  static List<dynamic>? _extractModernKeiyoushiEntries(
    Map<String, dynamic> document,
  ) {
    final extensionList = document['extensionList'];
    if (extensionList is! Map) return null;
    final extensions = extensionList['extensions'];
    if (extensions is! List) return null;

    final result = <dynamic>[];
    for (final rawExtension in extensions) {
      if (rawExtension is! Map) continue;
      final extension = Map<String, dynamic>.from(rawExtension);
      final packageName = extension['packageName']?.toString().trim() ?? '';
      if (packageName.isEmpty) continue;

      final resources = extension['resources'];
      final resourceMap = resources is Map
          ? Map<String, dynamic>.from(resources)
          : const <String, dynamic>{};
      final rawSources = extension['sources'];
      if (rawSources is! List) continue;

      final convertedSources = <Map<String, dynamic>>[];
      for (final rawSource in rawSources) {
        if (rawSource is! Map) continue;
        final source = Map<String, dynamic>.from(rawSource);
        convertedSources.add(<String, dynamic>{
          'id': source['id'],
          'name': source['name'],
          'lang': source['language'],
          'baseUrl': source['homeUrl'],
        });
      }

      result.add(<String, dynamic>{
        'name': extension['name'],
        'pkg': packageName,
        'apk': resourceMap['apkUrl'],
        'lang': convertedSources.isEmpty
            ? 'all'
            : (convertedSources.first['lang'] ?? 'all'),
        'code': extension['versionCode'],
        'version': extension['versionName'] ?? extension['extensionLib'] ?? '0',
        'nsfw':
            extension['contentWarning']?.toString() == 'CONTENT_WARNING_NSFW'
            ? 1
            : 0,
        'sources': convertedSources,
      });
    }
    return result;
  }

  Future<LibraryAddonInstallResult> installFromUrl(String manifestUrl) async {
    final batch = await installDocumentFromUrl(manifestUrl);
    if (batch.format != LibraryAddonDocumentFormat.neoStationManifest ||
        batch.addons.length != 1) {
      throw const LibraryAddonException(
        'This URL contains a repository. Use the repository import API.',
      );
    }
    return LibraryAddonInstallResult(
      addon: batch.addons.single,
      updated: batch.updatedCount == 1,
    );
  }

  Future<LibraryAddonInstallResult> installFromJson(
    String rawJson, {
    required String origin,
  }) async {
    final batch = await installDocumentFromJson(rawJson, origin: origin);
    if (batch.format != LibraryAddonDocumentFormat.neoStationManifest ||
        batch.addons.length != 1) {
      throw const LibraryAddonException(
        'This JSON contains a repository. Use the repository import API.',
      );
    }
    return LibraryAddonInstallResult(
      addon: batch.addons.single,
      updated: batch.updatedCount == 1,
    );
  }

  void _rejectKnownExternalManifest(Map<String, dynamic> manifest) {
    if (manifest.containsKey('schema')) return;

    final looksLikeObsidianPlugin =
        manifest['id'] != null &&
        manifest['name'] != null &&
        manifest['version'] != null &&
        manifest['minAppVersion'] != null &&
        (manifest['author'] != null || manifest['isDesktopOnly'] != null);

    if (looksLikeObsidianPlugin) {
      throw const LibraryAddonException(
        'This is an Obsidian plugin manifest. Its minAppVersion targets '
        'Obsidian, not NeoStation. A NeoStation source must declare '
        'schema "neostation.library.v1".',
      );
    }
  }

  Future<void> _validateMinimumAppVersion(LibraryAddon addon) async {
    final minimum = addon.minimumAppVersion;
    if (minimum == null) return;

    final requiredParts = _parseSemanticVersion(minimum);
    if (requiredParts == null) {
      throw LibraryAddonException(
        'Invalid minAppVersion "$minimum". Expected a semantic version such as 0.9.9.',
      );
    }

    final info = await PackageInfo.fromPlatform();
    final current = info.version.trim();
    final currentParts = _parseSemanticVersion(current);
    if (currentParts == null) {
      throw LibraryAddonException(
        'Unable to compare the current NeoStation version "$current".',
      );
    }

    if (_compareVersionParts(currentParts, requiredParts) < 0) {
      throw LibraryAddonException(
        'This source requires NeoStation $minimum or newer. '
        'Installed version: $current.',
      );
    }
  }

  static List<int>? _parseSemanticVersion(String value) {
    final core = value.trim().split(RegExp(r'[-+]')).first;
    if (core.isEmpty) return null;
    final result = <int>[];
    for (final piece in core.split('.')) {
      final parsed = int.tryParse(piece);
      if (parsed == null || parsed < 0) return null;
      result.add(parsed);
    }
    return result.isEmpty ? null : result;
  }

  static int _compareVersionParts(List<int> a, List<int> b) {
    final length = a.length > b.length ? a.length : b.length;
    for (var index = 0; index < length; index++) {
      final left = index < a.length ? a[index] : 0;
      final right = index < b.length ? b[index] : 0;
      if (left != right) return left.compareTo(right);
    }
    return 0;
  }

  List<LibraryAddon> _parseTachiyomiRepository(
    List<dynamic> entries, {
    required String origin,
  }) {
    final result = <LibraryAddon>[];
    final seenIds = <String>{};

    for (final rawEntry in entries) {
      if (rawEntry is! Map) continue;
      final entry = Map<String, dynamic>.from(rawEntry);
      final packageName = entry['pkg']?.toString().trim() ?? '';
      if (packageName.isEmpty || _isRepositoryDeprecationPackage(packageName)) {
        continue;
      }

      final extensionName = entry['name']?.toString().trim() ?? packageName;
      final version = entry['version']?.toString().trim().isNotEmpty == true
          ? entry['version'].toString().trim()
          : (entry['code']?.toString() ?? '0');
      final apk = entry['apk']?.toString().trim() ?? '';
      final extensionLang = entry['lang']?.toString().trim() ?? 'all';
      final code = entry['code'];
      final nsfw = entry['nsfw'];
      final rawSources = entry['sources'];
      if (rawSources is! List) continue;

      for (
        var sourceIndex = 0;
        sourceIndex < rawSources.length;
        sourceIndex++
      ) {
        if (result.length >= _maxRepositorySources) {
          throw const LibraryAddonException(
            'Repository contains more than 10000 sources.',
          );
        }

        final rawSource = rawSources[sourceIndex];
        if (rawSource is! Map) continue;
        final source = Map<String, dynamic>.from(rawSource);
        final baseUrl = source['baseUrl']?.toString().trim() ?? '';
        final uri = Uri.tryParse(baseUrl);
        if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
          continue;
        }

        final sourceId = source['id']?.toString().trim().isNotEmpty == true
            ? source['id'].toString().trim()
            : sourceIndex.toString();
        final sourceName = source['name']?.toString().trim().isNotEmpty == true
            ? source['name'].toString().trim()
            : extensionName;
        final sourceLang = source['lang']?.toString().trim().isNotEmpty == true
            ? source['lang'].toString().trim()
            : extensionLang;
        final id = _tachiyomiAddonId(packageName, sourceId);
        if (!seenIds.add(id)) continue;

        final manifest = <String, dynamic>{
          'schema': LibraryAddon.schemaV1,
          'id': id,
          'name': sourceName,
          'version': version,
          'baseUrl': baseUrl,
          'description':
              'Tachiyomi/Mihon repository source • $sourceLang • $extensionName',
          'iosCompatibility': 'metadata-only',
          'provider': <String, dynamic>{
            'type': LibraryAddon.tachiyomiProviderType,
            'package': packageName,
            'apk': apk,
            'extensionName': extensionName,
            'extensionLang': extensionLang,
            'extensionCode': code,
            'sourceId': sourceId,
            'sourceLang': sourceLang,
            'nsfw': nsfw,
            'repositoryOrigin': origin,
          },
        };

        result.add(LibraryAddon.fromManifest(manifest, origin: origin));
      }
    }

    if (result.isEmpty) {
      throw const LibraryAddonException(
        'No HTTPS Tachiyomi/Mihon sources were found in this repository.',
      );
    }
    return result;
  }

  static bool _isRepositoryDeprecationPackage(String packageName) {
    return packageName == 'eu.kanade.tachiyomi.extension.all.keiyoushi' ||
        packageName == 'eu.kanade.tachiyomi.extension.all.mihon';
  }

  static String _tachiyomiAddonId(String packageName, String sourceId) {
    String clean(String value) => value
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');

    final safePackage = clean(packageName);
    final safeSource = clean(sourceId);
    var id = 'tachiyomi.$safeSource.$safePackage';
    if (id.length > 100) id = id.substring(0, 100);
    if (id.length < 2) id = 'tachiyomi.source';
    return id;
  }

  Future<LibraryAddonBatchInstallResult> _upsertMany(
    List<LibraryAddon> incoming, {
    required LibraryAddonDocumentFormat format,
  }) async {
    await load();
    var addedCount = 0;
    var updatedCount = 0;

    for (final addon in incoming) {
      final existingIndex = _addons.indexWhere((item) => item.id == addon.id);
      if (existingIndex >= 0) {
        _addons[existingIndex] = addon;
        updatedCount++;
      } else {
        _addons.add(addon);
        addedCount++;
      }
    }

    _sortAddons();
    await _persist();
    return LibraryAddonBatchInstallResult(
      addons: List.unmodifiable(incoming),
      addedCount: addedCount,
      updatedCount: updatedCount,
      format: format,
    );
  }

  void _sortAddons() {
    _addons.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }

  Future<int> removeRepository(String repositoryOrigin) async {
    await load();
    final normalized = repositoryOrigin.trim();
    if (normalized.isEmpty) return 0;
    final before = _addons.length;
    _addons.removeWhere(
      (addon) =>
          !addon.isBuiltIn &&
          addon.isRepositorySource &&
          addon.repositoryOrigin == normalized,
    );
    final removed = before - _addons.length;
    if (removed > 0) await _persist();
    return removed;
  }

  Future<bool> remove(String id) async {
    await load();
    final before = _addons.length;
    _addons.removeWhere((addon) => addon.id == id);
    if (_addons.length == before) return false;
    await _persist();
    return true;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_addons.map((addon) => addon.toJson()).toList()),
    );
  }
}
