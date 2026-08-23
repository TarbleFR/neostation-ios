from pathlib import Path


def replace_required(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"Missing patch anchor: {label}")
    return text.replace(old, new, 1)


# Library provider registry: user import only.
p = Path("lib/services/library_metadata_provider_service.dart")
s = p.read_text(encoding="utf-8")
s = s.replace("import 'package:flutter/services.dart';\n", "")
s = s.replace("  static const String manifestAsset = 'assets/data/manga-providers.json';\n", "")
old = """  Future<void> initialize() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final imported = prefs.getString(_importedRegistryPrefsKey);
    final raw = imported?.trim().isNotEmpty == true
        ? imported!
        : await rootBundle.loadString(manifestAsset);
    _providers = _parseRegistry(raw);
    _initialized = true;
  }
"""
new = """  Future<void> initialize() async {
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
"""
s = replace_required(s, old, new, "metadata initialize import-only")
if "rootBundle.loadString" in s or "manifestAsset" in s:
    raise RuntimeError("Bundled provider registry fallback still exists")
p.write_text(s, encoding="utf-8")
Path("assets/data/manga-providers.json").unlink(missing_ok=True)

# Propagate native scan errors instead of silently falling back to Dart traversal.
p = Path("packages/external_folder_access/lib/external_folder_access.dart")
s = p.read_text(encoding="utf-8")
old = """    } on PlatformException {
      return null;
    }
  }

  /// Forgets the folder linked under [key]."""
new = """    } on PlatformException catch (error) {
      throw StateError(
        'Native iOS folder scan failed (${error.code}): ${error.message ?? 'unknown error'}',
      );
    }
  }

  /// Forgets the folder linked under [key]."""
s = replace_required(s, old, new, "native list error propagation")
p.write_text(s, encoding="utf-8")

# Swift bookmark + enumeration robustness.
p = Path("packages/external_folder_access/ios/Classes/ExternalFolderAccessPlugin.swift")
s = p.read_text(encoding="utf-8")
s = replace_required(
    s,
    "    private var activeSecurityScopedURLs: [String: URL] = [:]\n",
    "    private var activeSecurityScopedURLs: [String: URL] = [:]\n"
    "    private var startedSecurityScopedKeys = Set<String>()\n",
    "security scope tracking set",
)
old = """            if let previous = activeSecurityScopedURLs.removeValue(forKey: key),
                previous != url
            {
                previous.stopAccessingSecurityScopedResource()
            }
            if didStart {
                activeSecurityScopedURLs[key] = url
            }
            pendingResult?(url.path)
"""
new = """            if let previous = activeSecurityScopedURLs.removeValue(forKey: key),
                previous != url,
                startedSecurityScopedKeys.remove(key) != nil
            {
                previous.stopAccessingSecurityScopedResource()
            }
            activeSecurityScopedURLs[key] = url
            if didStart {
                startedSecurityScopedKeys.insert(key)
            } else {
                startedSecurityScopedKeys.remove(key)
            }
            pendingResult?(url.path)
"""
s = replace_required(s, old, new, "picker URL retention")
old = """            guard url.startAccessingSecurityScopedResource() else {
                result(
                    FlutterError(
                        code: "ACCESS_DENIED",
                        message: "startAccessingSecurityScopedResource returned false",
                        details: nil
                    )
                )
                return
            }
            activeSecurityScopedURLs[key] = url
"""
new = """            let didStart = url.startAccessingSecurityScopedResource()
            activeSecurityScopedURLs[key] = url
            if didStart {
                startedSecurityScopedKeys.insert(key)
            } else {
                startedSecurityScopedKeys.remove(key)
            }
"""
s = replace_required(s, old, new, "bookmark resolve")
old = """        guard url.startAccessingSecurityScopedResource() else {
            throw NSError(
                domain: "ExternalFolderAccess",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "startAccessingSecurityScopedResource returned false"
                ]
            )
        }
        activeSecurityScopedURLs[key] = url
"""
new = """        let didStart = url.startAccessingSecurityScopedResource()
        activeSecurityScopedURLs[key] = url
        if didStart {
            startedSecurityScopedKeys.insert(key)
        } else {
            startedSecurityScopedKeys.remove(key)
        }
"""
s = replace_required(s, old, new, "native bookmark resolve")
old = """            let manager = FileManager.default
            let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            var urls: [URL] = []

            if recursive {
                guard let enumerator = manager.enumerator(
                    at: root,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in true }
                ) else {
                    result([])
                    return
                }
"""
new = """            let manager = FileManager.default
            let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            var urls: [URL] = []
            var enumerationErrors: [String] = []

            if recursive {
                guard let enumerator = manager.enumerator(
                    at: root,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles],
                    errorHandler: { url, error in
                        enumerationErrors.append("\\(url.path): \\(error.localizedDescription)")
                        return true
                    }
                ) else {
                    throw NSError(
                        domain: "ExternalFolderAccess",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Could not enumerate bookmarked folder"]
                    )
                }
"""
s = replace_required(s, old, new, "enumeration diagnostics")
old = """                var prefix = Data()
                if prefixBytes > 0,
                    let handle = try? FileHandle(forReadingFrom: canonicalFile)
                {
                    defer { try? handle.close() }
                    prefix = (try? handle.read(upToCount: prefixBytes)) ?? Data()
                }

                entries.append([
                    "relativePath": relative,
                    "fileName": canonicalFile.lastPathComponent,
                    "size": values?.fileSize ?? 0,
                    "prefix": FlutterStandardTypedData(bytes: prefix),
                ])
            }

            result(entries)
"""
new = """                var prefix = Data()
                var prefixRead = prefixBytes == 0
                if prefixBytes > 0,
                    let handle = try? FileHandle(forReadingFrom: canonicalFile)
                {
                    defer { try? handle.close() }
                    if let data = try? handle.read(upToCount: prefixBytes) {
                        prefix = data
                        prefixRead = true
                    }
                }

                entries.append([
                    "relativePath": relative,
                    "fileName": canonicalFile.lastPathComponent,
                    "size": values?.fileSize ?? 0,
                    "prefix": FlutterStandardTypedData(bytes: prefix),
                    "prefixRead": prefixRead,
                ])
            }

            if entries.isEmpty && !enumerationErrors.isEmpty {
                throw NSError(
                    domain: "ExternalFolderAccess",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Folder enumeration failed: " + enumerationErrors.joined(separator: " | ")
                    ]
                )
            }

            result(entries)
"""
s = replace_required(s, old, new, "prefix diagnostics")
old = """    private func clearBookmark(key: String, result: @escaping FlutterResult) {
        if let active = activeSecurityScopedURLs.removeValue(forKey: key) {
            active.stopAccessingSecurityScopedResource()
        }
"""
new = """    private func clearBookmark(key: String, result: @escaping FlutterResult) {
        if let active = activeSecurityScopedURLs.removeValue(forKey: key),
            startedSecurityScopedKeys.remove(key) != nil
        {
            active.stopAccessingSecurityScopedResource()
        }
"""
s = replace_required(s, old, new, "balanced bookmark clear")
p.write_text(s, encoding="utf-8")

# Fin native scan is authoritative on iOS and accepts parent Fin folder.
p = Path("lib/services/fin_library_service.dart")
s = p.read_text(encoding="utf-8")
s = replace_required(
    s,
    "  static int _lastSkippedGames = 0;\n",
    "  static int _lastSkippedGames = 0;\n"
    "  static int _lastNativeCandidates = 0;\n"
    "  static int _lastNativeUnreadablePrefixes = 0;\n",
    "Fin counters",
)
s = replace_required(
    s,
    "  static int get skippedGameCount => _lastSkippedGames;\n",
    """  static int get skippedGameCount => _lastSkippedGames;

  static String? get firstLaunchableGameId {
    for (final game in _cache ?? const <FinLibraryGame>[]) {
      final value = game.gameId?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }
""",
    "Fin first launchable ID",
)
old = """        final nativeDiscovery = await _discoverLibraryNatively(
          root,
          allowTitleLookup: false,
        );
        final discovery =
            nativeDiscovery ??
            (await Directory(root).exists()
                ? await discoverLibrary(root)
                : null);
"""
new = """        final discovery = await _discoverLibraryNatively(
          root,
          allowTitleLookup: false,
        );
"""
s = replace_required(s, old, new, "Fin restore native only")
old = """    final nativeDiscovery = await _discoverLibraryNatively(
      root,
      allowTitleLookup: true,
    );
    final discovery =
        nativeDiscovery ?? await discoverLibrary(root, allowTitleLookup: true);
    final discoveryMode = nativeDiscovery == null ? 'dart' : 'native-ios';
"""
new = """    final discovery = Platform.isIOS
        ? await _discoverLibraryNatively(root, allowTitleLookup: true)
        : await discoverLibrary(root, allowTitleLookup: true);
    if (discovery == null) {
      await _writeDebugFile(
        'STATE: NATIVE_SCAN_UNAVAILABLE\\nGames root: $root',
      );
      throw StateError('Fin native iOS scan is unavailable for the linked folder.');
    }
    final discoveryMode = Platform.isIOS ? 'native-ios' : 'dart';
"""
s = replace_required(s, old, new, "Fin sync native only")
old = """    final entries = await ExternalFolderAccess.listBookmarkedFiles(
      key: bookmarkKey,
      subdirectory: subdirectory,
      extensions: _supportedExtensions
          .map((extension) => extension.replaceFirst('.', ''))
          .toList(growable: false),
      recursive: true,
      prefixBytes: 0x100,
    );
    if (entries == null) return null;

    final games = <FinLibraryGame>[];
    var skipped = 0;
"""
new = """    final entries = await ExternalFolderAccess.listBookmarkedFiles(
      key: bookmarkKey,
      subdirectory: subdirectory,
      extensions: _supportedExtensions
          .map((extension) => extension.replaceFirst('.', ''))
          .toList(growable: false),
      recursive: true,
      prefixBytes: 0x100,
    );
    if (entries == null) {
      throw StateError('Fin bookmark resolved but native enumeration returned no result.');
    }

    _lastNativeCandidates = entries.length;
    _lastNativeUnreadablePrefixes = 0;
    final games = <FinLibraryGame>[];
    var skipped = 0;
"""
s = replace_required(s, old, new, "Fin native enumeration result")
s = replace_required(
    s,
    "      final rawPrefix = entry['prefix'];\n      final Uint8List prefix;\n",
    """      if (entry['prefixRead'] == false) {
        _lastNativeUnreadablePrefixes++;
      }
      final rawPrefix = entry['prefix'];
      final Uint8List prefix;
""",
    "Fin prefix counter",
)
s = replace_required(
    s,
    "      'Discovery mode: $discoveryMode\\n'\n      'Detected: ${discovery.games.length}\\n'\n",
    """      'Discovery mode: $discoveryMode\\n'
      'Native candidates: $_lastNativeCandidates\\n'
      'Unreadable prefixes: $_lastNativeUnreadablePrefixes\\n'
      'Detected: ${discovery.games.length}\\n'
""",
    "Fin debug counters",
)
s = replace_required(
    s,
    """    final base = path.basename(normalizedPath).toLowerCase();
    if (base == 'games' || base == 'software') return normalizedPath;

    final root = Directory(normalizedPath);
""",
    """    final base = path.basename(normalizedPath).toLowerCase();
    if (base == 'games' || base == 'software') return normalizedPath;

    // The native recursive scanner can walk a selected parent Fin folder even
    // when Dart cannot stat/list provider-backed folders returned by Files.
    if (Platform.isIOS) return normalizedPath;

    final root = Directory(normalizedPath);
""",
    "Fin iOS parent folder",
)
p.write_text(s, encoding="utf-8")

# Fin test button uses a real Game ID rather than a dummy value that can launch Fruits!.
p = Path("lib/screens/settings_screen/new_settings_options/directories_settings_content.dart")
s = p.read_text(encoding="utf-8")
old = """  Future<void> _testFinLaunch() async {
    final fr = Localizations.localeOf(context).languageCode == 'fr';
    final opened = await IosShortcutJitLaunchService.run(
      shortcutName: IosShortcutJitLaunchService.finShortcutName,
      input: '__NEOSTATION_TEST__',
    );
    if (!mounted) return;
    AppNotification.showNotification(
      context,
      opened
          ? (fr
                ? 'Test envoyé au raccourci NeoStation+Fin.'
                : 'Test sent to the NeoStation+Fin Shortcut.')
          : (fr
                ? 'Le raccourci NeoStation+Fin n’a pas pu être lancé.'
                : 'NeoStation+Fin Shortcut could not be launched.'),
      type: opened ? NotificationType.info : NotificationType.error,
    );
  }
"""
new = """  Future<void> _testFinLaunch() async {
    final fr = Localizations.localeOf(context).languageCode == 'fr';
    await FinLibraryService.loadCachedLibrary();
    final input = FinLibraryService.firstLaunchableGameId;
    if (input == null || input.isEmpty) {
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        fr
            ? 'Synchronise d’abord Fin : aucun Game ID Nintendo n’est disponible.'
            : 'Sync Fin first: no Nintendo Game ID is available.',
        type: NotificationType.error,
      );
      return;
    }
    final opened = await IosShortcutJitLaunchService.run(
      shortcutName: IosShortcutJitLaunchService.finShortcutName,
      input: input,
    );
    if (!mounted) return;
    AppNotification.showNotification(
      context,
      opened
          ? (fr ? 'Test Fin envoyé avec le Game ID $input.' : 'Fin test sent with Game ID $input.')
          : (fr
                ? 'Le raccourci NeoStation+Fin n’a pas pu être lancé.'
                : 'NeoStation+Fin Shortcut could not be launched.'),
      type: opened ? NotificationType.info : NotificationType.error,
    );
  }
"""
s = replace_required(s, old, new, "Fin test button")
s = s.replace(
    "Raccourci attendu : NeoStation+Fin. NeoStation lui transmet le chemin relatif du jeu sous Fin/Games.",
    "Raccourci attendu : NeoStation+Fin. NeoStation lui transmet le Game ID Nintendo du jeu.",
)
s = s.replace(
    "Expected Shortcut: NeoStation+Fin. NeoStation passes the game path relative to Fin/Games.",
    "Expected Shortcut: NeoStation+Fin. NeoStation passes the Nintendo Game ID.",
)
p.write_text(s, encoding="utf-8")

# Regression test explicitly forbids a bundled metadata registry.
p = Path("test/library_no_native_sources_test.dart")
s = p.read_text(encoding="utf-8")
s = s.replace(
    "      expect(File('assets/data/manga-providers.json').existsSync(), isTrue);",
    "      expect(File('assets/data/manga-providers.json').existsSync(), isFalse);",
)
old = """      expect(
        File('lib/services/library_metadata_provider_service.dart')
            .existsSync(),
        isTrue,
      );
"""
new = """      final metadata = File(
        'lib/services/library_metadata_provider_service.dart',
      );
      expect(metadata.existsSync(), isTrue);
      final metadataSource = metadata.readAsStringSync();
      expect(metadataSource, isNot(contains('rootBundle.loadString')));
      expect(metadataSource, isNot(contains('manifestAsset')));
"""
s = replace_required(s, old, new, "Library no-native provider test")
p.write_text(s, encoding="utf-8")

# Make the corrected IPA distinguishable on-device.
p = Path("pubspec.yaml")
s = p.read_text(encoding="utf-8")
s = replace_required(s, "version: 1.0.0+143\n", "version: 1.0.0+144\n", "build 144")
p.write_text(s, encoding="utf-8")

print("Fin iOS native scan and Library import-only policy fixes applied.")
