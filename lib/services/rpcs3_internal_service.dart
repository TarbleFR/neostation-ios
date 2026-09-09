import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:rpcs3_internal_bridge/rpcs3_internal_bridge.dart';

import 'logger_service.dart';
import 'pairing_file_service.dart';
import 'rpcs3_library_service.dart';

class Rpcs3ImportResult {
  const Rpcs3ImportResult({
    required this.imported,
    required this.rejected,
    this.errors = const [],
  });

  final int imported;
  final int rejected;
  final List<String> errors;
}

class Rpcs3InternalException implements Exception {
  const Rpcs3InternalException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'Rpcs3InternalException($code, $message)';
}

/// Owns the in-process PlayStation 3 engine embedded in NeoStation iOS.
///
/// RPCS3 iOS 0.8.1 requires JIT to be active before libRPCS3Core.dylib is
/// dlopened, including for firmware/content management. NeoStation therefore
/// prepares and validates JIT first, loads one expanded RPCS3 runtime, and then
/// uses that same runtime for firmware installation, game import and direct
/// title boot. The standalone RPCS3 SwiftUI application is never launched.
class Rpcs3InternalService {
  Rpcs3InternalService._();

  static final _log = LoggerService.instance;
  static bool _initializing = false;
  static bool _initialized = false;
  static bool _jitPrepared = false;

  static bool get supported => Platform.isIOS;
  static bool get initialized => _initialized;
  static bool get gameplayMode => _initialized;

  static Future<Directory> rootDirectory() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(path.join(support.path, 'NeoStation', 'RPCS3'));
    await root.create(recursive: true);
    return root;
  }

  static Future<Directory> dataDirectory() async {
    final root = await rootDirectory();
    final directory = Directory(path.join(root.path, 'Data'));
    await directory.create(recursive: true);
    return directory;
  }

  static Future<Directory> cacheDirectory() async {
    final root = await rootDirectory();
    final directory = Directory(path.join(root.path, 'Cache'));
    await directory.create(recursive: true);
    return directory;
  }

  static Future<Map<String, dynamic>> diagnostics() async {
    final core = await Rpcs3InternalBridge.diagnostics();
    final jit = await Rpcs3InternalBridge.jitStatus();
    return <String, dynamic>{
      ...core,
      'jit': jit,
      'jitPrepared': _jitPrepared,
      'runtimeMode': _initialized ? 'ready' : 'stopped',
    };
  }

  static Future<void> _ensureJit() async {
    if (_jitPrepared) {
      final current = await Rpcs3InternalBridge.jitStatus();
      if (current['debugged'] == true) return;
      _jitPrepared = false;
    }

    if (!await PairingFileService.hasStoredPairingFile()) {
      throw const Rpcs3InternalException(
        'pairingRequired',
        'Import the NeoStation Pairing File before opening RPCS3 or installing PS3 firmware/games.',
      );
    }

    final pairing = await PairingFileService.storedFile();
    final jit = await Rpcs3InternalBridge.prepareJit(
      pairingFilePath: pairing.path,
    );
    if (jit['success'] != true) {
      throw Rpcs3InternalException(
        'jitFailed',
        jit['message']?.toString() ??
            'StikJIT could not enable JIT for NeoStation.',
      );
    }

    final status = await Rpcs3InternalBridge.jitStatus();
    if (status['debugged'] != true) {
      throw const Rpcs3InternalException(
        'jitNotPersistent',
        'RPCS3 JIT did not remain active after StikJIT detached.',
      );
    }

    _jitPrepared = true;
    _log.i(
      'RPCS3 internal JIT prepared for NeoStation pid=${jit['pid'] ?? 'unknown'}.',
    );
  }

  static Future<void> _ensureRuntime() async {
    if (!supported) {
      throw const Rpcs3InternalException(
        'unsupported',
        'RPCS3 internal is available on iOS only.',
      );
    }
    if (_initialized) return;

    if (_initializing) {
      while (_initializing) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_initialized) return;
      return _ensureRuntime();
    }

    _initializing = true;
    try {
      // RPCS3's own iOS loader requires JIT before dlopen. Do not move this
      // below initialize(): the Core reserves its JIT arena while loading.
      await _ensureJit();

      final data = await dataDirectory();
      final cache = await cacheDirectory();
      final report = await Rpcs3InternalBridge.initialize(
        supportPath: data.path,
        cachePath: cache.path,
        expandedJitRegion: true,
      );
      if (report['success'] != true) {
        throw Rpcs3InternalException(
          'coreInitializeFailed',
          report['message']?.toString() ?? 'RPCS3 Core could not initialize.',
        );
      }

      _initialized = true;
      _log.i('RPCS3 internal Core initialized with validated expanded JIT.');
    } finally {
      _initializing = false;
    }
  }

  /// Opens the internal RPCS3 runtime for firmware/content management.
  /// RPCS3 0.8.1 still requires JIT before its Core can be loaded.
  static Future<void> ensureManagementInitialized() => _ensureRuntime();

  static Future<void> ensureInitialized() => _ensureRuntime();

  static Future<void> ensureGameplayInitialized() => _ensureRuntime();

  /// Closing the manager only closes NeoStation's manager UI. The Core remains
  /// loaded with the same JIT-arena policy so a later game can boot directly;
  /// RPCS3 itself treats changing that policy after dlopen as relaunch-only.
  static Future<void> closeManagementRuntime() async {}

  static Future<String> firmwareVersion() async {
    await ensureManagementInitialized();
    return (await Rpcs3InternalBridge.firmwareVersion()).trim();
  }

  static Future<bool> hasFirmware() async {
    try {
      return (await firmwareVersion()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _stageFirmware(String sourcePath) async {
    final root = await rootDirectory();
    final imports = Directory(path.join(root.path, 'Imports'));
    await imports.create(recursive: true);
    final staged = File(
      path.join(
        imports.path,
        'PS3UPDAT-${DateTime.now().microsecondsSinceEpoch}.PUP',
      ),
    );
    await File(sourcePath).copy(staged.path);
    return staged.path;
  }

  static Future<bool> importFirmware() async {
    // Prepare RPCS3 before presenting the document picker. This mirrors the
    // standalone loader and ensures the selected security-scoped file is used
    // immediately instead of waiting for a long JIT transaction afterwards.
    await ensureManagementInitialized();

    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Select official PS3UPDAT.PUP firmware',
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['pup'],
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return false;

    final sourcePath = picked.files.single.path;
    if (sourcePath == null || !await File(sourcePath).exists()) {
      throw const Rpcs3InternalException(
        'firmwareUnreadable',
        'The selected PS3 firmware is unreadable.',
      );
    }

    String? stagedPath;
    try {
      // Keep a private copy while the native installer runs. This avoids the
      // iOS document-picker security scope disappearing mid-install.
      stagedPath = await _stageFirmware(sourcePath);
      final report = await Rpcs3InternalBridge.installFirmware(stagedPath);
      if (report['success'] != true) {
        throw Rpcs3InternalException(
          'firmwareInstallFailed',
          report['message']?.toString() ?? 'RPCS3 rejected the PS3 firmware.',
        );
      }

      final version = (await Rpcs3InternalBridge.firmwareVersion()).trim();
      if (version.isEmpty) {
        throw const Rpcs3InternalException(
          'firmwareVerificationFailed',
          'RPCS3 did not report an installed firmware after import.',
        );
      }
      _log.i('RPCS3 firmware installed successfully: $version');
      return true;
    } finally {
      if (stagedPath != null) {
        try {
          await File(stagedPath).delete();
        } catch (_) {}
      }
    }
  }

  static Future<Rpcs3ImportResult> importGames() async {
    await ensureManagementInitialized();

    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Import PlayStation 3 games',
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['pkg', 'iso', 'zip'],
      withData: false,
    );
    if (picked == null) {
      return const Rpcs3ImportResult(imported: 0, rejected: 0);
    }

    var imported = 0;
    var rejected = 0;
    final errors = <String>[];
    for (final item in picked.files) {
      final sourcePath = item.path;
      if (sourcePath == null || !await File(sourcePath).exists()) {
        rejected++;
        errors.add('${item.name}: unreadable file.');
        continue;
      }

      final extension = path.extension(item.name).toLowerCase();
      Map<String, dynamic> report;
      if (extension == '.pkg') {
        report = await Rpcs3InternalBridge.installPackage(sourcePath);
      } else if (extension == '.zip') {
        report = await Rpcs3InternalBridge.installZip(sourcePath);
      } else if (extension == '.iso') {
        final key = File(path.setExtension(sourcePath, '.key'));
        report = await Rpcs3InternalBridge.installIso(
          sourcePath,
          keyPath: await key.exists() ? key.path : null,
        );
      } else {
        report = const <String, dynamic>{
          'success': false,
          'message': 'Unsupported game format.',
        };
      }

      if (report['success'] == true) {
        imported++;
      } else {
        rejected++;
        errors.add(
          '${item.name}: ${report['message'] ?? 'RPCS3 import failed.'}',
        );
      }
    }

    await Rpcs3LibraryService.syncInternalLibrary();
    return Rpcs3ImportResult(
      imported: imported,
      rejected: rejected,
      errors: errors,
    );
  }

  static Future<bool> importExtractedGameFolder() async {
    await ensureManagementInitialized();

    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Import extracted PlayStation 3 game folder',
    );
    if (folder == null) return false;

    final report = await Rpcs3InternalBridge.installFolder(folder);
    if (report['success'] != true) {
      throw Rpcs3InternalException(
        'gameImportFailed',
        report['message']?.toString() ?? 'RPCS3 rejected the selected folder.',
      );
    }
    await Rpcs3LibraryService.syncInternalLibrary();
    return true;
  }

  static Future<bool> launchTitle(String titleId, {String? savestateId}) async {
    final normalized = titleId.trim().toUpperCase();
    if (normalized.isEmpty) return false;

    await ensureGameplayInitialized();
    final firmware = (await Rpcs3InternalBridge.firmwareVersion()).trim();
    if (firmware.isEmpty) {
      throw const Rpcs3InternalException(
        'firmwareRequired',
        'PlayStation 3 firmware is required before launching a game.',
      );
    }

    // Direct Core boot: no standalone RPCS3 Start/Commencer screen is ever
    // presented. NeoStation calls rpcs3_ios_boot_game for the selected title.
    final report = await Rpcs3InternalBridge.launchGame(
      titleId: normalized,
      savestateId: savestateId,
    );
    if (report['success'] != true) {
      throw Rpcs3InternalException(
        'bootFailed',
        report['message']?.toString() ?? 'RPCS3 could not boot this game.',
      );
    }
    return true;
  }

  static Future<bool> stop() => Rpcs3InternalBridge.stop();
}
