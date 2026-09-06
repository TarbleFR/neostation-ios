import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:external_folder_access/external_folder_access.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import '../l10n/dolphin_import_locale.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'logger_service.dart';
import 'dolphin_system_files.dart';
import 'dolphin_save_store.dart';

/// IPL slots exposed by the native GameCube playlist.
enum DolphinIplRegion { usa, eur, jap }

class DolphinImportResult {
  final int imported;
  final int rejected;
  final List<String> errors;

  const DolphinImportResult({
    required this.imported,
    required this.rejected,
    this.errors = const [],
  });
}

class DolphinLaunchReport {
  final bool ready;
  final String message;
  final String? failedStage;
  final String logPath;
  final Map<String, bool> gates;

  const DolphinLaunchReport({
    required this.ready,
    required this.message,
    required this.logPath,
    required this.gates,
    this.failedStage,
  });
}

/// Owns the private Dolphin library and the strict native launch transaction.
///
/// The service is intentionally not a general emulator router. Every public
/// entry point rejects any system other than `gc` or `wii` before touching JIT,
/// storage, Metal or the native core.
class DolphinInternalV2Service {
  DolphinInternalV2Service._();

  static const MethodChannel _channel = MethodChannel(
    'neostation/dolphin_internal',
  );
  static final _log = LoggerService.instance;
  static bool _systemImportBusy = false;
  static bool _launchInProgress = false;
  static Future<void>? _layoutFuture;
  static Future<void>? _saveAccessFuture;
  static String? _saveSessionToken;
  static Future<void> Function()? _onSaveSessionStopped;
  static bool _saveHandlerInstalled = false;

  /// Scoped exclusion with launches and system-file imports, not a global JIT
  /// switch. Failure/unknown native state refuses filesystem synchronization.
  static Future<T> withSaveAccess<T>(Future<T> Function(DolphinSaveStore store) action) async {
    final previous = _saveAccessFuture;
    final done = Completer<void>();
    _saveAccessFuture = done.future;
    if (previous != null) await previous;
    try {
      return await _withSystemImport(() async {
        final root = await rootDirectory();
        final store = DolphinSaveStore(Directory(path.join(root.path, 'User')),
          Directory(path.join(root.path, 'SaveCache')));
        await store.recover();
        return action(store);
      });
    } finally {
      if (identical(_saveAccessFuture, done.future)) _saveAccessFuture = null;
      done.complete();
    }
  }

  static Future<void> logSaveSync(String stage, String message) =>
      _appendLog('cloud-saves.$stage', message);

  static Future<DolphinSaveIdentity> readSaveIdentity(String folderName, String gamePath) async {
    final system = _normalizeSystem(folderName);
    final library = await libraryDirectory(system);
    final realLibrary = await library.resolveSymbolicLinks();
    final realGame = await File(gamePath).resolveSymbolicLinks();
    if (!path.isWithin(realLibrary, realGame)) throw const FormatException('Dolphin save identity: foreign ROM');
    final data = await _channel.invokeMapMethod<String, dynamic>('saveIdentity',
      {'system': system, 'gamePath': realGame});
    if (data == null) throw const FormatException('Dolphin cannot read the native save identity');
    return DolphinSaveIdentity.fromMap(data);
  }

  static void _installSaveSessionHandler() {
    if (_saveHandlerInstalled) return;
    _saveHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'saveSessionStopped' || call.arguments is! Map) return;
      final data = call.arguments as Map;
      if (data['savesFlushed'] != true || data['token'] != _saveSessionToken) return;
      final callback = _onSaveSessionStopped;
      _saveSessionToken = null;
      _onSaveSessionStopped = null;
      final root = await rootDirectory();
      await _deleteIfExists(File(path.join(root.path, 'CrashMarkers', 'active-session.json')));
      await _appendLog('cloud-saves.saves_flushed', 'Native Dolphin stopped; save synchronization is now permitted.');
      if (callback != null) {
        try { await callback(); }
        catch (error) { await _appendLog('cloud-saves.after_close_failed', '$error'); }
      }
    });
  }

  static const Set<String> _gameCubeExtensions = {
    'iso',
    'gcm',
    'ciso',
    'gcz',
    'rvz',
    'wia',
    'tgc',
  };
  static const Set<String> _wiiExtensions = {
    'iso',
    'ciso',
    'gcz',
    'rvz',
    'wia',
    'wbfs',
    'wad',
  };

  static const int _iplSize = 2 * 1024 * 1024;
  static const Set<int> _ntscIplCrc32 = {
    0x6DAC1F2A,
    0xD5E6FEEA,
    0xD235E3F9,
    0x86573808,
    0x667D0B64,
  };
  static const Set<int> _palIplCrc32 = {
    0x4F319F43,
    0xAD1B7F16,
  };

  static bool isDolphinSystem(String folderName) {
    final normalized = folderName.trim().toLowerCase();
    return normalized == 'gc' || normalized == 'wii';
  }

  static Set<String> extensionsFor(String folderName) {
    switch (_normalizeSystem(folderName)) {
      case 'gc':
        return _gameCubeExtensions;
      case 'wii':
        return _wiiExtensions;
      default:
        return const {};
    }
  }

  static Future<Directory> rootDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(path.join(support.path, 'NeoStation', 'Dolphin'));
  }

  /// Hidden root used only by the gc/wii-specific scanner branch.
  static Future<String> scanRootPath() async {
    final root = await rootDirectory();
    return path.join(root.path, 'Library');
  }

  static Future<Directory> libraryDirectory(String folderName) async {
    final system = _normalizeSystem(folderName);
    final root = await rootDirectory();
    return Directory(path.join(root.path, 'Library', system));
  }

  static Future<void> ensureLayout() async {
    // Share initialization across the scanner, the import menu and logging.
    // Recreating User/Wii during a snapshot rename could obstruct the commit.
    final future = _layoutFuture ??= _initializeLayout();
    try {
      await future;
    } catch (_) {
      if (identical(_layoutFuture, future)) _layoutFuture = null;
      rethrow;
    }
  }

  static Future<void> _initializeLayout() async {
    final root = await rootDirectory();
    for (final name in ['Wii', 'GC']) {
      await DolphinSystemFiles.recover(Directory(path.join(root.path, 'User', name)));
    }
    final directories = <String>[
      'Library/gc',
      'Library/wii',
      'User/Config',
      'User/GC/USA',
      'User/GC/EUR',
      'User/GC/JAP',
      'User/Wii',
      'User/StateSaves',
      'User/Load/Textures',
      'User/Dump',
      'Saves',
      'ShaderCache',
      'Logs',
      'Metadata/IPL',
      'CrashMarkers',
    ];
    for (final relative in directories) {
      await Directory(path.join(root.path, relative)).create(recursive: true);
    }
    await DolphinSaveStore(Directory(path.join(root.path, 'User')),
      Directory(path.join(root.path, 'SaveCache'))).recover();
    await sharedSystemDirectory('wii');
    await _recoverPreviousCrash(root);
  }

  static Future<DolphinImportResult> importGames(String folderName) async {
    final system = _normalizeSystem(folderName);
    await ensureLayout();
    final extensions = extensionsFor(system).toList()..sort();
    final selection = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: extensions,
      withData: false,
      lockParentWindow: true,
    );
    if (selection == null) {
      return const DolphinImportResult(imported: 0, rejected: 0);
    }

    final destination = await libraryDirectory(system);
    await destination.create(recursive: true);
    var imported = 0;
    var rejected = 0;
    final errors = <String>[];

    for (final picked in selection.files) {
      final sourcePath = picked.path;
      final extension = path.extension(picked.name).replaceFirst('.', '').toLowerCase();
      if (sourcePath == null || !extensions.contains(extension)) {
        rejected++;
        errors.add('${picked.name}: unsupported $system image extension.');
        continue;
      }
      final source = File(sourcePath);
      if (!await source.exists()) {
        rejected++;
        errors.add('${picked.name}: source file is not readable.');
        continue;
      }

      try {
        final output = await _uniqueDestination(destination, picked.name);
        await source.copy(output.path);
        final sourceLength = await source.length();
        final outputLength = await output.length();
        if (sourceLength <= 0 || sourceLength != outputLength) {
          await _deleteIfExists(output);
          throw FileSystemException('Copied image length mismatch');
        }
        imported++;
        await _appendLog(
          'import.game_complete',
          'Imported ${picked.name} into the private $system library.',
          {'system': system, 'bytes': outputLength},
        );
      } catch (error) {
        rejected++;
        errors.add('${picked.name}: $error');
        await _appendLog(
          'import.game_failed',
          'Could not import ${picked.name}.',
          {'system': system, 'error': '$error'},
        );
      }
    }
    return DolphinImportResult(
      imported: imported,
      rejected: rejected,
      errors: errors,
    );
  }

  static Future<bool> importIpl(DolphinIplRegion region) => _withSystemImport(() async {
    await ensureLayout();
    final selection = await FilePicker.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['bin'],
      withData: true,
      lockParentWindow: true,
    );
    if (selection == null || selection.files.isEmpty) return false;

    final picked = selection.files.single;
    Uint8List? bytes = picked.bytes;
    if (bytes == null && picked.path != null) {
      bytes = await File(picked.path!).readAsBytes();
    }
    if (bytes == null) {
      throw const FormatException('The selected IPL could not be read.');
    }
    await _installIpl(bytes, region);
    return true;
  });

  static Future<void> _installIpl(Uint8List bytes, DolphinIplRegion region) async {
    final validation = _validateIpl(bytes, region);
    if (!validation.accepted) {
      await _appendLog(
        'ipl.rejected',
        validation.reason,
        {
          'slot': region.name.toUpperCase(),
          'size': bytes.length,
          'crc32': validation.crc32.toRadixString(16).padLeft(8, '0'),
        },
      );
      throw FormatException(validation.reason);
    }

    final root = await rootDirectory();
    final slot = region.name.toUpperCase();
    await DolphinSystemFiles.replaceSnapshot(
      Directory(path.join(root.path, 'User', 'GC')),
      (stage) async {
        final target = File(path.join(stage.path, slot, 'IPL.bin'));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes, flush: true);
        return 1;
      },
      merge: true,
    );

    final manifest = File(path.join(root.path, 'Metadata', 'IPL', '$slot.json'));
    await manifest.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'slot': slot,
        'size': bytes.length,
        'crc32': validation.crc32.toRadixString(16).padLeft(8, '0').toUpperCase(),
        'nintendoHeader': validation.nintendoHeader,
        'artXHeader': validation.artXHeader,
        'knownDump': true,
        'installedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    await _appendLog(
      'ipl.accepted',
      'Validated and installed IPL $slot.',
      {'slot': slot, 'crc32': validation.crc32},
    );
  }

  static Future<Set<DolphinIplRegion>> installedIplRegions() async {
    await ensureLayout();
    final root = await rootDirectory();
    final installed = <DolphinIplRegion>{};
    for (final region in DolphinIplRegion.values) {
      final slot = region.name.toUpperCase();
      final file = File(path.join(root.path, 'User', 'GC', slot, 'IPL.bin'));
      if (!await file.exists()) continue;
      try {
        final bytes = await file.readAsBytes();
        if (_validateIpl(bytes, region).accepted) installed.add(region);
      } catch (_) {
        // A stale/tampered file is never shown as installed.
      }
    }
    return installed;
  }

  static Future<T> _withSystemImport<T>(Future<T> Function() action) async {
    if (_systemImportBusy || _launchInProgress) {
      throw const DolphinSystemFilesException('busy');
    }
    _systemImportBusy = true;
    try {
      if (await _channel.invokeMethod<bool>('isRunning') != false) {
        throw const DolphinSystemFilesException('busy');
      }
      await ensureLayout();
      return await action();
    } finally {
      _systemImportBusy = false;
    }
  }

  /// Visible in Files > On My iPhone > NeoStation > Dolphin. These are
  /// import folders, not the live NAND; copying here cannot alter a running game.
  static Future<Directory> sharedSystemDirectory(String folderName) async {
    final system = _normalizeSystem(folderName);
    final documents = await getApplicationDocumentsDirectory();
    final shared = Directory(path.join(documents.path, 'Dolphin'));
    for (final name in ['Wii', 'GameCube/USA', 'GameCube/EUR', 'GameCube/JAP']) {
      await Directory(path.join(shared.path, name)).create(recursive: true);
    }
    return Directory(path.join(shared.path, system == 'wii' ? 'Wii' : 'GameCube'));
  }

  static Future<int?> importSystemFolder(String folderName, {bool fromShared = false}) =>
      _withSystemImport(() async {
        final system = _normalizeSystem(folderName);
        const bookmark = 'dolphin-system-import';
        try {
          final selected = fromShared
              ? (await sharedSystemDirectory(system)).path
              : await ExternalFolderAccess.pickAndActivateFolder(key: bookmark);
          if (selected == null) return null;
          final root = await rootDirectory();
          if (system == 'wii') {
            return await DolphinSystemFiles.importWiiFolder(
              Directory(selected), Directory(path.join(root.path, 'User', 'Wii')),
            );
          }
          // Accept GC, GameCube, User/GC or their parent; never confuse a Wii
          // keys.bin with an IPL. Validate every selected slot before writing.
          final images = <DolphinIplRegion, Uint8List>{};
          for (final suffix in ['', 'GC', 'GameCube', 'User/GC']) {
            for (final region in DolphinIplRegion.values) {
              final file = File(path.join(selected, suffix, region.name.toUpperCase(), 'IPL.bin'));
              if (!await file.exists()) continue;
              final real = await file.resolveSymbolicLinks();
              final sourceRoot = await Directory(selected).resolveSymbolicLinks();
              if (!path.isWithin(sourceRoot, real)) {
                throw const DolphinSystemFilesException('unsafePath');
              }
              final bytes = await file.readAsBytes();
              if (!_validateIpl(bytes, region).accepted) {
                throw const DolphinSystemFilesException('invalidIpl');
              }
              images[region] = bytes;
            }
            if (images.isNotEmpty) break;
          }
          if (images.isEmpty) throw const DolphinSystemFilesException('invalidGameCube');
          return await DolphinSystemFiles.replaceSnapshot(
            Directory(path.join(root.path, 'User', 'GC')),
            (stage) async {
              for (final entry in images.entries) {
                final file = File(path.join(stage.path, entry.key.name.toUpperCase(), 'IPL.bin'));
                await file.parent.create(recursive: true);
                await file.writeAsBytes(entry.value, flush: true);
              }
              return images.length;
            }, merge: true,
          );
        } finally {
          if (!fromShared) await ExternalFolderAccess.clearBookmark(key: bookmark);
        }
      });

  static Future<int?> importWiiSystemFiles() => _withSystemImport(() async {
    final selection = await FilePicker.pickFiles(
      allowMultiple: true, type: FileType.custom,
      allowedExtensions: const ['bin', 'pem'], withData: false,
    );
    if (selection == null) return null;
    if (selection.files.any((file) => file.path == null ||
        !DolphinSystemFiles.wiiFiles.contains(file.name))) {
      throw const DolphinSystemFilesException('invalidWiiFile');
    }
    final root = await rootDirectory();
    return DolphinSystemFiles.importWiiFiles(
      selection.files.map((file) => File(file.path!)).toList(),
      Directory(path.join(root.path, 'User', 'Wii')),
    );
  });

  static Future<DolphinLaunchReport> launch({
    required String folderName,
    required String gamePath,
    String? gameTitle,
    Future<void> Function()? onSessionStopped,
  }) => _launchSession(
    folderName: folderName,
    gamePath: gamePath,
    gameTitle: gameTitle,
    onSessionStopped: onSessionStopped,
  );

  /// Boots the user's installed NAND title, with the same JIT and session
  /// exclusion as a game. A menu session has no ROM identity or iCloud Saves game
  /// callback, so it cannot be mistaken for the previously played Wii title.
  static Future<DolphinLaunchReport> launchWiiMenu() => _launchSession(
    folderName: 'wii',
    wiiSystemMenu: true,
    gameTitle: DolphinImportLocale.labelsFor(
      FlutterLocalization.instance.currentLocale,
    )['wiiMenuTitle'],
  );

  static Future<DolphinLaunchReport> _launchSession({
    required String folderName,
    String? gamePath,
    String? gameTitle,
    bool wiiSystemMenu = false,
    Future<void> Function()? onSessionStopped,
  }) async {
    // Let an already-started save transaction finish before opening the core.
    if (_saveAccessFuture != null) await _saveAccessFuture;
    if (_systemImportBusy || _launchInProgress) {
      throw const DolphinSystemFilesException('busy');
    }
    _launchInProgress = true;
    var ownsSaveCallback = false;
    try {
      if (await _channel.invokeMethod<bool>('isRunning') != false) {
        throw const DolphinSystemFilesException('busy');
      }
      _installSaveSessionHandler();
      ownsSaveCallback = true;
      _saveSessionToken = '${DateTime.now().microsecondsSinceEpoch}';
      _onSaveSessionStopped = onSessionStopped;
      final report = await _launch(
        folderName: folderName, gamePath: gamePath, gameTitle: gameTitle,
        wiiSystemMenu: wiiSystemMenu,
      );
      if (!report.ready) { _saveSessionToken = null; _onSaveSessionStopped = null; }
      return report;
    } catch (_) {
      if (ownsSaveCallback) {
        _saveSessionToken = null;
        _onSaveSessionStopped = null;
      }
      rethrow;
    } finally {
      _launchInProgress = false;
    }
  }

  static Future<DolphinLaunchReport> _launch({
    required String folderName,
    String? gamePath,
    String? gameTitle,
    required bool wiiSystemMenu,
  }) async {
    final system = _normalizeSystem(folderName);
    await ensureLayout();
    final root = await rootDirectory();
    final library = await libraryDirectory(system);
    final normalizedGame = wiiSystemMenu ? '' : path.normalize(path.absolute(gamePath!));
    final normalizedLibrary = path.normalize(path.absolute(library.path));
    if (wiiSystemMenu) {
      await DolphinSystemFiles.requireWiiMenuMetadata(
        Directory(path.join(root.path, 'User', 'Wii')),
      );
    } else if (!path.isWithin(normalizedLibrary, normalizedGame)) {
      final logPath = await _sessionLogPath();
      await _appendLogTo(
        logPath,
        'route.path_rejected',
        'The selected path is outside the private $system library.',
      );
      return DolphinLaunchReport(
        ready: false,
        message: 'This game is not stored in NeoStation’s private Dolphin library.',
        failedStage: 'route.path_rejected',
        logPath: logPath,
        gates: _emptyGates(),
      );
    }
    final extension = path.extension(normalizedGame).replaceFirst('.', '').toLowerCase();
    if (!wiiSystemMenu && !extensionsFor(system).contains(extension)) {
      final logPath = await _sessionLogPath();
      await _appendLogTo(logPath, 'image.extension_rejected', 'Unsupported $system image extension: $extension.');
      return DolphinLaunchReport(
        ready: false,
        message: 'This file format is not accepted for $system.',
        failedStage: 'image.extension_rejected',
        logPath: logPath,
        gates: _emptyGates(),
      );
    }

    final pairing = await _locatePairingFile();
    final logPath = await _sessionLogPath();
    final marker = File(path.join(root.path, 'CrashMarkers', 'active-session.json'));
    if (pairing == null) {
      await _appendLogTo(logPath, 'stikjit.pairing_missing', 'No readable pairing file was found.');
      return DolphinLaunchReport(
        ready: false,
        message: 'Import a pairing file in NeoStation before launching Dolphin.',
        failedStage: 'stikjit.pairing_missing',
        logPath: logPath,
        gates: _emptyGates(),
      );
    }

    final systemDirectory = path.join(
      path.dirname(Platform.resolvedExecutable),
      'Sys',
    );
    await marker.writeAsString(
      jsonEncode({
        'state': 'preparing',
        'system': system,
        'bootKind': wiiSystemMenu ? 'wiiSystemMenu' : 'game',
        if (!wiiSystemMenu) 'gamePath': normalizedGame,
        'logPath': logPath,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );

    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'launchGame',
        {
          'system': system,
          'bootKind': wiiSystemMenu ? 'wiiSystemMenu' : 'game',
          'saveSessionToken': _saveSessionToken,
          'menuLabels': DolphinImportLocale.labelsFor(FlutterLocalization.instance.currentLocale),
          if (!wiiSystemMenu) 'gamePath': normalizedGame,
          'gameTitle': gameTitle?.trim().isNotEmpty == true
              ? gameTitle!.trim() : path.basenameWithoutExtension(normalizedGame),
          'userDirectory': path.join(root.path, 'User'),
          'systemDirectory': systemDirectory,
          'logPath': logPath,
          'pairingFilePath': pairing.path,
        },
      );
      final response = Map<String, dynamic>.from(raw ?? const {});
      final gates = <String, bool>{
        'stikjitConnected': response['stikjitConnected'] == true,
        'pidAttached': response['pidAttached'] == true,
        'legacyHandshakeValidated': response['legacyHandshakeValidated'] == true,
        'executableMemoryValidated': response['executableMemoryValidated'] == true,
        'jitArm64Initialized': response['jitArm64Initialized'] == true,
        'metalInitialized': response['metalInitialized'] == true,
        'imageAccepted': response['imageAccepted'] == true,
        'gameSubmitted': response['gameSubmitted'] == true,
      };
      final ready = response['success'] == true && gates.values.every((gate) => gate);
      final message = response['message']?.toString() ??
          (ready ? 'Dolphin started.' : 'Dolphin launch was refused.');
      final failedStage = response['failedStage']?.toString();

      if (ready) {
        await marker.writeAsString(
          jsonEncode({
            'state': 'running',
            'system': system,
            'bootKind': wiiSystemMenu ? 'wiiSystemMenu' : 'game',
            if (!wiiSystemMenu) 'gamePath': normalizedGame,
            'logPath': logPath,
            'authorizedAt': DateTime.now().toUtc().toIso8601String(),
          }),
          flush: true,
        );
      } else {
        await _deleteIfExists(marker);
      }
      await _appendLogTo(
        logPath,
        ready ? 'launch.ready' : 'launch.refused',
        message,
        {'gates': gates, if (failedStage != null) 'failedStage': failedStage},
      );
      return DolphinLaunchReport(
        ready: ready,
        message: message,
        failedStage: failedStage,
        logPath: logPath,
        gates: gates,
      );
    } on PlatformException catch (error) {
      await _deleteIfExists(marker);
      await _appendLogTo(
        logPath,
        'bridge.platform_exception',
        error.message ?? error.code,
        {'code': error.code, 'details': '${error.details}'},
      );
      return DolphinLaunchReport(
        ready: false,
        message: error.message ?? 'The native Dolphin bridge failed.',
        failedStage: error.code,
        logPath: logPath,
        gates: _emptyGates(),
      );
    } catch (error, stackTrace) {
      await _deleteIfExists(marker);
      await _appendLogTo(
        logPath,
        'bridge.exception',
        '$error',
        {'stack': '$stackTrace'},
      );
      return DolphinLaunchReport(
        ready: false,
        message: 'Dolphin launch failed: $error',
        failedStage: 'bridge.exception',
        logPath: logPath,
        gates: _emptyGates(),
      );
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } finally {
      final root = await rootDirectory();
      final marker = File(
        path.join(root.path, 'CrashMarkers', 'active-session.json'),
      );
      await _deleteIfExists(marker);
      await _appendLog('session.clean_stop', 'Dolphin session stopped cleanly.');
    }
  }

  static String _normalizeSystem(String folderName) {
    final normalized = folderName.trim().toLowerCase();
    if (normalized != 'gc' && normalized != 'wii') {
      throw ArgumentError.value(
        folderName,
        'folderName',
        'The internal Dolphin engine only accepts gc or wii.',
      );
    }
    return normalized;
  }

  static Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort cleanup never replaces the original diagnostic.
    }
  }

  static Future<File> _uniqueDestination(Directory directory, String name) async {
    final safe = path.basename(name).replaceAll(RegExp(r'[\x00-\x1f]'), '_');
    var candidate = File(path.join(directory.path, safe));
    var suffix = 1;
    while (await candidate.exists()) {
      candidate = File(
        path.join(
          directory.path,
          '${path.basenameWithoutExtension(safe)} ($suffix)${path.extension(safe)}',
        ),
      );
      suffix++;
    }
    return candidate;
  }

  static _IplValidation _validateIpl(
    Uint8List bytes,
    DolphinIplRegion region,
  ) {
    final crc = _crc32(bytes);
    if (bytes.length != _iplSize) {
      return _IplValidation(false, 'A retail GameCube IPL must be exactly 2 MiB.', crc);
    }
    final header = latin1.decode(bytes.sublist(0, 0x100), allowInvalid: true);
    final hasNintendo = header.contains('Nintendo');
    final hasArtX = header.contains('ArtX Inc.');
    if (!hasNintendo || !hasArtX) {
      return _IplValidation(
        false,
        'The IPL header does not contain the expected Nintendo and ArtX identifiers.',
        crc,
        nintendoHeader: hasNintendo,
        artXHeader: hasArtX,
      );
    }
    final allBlank = bytes.every((byte) => byte == 0x00 || byte == 0xFF);
    if (allBlank) {
      return _IplValidation(false, 'The IPL content is blank.', crc);
    }
    final knownForSlot = region == DolphinIplRegion.eur
        ? _palIplCrc32.contains(crc)
        : _ntscIplCrc32.contains(crc);
    if (!knownForSlot) {
      return _IplValidation(
        false,
        'The IPL CRC32 is not a known retail dump for the selected region family.',
        crc,
        nintendoHeader: hasNintendo,
        artXHeader: hasArtX,
      );
    }
    return _IplValidation(
      true,
      'Valid retail IPL.',
      crc,
      nintendoHeader: hasNintendo,
      artXHeader: hasArtX,
    );
  }

  static int _crc32(Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (final value in data) {
      crc ^= value;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0
            ? (crc >> 1) ^ 0xEDB88320
            : crc >> 1;
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static Future<File?> _locatePairingFile() async {
    final roots = <Directory>[
      await getApplicationDocumentsDirectory(),
      await getApplicationSupportDirectory(),
    ];
    final preferredNames = <String>{
      'pairingfile.plist',
      'pairingfile.mobiledevicepairing',
      'pairrecord.plist',
    };
    File? fallback;
    for (final root in roots) {
      if (!await root.exists()) continue;
      try {
        await for (final entity in root.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final relative = path.relative(entity.path, from: root.path);
          if (path.split(relative).length > 6) continue;
          final lower = path.basename(entity.path).toLowerCase();
          if (!lower.contains('pair') || await entity.length() < 128) continue;
          if (preferredNames.contains(lower)) return entity;
          fallback ??= entity;
        }
      } catch (_) {
        // Continue to the next app-owned root.
      }
    }
    return fallback;
  }

  static Map<String, bool> _emptyGates() => {
        'stikjitConnected': false,
        'pidAttached': false,
        'legacyHandshakeValidated': false,
        'executableMemoryValidated': false,
        'jitArm64Initialized': false,
        'metalInitialized': false,
        'imageAccepted': false,
        'gameSubmitted': false,
      };

  static Future<String> _sessionLogPath() async {
    final root = await rootDirectory();
    final name = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    return path.join(root.path, 'Logs', 'dolphin-$name.jsonl');
  }

  static Future<void> _appendLog(
    String stage,
    String message, [
    Map<String, dynamic>? details,
  ]) async {
    await ensureLayout();
    final root = await rootDirectory();
    await _appendLogTo(
      path.join(root.path, 'Logs', 'dolphin-persistent.jsonl'),
      stage,
      message,
      details,
    );
  }

  static Future<void> _appendLogTo(
    String logPath,
    String stage,
    String message, [
    Map<String, dynamic>? details,
  ]) async {
    final entry = <String, dynamic>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'engine': 'dolphin_internal',
      'stage': stage,
      'message': message,
      if (details != null) ...details,
    };
    await File(logPath).parent.create(recursive: true);
    await File(logPath).writeAsString(
      '${jsonEncode(entry)}\n',
      mode: FileMode.append,
      flush: true,
    );
    _log.i('[DolphinInternal][$stage] $message');
  }

  static Future<void> _recoverPreviousCrash(Directory root) async {
    final marker = File(path.join(root.path, 'CrashMarkers', 'active-session.json'));
    if (!await marker.exists()) return;
    try {
      final payload = jsonDecode(await marker.readAsString());
      final state = payload is Map ? payload['state']?.toString() : null;
      final logPath = payload is Map ? payload['logPath']?.toString() : null;
      final stage = state == 'running'
          ? 'crash.after_launch_detected'
          : 'crash.before_launch_detected';
      if (logPath != null && logPath.isNotEmpty) {
        await _appendLogTo(logPath, stage, 'NeoStation recovered an unclosed Dolphin session marker.');
      }
      await marker.rename('${marker.path}.${DateTime.now().millisecondsSinceEpoch}.recovered');
    } catch (_) {
      await _deleteIfExists(marker);
    }
  }
}

class _IplValidation {
  final bool accepted;
  final String reason;
  final int crc32;
  final bool nintendoHeader;
  final bool artXHeader;

  const _IplValidation(
    this.accepted,
    this.reason,
    this.crc32, {
    this.nintendoHeader = false,
    this.artXHeader = false,
  });
}
