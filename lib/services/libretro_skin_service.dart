import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show InputMemoryStream, ZipDirectory;
import 'package:crypto/crypto.dart' show sha256;
import 'package:file_picker/file_picker.dart';
import 'package:libretro_internal_bridge/libretro_internal_bridge.dart';
import 'package:path/path.dart' as path;

import 'libretro_core_catalog.dart';
import 'libretro_internal_service.dart';
import 'logger_service.dart';

/// LibretroLocale keys of the skin import messages. Native codes (the
/// `SKIN_*` constants of LibretroSkin.h) are translated through
/// [errorKeys] and [warningKeys]; the other keys are refusals decided in
/// Dart before the native parser runs.
abstract final class LibretroSkinMessages {
  static const String notArchive = 'skinErrorNotArchive';
  static const String tooLarge = 'skinErrorTooLarge';
  static const String unsafe = 'skinErrorUnsafe';
  static const String corrupt = 'skinErrorCorrupt';
  static const String infoMissing = 'skinErrorInfoMissing';
  static const String tooManyFiles = 'skinErrorTooManyFiles';
  static const String expandedTooLarge = 'skinErrorExpandedTooLarge';
  static const String imageTooLarge = 'skinErrorImageTooLarge';
  static const String consoleUnsupported = 'skinErrorConsoleUnsupported';
  static const String download = 'skinErrorDownload';
  static const String notDirect = 'catalogNotDirect';

  /// A `.zip` holding several `.deltaskin`/`.manicskin` files: the user
  /// extracts it and imports the skins one at a time.
  static const String pack = 'skinErrorPack';

  /// Generic refusal when no specific message applies.
  static const String importFailed = 'skinsImportFailed';

  /// Native import errors (skin refused).
  static const Map<String, String> errorKeys = <String, String>{
    'SKIN_INFO_MISSING': infoMissing,
    'SKIN_INFO_INVALID': 'skinErrorInfoInvalid',
    'SKIN_FIELD_MISSING': 'skinErrorFieldMissing',
    'SKIN_CONSOLE_UNSUPPORTED': consoleUnsupported,
    'SKIN_NO_REPRESENTATION': 'skinErrorNoRepresentation',
    'SKIN_NO_DEVICE': 'skinErrorNoDevice',
  };

  /// Native import remarks (skin accepted).
  static const Map<String, String> warningKeys = <String, String>{
    'SKIN_WARN_ORIENTATION_MISSING': 'skinWarnOrientationMissing',
    'SKIN_WARN_ASSET_MISSING': 'skinWarnAssetMissing',
    'SKIN_WARN_UNKNOWN_INPUTS': 'skinWarnUnknownInputs',
    'SKIN_WARN_FILTERS_IGNORED': 'skinWarnFiltersIgnored',
    'SKIN_WARN_INPUT_FRAME_IGNORED': 'skinWarnInputFrameIgnored',
    'SKIN_WARN_ITEMS_DROPPED': 'skinWarnItemsDropped',
    'SKIN_WARN_DEBUG_MISSING': 'skinWarnDebugMissing',
    'SKIN_WARN_TOUCHSCREEN_UNSUPPORTED': 'skinWarnTouchScreen',
  };

  /// Every native `SKIN_*` code.
  static const Map<String, String> codeKeys = <String, String>{...errorKeys, ...warningKeys};
}

/// An imported skin, described by `Skins/<id>/neostation-skin.json`.
class LibretroInstalledSkin {
  const LibretroInstalledSkin({
    required this.id,
    required this.identifier,
    required this.name,
    this.author,
    required this.consoles,
    this.gameTypeIdentifier = '',
    required this.orientations,
    this.warnings = const <String>[],
    required this.source,
    this.license,
    required this.sha256,
    required this.importedAt,
    required this.directory,
  });

  /// Directory name: the first 16 hex characters of the archive SHA-256.
  final String id;

  /// `identifier` of info.json (reverse DNS), used to detect a replacement.
  final String identifier;
  final String name;
  final String? author;

  /// NeoStation consoles the skin applies to.
  final List<String> consoles;
  final String gameTypeIdentifier;

  /// Orientations per device class: {"iphone": [...], "ipad": [...]}.
  final Map<String, List<String>> orientations;

  /// Native `SKIN_WARN_*` codes of the import report.
  final List<String> warnings;

  /// [LibretroSkinService.sourceFile] or the catalog download URL.
  final String source;
  final String? license;
  final String sha256;
  final DateTime importedAt;
  final String directory;

  /// LibretroLocale keys of the import remarks.
  List<String> get warningKeys =>
      warnings.map((code) => LibretroSkinMessages.warningKeys[code]).whereType<String>().toList();

  bool supports(String orientation, {bool iPad = false}) =>
      (orientations[iPad ? 'ipad' : 'iphone'] ?? const <String>[]).contains(orientation);

  Map<String, Object?> toJson() => <String, Object?>{
        'version': 1,
        'id': id,
        'identifier': identifier,
        'name': name,
        'author': author,
        'consoles': consoles,
        'gameTypeIdentifier': gameTypeIdentifier,
        'orientations': orientations,
        'warnings': warnings,
        'source': source,
        'license': license,
        'sha256': sha256,
        'importedAt': importedAt.toUtc().toIso8601String(),
      };

  /// Null when the metadata is unreadable or does not name `directory`.
  static LibretroInstalledSkin? fromJson(Object? json, String directory) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final importedAt = DateTime.tryParse(_text(json['importedAt']));
    if (id is! String || id != path.basename(directory) || name is! String || importedAt == null) {
      return null;
    }
    return LibretroInstalledSkin(
      id: id,
      identifier: _text(json['identifier']),
      name: name,
      author: _optionalText(json['author']),
      consoles: _texts(json['consoles']),
      gameTypeIdentifier: _text(json['gameTypeIdentifier']),
      orientations: _orientations(json['orientations']),
      warnings: _texts(json['warnings']),
      source: _optionalText(json['source']) ?? LibretroSkinService.sourceFile,
      license: _optionalText(json['license']),
      sha256: _text(json['sha256']),
      importedAt: importedAt,
      directory: directory,
    );
  }
}

/// Outcome of a skin import.
sealed class LibretroSkinImportResult {
  const LibretroSkinImportResult();
}

final class LibretroSkinImported extends LibretroSkinImportResult {
  const LibretroSkinImported(this.skin, {this.alreadyInstalled = false});

  final LibretroInstalledSkin skin;

  /// The same archive was already installed; nothing changed.
  final bool alreadyInstalled;

  List<String> get warningKeys => skin.warningKeys;
}

/// An installed skin has the same identifier: the user confirms with
/// [LibretroSkinService.replace] or cancels with [LibretroSkinService.discard].
final class LibretroSkinNeedsReplaceConfirmation extends LibretroSkinImportResult {
  const LibretroSkinNeedsReplaceConfirmation._(this.existing, this.skin, this._stagingPath);

  final LibretroInstalledSkin existing;

  /// The new skin, checked but not installed yet.
  final LibretroInstalledSkin skin;
  final String _stagingPath;

  /// Name shown in "skinsReplaceConfirm".
  String get existingName => existing.name;
}

final class LibretroSkinImportFailed extends LibretroSkinImportResult {
  const LibretroSkinImportFailed(
    this.messageKey, {
    this.parameters = const <String, Object>{},
    this.technicalDetails = '',
  });

  /// LibretroLocale key of the translated message.
  final String messageKey;

  /// Placeholder values of the message ({limit}, {type}).
  final Map<String, Object> parameters;

  /// Raw diagnostic, never shown as the message.
  final String technicalDetails;
}

/// Imported skins of the embedded engine: validation and extraction of
/// `.deltaskin`, `.manicskin` and `.zip` archives, native parsing through
/// the bridge, storage in `Documents/Libretro/Skins/<id>`, and the per-console
/// selections kept by the native frontend store.
class LibretroSkinService {
  LibretroSkinService({
    required this.skinsDirectory,
    required this.frontendDirectory,
    required this.cacheDirectory,
    Map<String, Object?>? consoleGeometry,
  }) : consoleGeometry = consoleGeometry ?? LibretroCoreCatalog.consoleGeometry();

  static Future<LibretroSkinService> create() async => LibretroSkinService(
        skinsDirectory: (await LibretroInternalService.skinsDirectory()).path,
        frontendDirectory: (await LibretroInternalService.frontendDirectory()).path,
        cacheDirectory: (await LibretroInternalService.cacheDirectory()).path,
      );

  static final _log = LoggerService.instance;

  static const int maxArchiveBytes = 50 * 1024 * 1024;
  static const int maxExpandedBytes = 200 * 1024 * 1024;
  static const int maxEntries = 1024;
  static const int maxCompressionRatio = 100;
  static const int maxImagePixels = 8192;

  /// Entries smaller than this are not held to [maxCompressionRatio]: tiny
  /// text files legitimately compress very well.
  static const int compressionRatioFloor = 64 * 1024;

  static const String metadataFileName = 'neostation-skin.json';
  static const String stagingFolderName = '.staging';
  static const String sourceFile = 'file';

  /// Identifier of NeoStation's built-in skin (LibretroDefaultSkinIdentifier).
  static const String defaultSkinId = 'default';
  static const String portrait = 'portrait';
  static const String landscape = 'landscape';
  static const List<String> orientationNames = <String>[portrait, landscape];

  static final RegExp _idPattern = RegExp(r'^[a-z0-9-]+$');

  final String skinsDirectory;
  final String frontendDirectory;
  final String cacheDirectory;
  final Map<String, Object?> consoleGeometry;

  /// Imported skin directory names (never "default", never ".staging").
  static bool isInstalledId(String id) => id != defaultSkinId && _idPattern.hasMatch(id);

  /// ZIP local file header signature "PK\x03\x04" (every skin archive).
  static bool isZipSignature(List<int> bytes) =>
      bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04;

  /// Frontend setting key of the skin selected for an orientation.
  static String selectionKey(String orientation) {
    if (!orientationNames.contains(orientation)) {
      throw ArgumentError.value(orientation, 'orientation');
    }
    return 'skin.$orientation';
  }

  Future<List<LibretroInstalledSkin>> installedSkins({String? console}) async {
    final root = Directory(skinsDirectory);
    if (!await root.exists()) return const <LibretroInstalledSkin>[];
    final skins = <LibretroInstalledSkin>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory || !isInstalledId(path.basename(entity.path))) continue;
      final skin = await _readMetadata(entity.path);
      if (skin == null || (console != null && !skin.consoles.contains(console))) continue;
      skins.add(skin);
    }
    skins.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
    return skins;
  }

  Future<LibretroInstalledSkin?> installedSkin(String id) async =>
      isInstalledId(id) ? await _readMetadata(path.join(skinsDirectory, id)) : null;

  /// Lets the user pick an archive in Files. Every file type is offered:
  /// `.deltaskin` and `.manicskin` have no system type on iOS, and the
  /// content is checked anyway. Null when the picker was cancelled.
  Future<LibretroSkinImportResult?> pickAndImport() async {
    final selection = await FilePicker.pickFiles(
      allowMultiple: false,
      type: FileType.any,
      withData: false,
      lockParentWindow: true,
    );
    final picked = selection?.files.single.path;
    if (picked == null) return null;
    return importFromFile(picked);
  }

  /// Checks, unpacks and parses an archive, then installs it unless an
  /// installed skin has the same identifier.
  Future<LibretroSkinImportResult> importFromFile(
    String archivePath, {
    String source = sourceFile,
    String? author,
    String? license,
  }) async {
    final staging = Directory(path.join(skinsDirectory, stagingFolderName, _randomHex()));
    try {
      await _removeStaleStaging();
      final unpacked = await _unpackInBackground(archivePath, staging.path);
      final refusal = unpacked.failure;
      if (refusal != null) {
        await _remove(staging);
        return refusal;
      }
      final id = unpacked.sha256.substring(0, 16);
      final installed = await installedSkin(id);
      if (installed != null) {
        await _remove(staging);
        return LibretroSkinImported(installed, alreadyInstalled: true);
      }
      final inspected = await LibretroInternalBridge.inspectSkin(
        directory: staging.path,
        consoleGeometry: consoleGeometry,
      );
      final rawSummary = inspected['summary'];
      final summary = rawSummary is Map ? rawSummary : inspected;
      final consoles = _texts(summary['consoles']);
      if (inspected['ok'] != true || consoles.isEmpty) {
        final failure = await _nativeFailure(inspected, summary, staging.path);
        await _remove(staging);
        return failure;
      }
      final identifier = _optionalText(summary['identifier']) ?? id;
      final skin = LibretroInstalledSkin(
        id: id,
        identifier: identifier,
        name: _optionalText(summary['name']) ?? identifier,
        author: _optionalText(author) ?? _optionalText(summary['author']),
        consoles: consoles,
        gameTypeIdentifier: _text(summary['gameTypeIdentifier']),
        orientations: _orientations(summary['orientations']),
        warnings: _texts(summary['warnings']),
        source: _optionalText(source) ?? sourceFile,
        license: _optionalText(license),
        sha256: unpacked.sha256,
        importedAt: DateTime.now().toUtc(),
        directory: path.join(skinsDirectory, id),
      );
      for (final other in await installedSkins()) {
        if (other.identifier == skin.identifier) {
          return LibretroSkinNeedsReplaceConfirmation._(other, skin, staging.path);
        }
      }
      return LibretroSkinImported(await _install(staging, skin));
    } catch (error) {
      _log.w('Libretro skin import failed for $archivePath: $error');
      await _remove(staging);
      return LibretroSkinImportFailed(LibretroSkinMessages.importFailed, technicalDetails: '$error');
    }
  }

  /// Replaces the installed skin with the same identifier. The new skin is
  /// installed first, in its own directory (its id always differs from the
  /// old one), and the skin selections naming the old skin move to it; only
  /// then is the old skin forgotten and deleted (its control remaps and
  /// layouts no longer match). When the new skin cannot be installed, or a
  /// selection cannot be moved, the new skin is taken back out and the old
  /// skin keeps its files and its selections.
  Future<LibretroSkinImportResult> replace(LibretroSkinNeedsReplaceConfirmation confirmation) async {
    final staging = Directory(confirmation._stagingPath);
    final previous = confirmation.existing;
    try {
      if (!await staging.exists()) {
        return const LibretroSkinImportFailed(LibretroSkinMessages.importFailed);
      }
      final selections = await _selectionsNaming(previous);
      final installed = await _install(staging, confirmation.skin);
      final moved = <_SkinSelection>[];
      try {
        for (final selection in selections) {
          if (!installed.consoles.contains(selection.console)) continue;
          if (!await _storeSelection(selection, installed.id)) {
            throw StateError('Skin selection not stored: ${selection.console} ${selection.game ?? '-'} '
                '${selection.key}');
          }
          moved.add(selection);
        }
      } catch (_) {
        await _withdraw(installed, moved, previous.id);
        rethrow;
      }
      try {
        await delete(previous.id);
      } catch (error) {
        // The new skin is installed and selected; the old one stays listed
        // on the skin page, where it can still be deleted.
        _log.w('Libretro replaced skin ${previous.id} not removed: $error');
      }
      return LibretroSkinImported(installed);
    } catch (error) {
      _log.w('Libretro skin replacement failed: $error');
      await _remove(staging);
      return LibretroSkinImportFailed(LibretroSkinMessages.importFailed, technicalDetails: '$error');
    }
  }

  /// Undoes a replacement that failed after the new skin was installed: the
  /// selections already moved name the previous skin again, then the new
  /// skin is forgotten and deleted.
  Future<void> _withdraw(LibretroInstalledSkin installed, List<_SkinSelection> moved, String previousId) async {
    for (final selection in moved) {
      try {
        await _storeSelection(selection, previousId);
      } catch (error) {
        _log.w('Libretro skin selection not restored for ${selection.console}: $error');
      }
    }
    try {
      await delete(installed.id);
    } catch (error) {
      _log.w('Libretro skin ${installed.id} not removed after a failed replacement: $error');
    }
  }

  Future<bool> _storeSelection(_SkinSelection selection, String skinId) =>
      LibretroInternalBridge.setFrontendSetting(
        directory: frontendDirectory,
        console: selection.console,
        game: selection.game,
        key: selection.key,
        value: skinId,
      );

  /// Cancels a pending replacement.
  Future<void> discard(LibretroSkinNeedsReplaceConfirmation confirmation) =>
      _remove(Directory(confirmation._stagingPath));

  /// Deletes an imported skin after the native store has forgotten its
  /// selections, remaps, layouts and cached images.
  Future<void> delete(String id) async {
    if (!isInstalledId(id)) throw ArgumentError.value(id, 'id');
    final directory = Directory(path.join(skinsDirectory, id));
    await LibretroInternalBridge.forgetSkin(
      directory: frontendDirectory,
      skinId: id,
      skinDirectory: directory.path,
      cacheDirectory: cacheDirectory,
    );
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  /// Uses a skin for one orientation of a console (or of one game).
  Future<bool> select({
    required String console,
    required String orientation,
    required String skinId,
    String? game,
  }) {
    if (skinId != defaultSkinId && !isInstalledId(skinId)) {
      throw ArgumentError.value(skinId, 'skinId');
    }
    return LibretroInternalBridge.setFrontendSetting(
      directory: frontendDirectory,
      console: console,
      game: game,
      key: selectionKey(orientation),
      value: skinId,
    );
  }

  /// Removes the selection of one orientation, or of both, so NeoStation's
  /// default skin applies again (or the console's choice, for a game).
  Future<bool> resetToDefault({required String console, String? orientation, String? game}) async {
    var stored = true;
    for (final name in orientation == null ? orientationNames : <String>[orientation]) {
      final done = await LibretroInternalBridge.setFrontendSetting(
        directory: frontendDirectory,
        console: console,
        game: game,
        key: selectionKey(name),
        value: null,
      );
      stored = stored && done;
    }
    return stored;
  }

  /// Skin ids stored at one scope: {"portrait": id?, "landscape": id?}.
  Future<Map<String, String?>> selectedSkins(String console, {String? game}) async {
    final snapshot = await LibretroInternalBridge.frontendSettings(
      directory: frontendDirectory,
      console: console,
    );
    final games = snapshot['games'];
    final scope = game == null ? snapshot['console'] : (games is Map ? games[game] : null);
    return <String, String?>{
      for (final name in orientationNames)
        name: scope is Map && scope[selectionKey(name)] is String ? scope[selectionKey(name)] as String : null,
    };
  }

  /// PNG preview of a skin, NeoStation's default skin when [skin] is null.
  Future<Uint8List?> preview({
    LibretroInstalledSkin? skin,
    required String console,
    required String orientation,
    required double width,
    required double height,
    double? scale,
  }) async {
    try {
      return await LibretroInternalBridge.skinPreview(
        skinDirectory: skin?.directory,
        console: console,
        orientation: orientation,
        width: width,
        height: height,
        consoleGeometry: consoleGeometry,
        cacheDirectory: cacheDirectory,
        scale: scale,
      );
    } catch (error) {
      _log.w('Libretro skin preview unavailable: $error');
      return null;
    }
  }

  Future<LibretroInstalledSkin> _install(Directory staging, LibretroInstalledSkin skin) async {
    await File(path.join(staging.path, metadataFileName)).writeAsString(jsonEncode(skin.toJson()), flush: true);
    final target = Directory(skin.directory);
    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);
    return skin;
  }

  Future<List<_SkinSelection>> _selectionsNaming(LibretroInstalledSkin skin) async {
    final selections = <_SkinSelection>[];
    for (final console in skin.consoles) {
      final snapshot = await LibretroInternalBridge.frontendSettings(
        directory: frontendDirectory,
        console: console,
      );
      void collect(Object? scope, String? game) {
        if (scope is! Map) return;
        for (final name in orientationNames) {
          final key = selectionKey(name);
          if (scope[key] == skin.id) selections.add(_SkinSelection(console, game, key));
        }
      }

      collect(snapshot['console'], null);
      final games = snapshot['games'];
      if (games is Map) {
        for (final entry in games.entries) {
          if (entry.key is String) collect(entry.value, entry.key as String);
        }
      }
    }
    return selections;
  }

  Future<LibretroSkinImportFailed> _nativeFailure(
    Map<String, dynamic> inspected,
    Map<Object?, Object?> summary,
    String stagingPath,
  ) async {
    final code = _text(inspected['error']);
    final key = code.isEmpty && inspected['ok'] == true
        ? LibretroSkinMessages.consoleUnsupported
        : LibretroSkinMessages.errorKeys[code] ?? LibretroSkinMessages.importFailed;
    final message = _optionalText(inspected['message']);
    final details = <String>[
      if (code.isNotEmpty) code,
      ?message,
    ].join(': ');
    if (key != LibretroSkinMessages.consoleUnsupported) {
      return LibretroSkinImportFailed(key, technicalDetails: details);
    }
    final type = _optionalText(summary['gameTypeIdentifier']) ??
        _optionalText(inspected['gameTypeIdentifier']) ??
        await _declaredGameType(stagingPath) ??
        '';
    return LibretroSkinImportFailed(key, parameters: <String, Object>{'type': type}, technicalDetails: details);
  }

  /// gameTypeIdentifier of an unpacked info.json, only for the message.
  static Future<String?> _declaredGameType(String stagingPath) async {
    try {
      final json = jsonDecode(await File(path.join(stagingPath, 'info.json')).readAsString());
      return json is Map ? _optionalText(json['gameTypeIdentifier']) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<LibretroInstalledSkin?> _readMetadata(String directory) async {
    try {
      final file = File(path.join(directory, metadataFileName));
      if (!await file.exists()) return null;
      return LibretroInstalledSkin.fromJson(jsonDecode(await file.readAsString()), directory);
    } catch (error) {
      _log.w('Libretro skin metadata unreadable in $directory: $error');
      return null;
    }
  }

  /// Staging directories older than an hour belong to an interrupted import
  /// or to a replacement that was never confirmed.
  Future<void> _removeStaleStaging() async {
    final root = Directory(path.join(skinsDirectory, stagingFolderName));
    if (!await root.exists()) return;
    final limit = DateTime.now().subtract(const Duration(hours: 1));
    await for (final entity in root.list(followLinks: false)) {
      try {
        if ((await entity.stat()).modified.isBefore(limit)) await entity.delete(recursive: true);
      } catch (error) {
        _log.w('Libretro skin staging cleanup skipped ${entity.path}: $error');
      }
    }
  }

  static Future<void> _remove(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (error) {
      _log.w('Libretro skin staging not removed ${directory.path}: $error');
    }
  }

  static String _randomHex() {
    final random = Random.secure();
    return List<String>.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<_UnpackOutcome> _unpackInBackground(String archivePath, String stagingPath) =>
      Isolate.run(() => _unpackArchive(archivePath, stagingPath));
}

class _SkinSelection {
  const _SkinSelection(this.console, this.game, this.key);

  final String console;
  final String? game;
  final String key;
}

String _text(Object? value) => value is String ? value : '';

String? _optionalText(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;

List<String> _texts(Object? value) =>
    value is List ? <String>[for (final item in value) if (item is String) item] : const <String>[];

Map<String, List<String>> _orientations(Object? value) => value is Map
    ? <String, List<String>>{
        for (final entry in value.entries)
          if (entry.key is String) entry.key as String: _texts(entry.value),
      }
    : const <String, List<String>>{};

class _UnpackOutcome {
  const _UnpackOutcome.success(this.sha256) : failure = null;
  const _UnpackOutcome.failure(LibretroSkinImportFailed this.failure) : sha256 = '';

  final String sha256;
  final LibretroSkinImportFailed? failure;
}

class _Refusal implements Exception {
  const _Refusal(this.failure);

  final LibretroSkinImportFailed failure;
}

class _PlannedEntry {
  const _PlannedEntry(this.segments, this.compressionMethod, this.size, this.raw);

  final List<String> segments;
  final int compressionMethod;
  final int size;
  final Uint8List Function() raw;
}

const LibretroSkinImportFailed _corrupt = LibretroSkinImportFailed(LibretroSkinMessages.corrupt);
const LibretroSkinImportFailed _unsafe = LibretroSkinImportFailed(LibretroSkinMessages.unsafe);
const LibretroSkinImportFailed _archiveTooLarge = LibretroSkinImportFailed(
  LibretroSkinMessages.tooLarge,
  parameters: <String, Object>{'limit': LibretroSkinService.maxArchiveBytes ~/ (1024 * 1024)},
);

/// Runs in a background isolate: checks the archive, then writes the skin
/// files into `stagingPath` (info.json at its root). Nothing is written
/// outside `stagingPath`.
_UnpackOutcome _unpackArchive(String archivePath, String stagingPath) {
  try {
    final archive = File(archivePath);
    if (archive.lengthSync() > LibretroSkinService.maxArchiveBytes) {
      return const _UnpackOutcome.failure(_archiveTooLarge);
    }
    return _unpackBytes(archive.readAsBytesSync(), stagingPath, unwrap: true);
  } on _Refusal catch (refusal) {
    return _UnpackOutcome.failure(refusal.failure);
  } catch (_) {
    return const _UnpackOutcome.failure(_corrupt);
  }
}

/// Checks a skin archive held in memory, then writes its files into
/// `stagingPath`. With [unwrap], an archive without info.json that wraps
/// exactly one `.deltaskin` or `.manicskin` file (a skin published as a
/// `.zip`) opens that skin archive in turn, once, under the same limits and
/// checks; the skin id then comes from the wrapped archive, as if it had been
/// imported directly. Several wrapped skins are refused as a pack.
_UnpackOutcome _unpackBytes(Uint8List bytes, String stagingPath, {required bool unwrap}) {
  if (!LibretroSkinService.isZipSignature(bytes)) {
    return const _UnpackOutcome.failure(LibretroSkinImportFailed(LibretroSkinMessages.notArchive));
  }
  final digest = sha256.convert(bytes).toString();
  final headers = (ZipDirectory()..read(InputMemoryStream(bytes))).fileHeaders;
  if (headers.isEmpty) return const _UnpackOutcome.failure(_corrupt);
  if (headers.length > LibretroSkinService.maxEntries) {
    return const _UnpackOutcome.failure(LibretroSkinImportFailed(
      LibretroSkinMessages.tooManyFiles,
      parameters: <String, Object>{'limit': LibretroSkinService.maxEntries},
    ));
  }

  const expandedTooLarge = LibretroSkinImportFailed(
    LibretroSkinMessages.expandedTooLarge,
    parameters: <String, Object>{'limit': LibretroSkinService.maxExpandedBytes ~/ (1024 * 1024)},
  );
  final kept = <_PlannedEntry>[];
  var expanded = 0;
  var compressed = 0;
  for (final header in headers) {
    final name = header.filename;
    if (name.isEmpty || name.contains('\\') || name.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(name)) {
      return const _UnpackOutcome.failure(_unsafe);
    }
    final segments = name.split('/').where((part) => part.isNotEmpty && part != '.').toList();
    if (segments.contains('..')) return const _UnpackOutcome.failure(_unsafe);
    // Unix file type in the high word of the external attributes.
    if (((header.externalFileAttributes >> 16) & 0xF000) == 0xA000) {
      return const _UnpackOutcome.failure(_unsafe);
    }
    if (segments.isEmpty || name.endsWith('/')) continue;
    if (segments.first == '__MACOSX' || segments.last.startsWith('._') || segments.last == '.DS_Store') {
      continue;
    }
    // Encrypted entries and compression methods other than store and
    // deflate cannot come from a skin editor.
    if ((header.generalPurposeBitFlag & 0x1) != 0 ||
        (header.compressionMethod != 0 && header.compressionMethod != 8)) {
      return const _UnpackOutcome.failure(_corrupt);
    }
    final size = header.uncompressedSize;
    expanded += size;
    compressed += header.compressedSize;
    if (expanded > LibretroSkinService.maxExpandedBytes) return const _UnpackOutcome.failure(expandedTooLarge);
    if (size > LibretroSkinService.compressionRatioFloor &&
        size > header.compressedSize * LibretroSkinService.maxCompressionRatio) {
      return const _UnpackOutcome.failure(expandedTooLarge);
    }
    final file = header.file;
    if (file == null) return const _UnpackOutcome.failure(_corrupt);
    kept.add(_PlannedEntry(segments, header.compressionMethod, size, file.getRawContent));
  }
  if (expanded > LibretroSkinService.compressionRatioFloor &&
      expanded > compressed * LibretroSkinService.maxCompressionRatio) {
    return const _UnpackOutcome.failure(expandedTooLarge);
  }

  final prefix = _skinRoot(kept);
  if (prefix == null) {
    final wrapped = unwrap ? kept.where(_isWrappedSkin).toList() : const <_PlannedEntry>[];
    if (wrapped.length > 1) {
      return const _UnpackOutcome.failure(LibretroSkinImportFailed(LibretroSkinMessages.pack));
    }
    if (wrapped.length == 1) {
      final inner = wrapped.single;
      if (inner.size > LibretroSkinService.maxArchiveBytes) return const _UnpackOutcome.failure(_archiveTooLarge);
      return _unpackBytes(_expand(inner), stagingPath, unwrap: false);
    }
    return const _UnpackOutcome.failure(LibretroSkinImportFailed(LibretroSkinMessages.infoMissing));
  }
  final seen = <String>{};
  for (final entry in kept) {
    final relative = entry.segments.sublist(prefix.length);
    // NeoStation writes its own metadata file at the skin root: an archive
    // never provides it (as a file, or as a folder that would make the
    // metadata write fail).
    if (relative.first.toLowerCase() == LibretroSkinService.metadataFileName) {
      return const _UnpackOutcome.failure(_unsafe);
    }
    if (!seen.add(relative.join('/').toLowerCase())) return const _UnpackOutcome.failure(_corrupt);
  }

  Directory(stagingPath).createSync(recursive: true);
  for (final entry in kept) {
    final target = path.joinAll(<String>[stagingPath, ...entry.segments.sublist(prefix.length)]);
    if (!path.isWithin(stagingPath, target)) return const _UnpackOutcome.failure(_unsafe);
    final content = _expand(entry);
    if (_pngTooLarge(content)) {
      return const _UnpackOutcome.failure(LibretroSkinImportFailed(LibretroSkinMessages.imageTooLarge));
    }
    final output = File(target);
    output.parent.createSync(recursive: true);
    output.writeAsBytesSync(content, flush: true);
  }
  return _UnpackOutcome.success(digest);
}

/// A `.deltaskin` or `.manicskin` file inside a `.zip`.
bool _isWrappedSkin(_PlannedEntry entry) {
  final name = entry.segments.last.toLowerCase();
  return name.endsWith('.deltaskin') || name.endsWith('.manicskin');
}

/// Segments to strip so that info.json sits at the skin root: none when it
/// is at the archive root, the folder name when every file is inside one
/// top-level folder holding info.json; null when there is no info.json.
List<String>? _skinRoot(List<_PlannedEntry> entries) {
  if (entries.isEmpty) return null;
  if (entries.any((entry) => entry.segments.length == 1 && entry.segments.single == 'info.json')) {
    return const <String>[];
  }
  final top = entries.first.segments.first;
  final single = entries.every((entry) => entry.segments.length > 1 && entry.segments.first == top);
  final hasInfo = entries.any((entry) => entry.segments.length == 2 && entry.segments[1] == 'info.json');
  return single && hasInfo ? <String>[top] : null;
}

/// Decompressed content, never larger than the size the archive declares:
/// a zip bomb stops at the first chunk past that size.
Uint8List _expand(_PlannedEntry entry) {
  final raw = entry.raw();
  if (entry.compressionMethod == 0) {
    if (raw.length != entry.size) throw const _Refusal(_corrupt);
    return raw;
  }
  final sink = _BoundedSink(entry.size);
  final input = ZLibCodec(raw: true).decoder.startChunkedConversion(sink);
  const chunk = 64 * 1024;
  for (var offset = 0; offset < raw.length; offset += chunk) {
    input.add(Uint8List.sublistView(raw, offset, min(offset + chunk, raw.length)));
  }
  input.close();
  final content = sink.takeBytes();
  if (content.length != entry.size) throw const _Refusal(_corrupt);
  return content;
}

class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.limit);

  final int limit;
  final BytesBuilder _bytes = BytesBuilder();

  @override
  void add(List<int> data) {
    if (_bytes.length + data.length > limit) throw const _Refusal(_corrupt);
    _bytes.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _bytes.takeBytes();
}

/// PNG whose IHDR declares a side over [LibretroSkinService.maxImagePixels].
bool _pngTooLarge(Uint8List bytes) {
  const signature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 24) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) return false;
  }
  if (bytes[12] != 0x49 || bytes[13] != 0x48 || bytes[14] != 0x44 || bytes[15] != 0x52) return false;
  final header = ByteData.sublistView(bytes, 16, 24);
  return header.getUint32(0) > LibretroSkinService.maxImagePixels ||
      header.getUint32(4) > LibretroSkinService.maxImagePixels;
}
