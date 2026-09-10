import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:rpcs3_internal_bridge/rpcs3_internal_bridge.dart';

import 'logger_service.dart';
import 'pairing_file_service.dart';
import 'rpcs3_library_service.dart';

enum Rpcs3RuntimePhase {
  idle,
  checkingJit,
  enablingJit,
  jitReady,
  initializingCore,
  ready,
  installingFirmware,
  importingContent,
  launching,
  error,
}

class Rpcs3RuntimeState {
  const Rpcs3RuntimeState({
    required this.phase,
    required this.message,
    required this.jitReady,
    required this.coreReady,
    this.error,
  });

  const Rpcs3RuntimeState.idle()
    : phase = Rpcs3RuntimePhase.idle,
      message = '',
      jitReady = false,
      coreReady = false,
      error = null;

  final Rpcs3RuntimePhase phase;
  final String message;
  final bool jitReady;
  final bool coreReady;
  final String? error;

  bool get busy => switch (phase) {
    Rpcs3RuntimePhase.checkingJit ||
    Rpcs3RuntimePhase.enablingJit ||
    Rpcs3RuntimePhase.initializingCore ||
    Rpcs3RuntimePhase.installingFirmware ||
    Rpcs3RuntimePhase.importingContent ||
    Rpcs3RuntimePhase.launching => true,
    _ => false,
  };
}

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
/// RPCS3 iOS 0.8.1 requires JIT before libRPCS3Core.dylib is dlopened. The
/// Universal JIT is a two-phase transaction: attach, load/initialize the Core
/// while the debugger prepares its arena, then confirm the helper detached.
class Rpcs3InternalService {
  Rpcs3InternalService._();

  static final _log = LoggerService.instance;
  static final _stateController = StreamController<Rpcs3RuntimeState>.broadcast(
    sync: true,
  );

  static const _statusTimeout = Duration(seconds: 5);
  static const _jitTimeout = Duration(minutes: 11);
  static const _coreTimeout = Duration(minutes: 3);
  static const _jitCompletionTimeout = Duration(seconds: 130);
  static const _firmwareInstallTimeout = Duration(minutes: 10);
  static const _contentInstallTimeout = Duration(minutes: 30);

  static Future<void>? _runtimePreparation;
  static bool _initialized = false;
  static bool _jitPrepared = false;
  static Future<void>? _jitPreparation;
  static bool _jitCompletionPending = false;
  static bool _restartRequired = false;
  static Rpcs3RuntimeState _state = const Rpcs3RuntimeState.idle();

  static bool get supported => Platform.isIOS;
  static bool get initialized => _initialized;
  static bool get gameplayMode => _initialized;
  static Rpcs3RuntimeState get runtimeState => _state;
  static Stream<Rpcs3RuntimeState> get runtimeStates => _stateController.stream;

  static void _emit(
    Rpcs3RuntimePhase phase,
    String message, {
    bool? jitReady,
    bool? coreReady,
    String? error,
  }) {
    _state = Rpcs3RuntimeState(
      phase: phase,
      message: message,
      jitReady: jitReady ?? _state.jitReady,
      coreReady: coreReady ?? _initialized,
      error: error,
    );
    _stateController.add(_state);
  }

  static Future<T> _bounded<T>(
    Future<T> future,
    Duration timeout,
    String code,
    String message,
  ) async {
    try {
      return await future.timeout(timeout);
    } on TimeoutException {
      throw Rpcs3InternalException(code, message);
    }
  }

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

  static Future<Map<String, dynamic>> _jitStatus() => _bounded(
    Rpcs3InternalBridge.jitStatus(),
    _statusTimeout,
    'jitStatusTimeout',
    'RPCS3 could not read the current JIT state.',
  );

  static Future<Map<String, dynamic>> diagnostics() async {
    final core = await _bounded(
      Rpcs3InternalBridge.diagnostics(),
      _statusTimeout,
      'diagnosticsTimeout',
      'RPCS3 diagnostics did not respond.',
    );
    final jit = await _jitStatus();
    return <String, dynamic>{
      ...core,
      'jit': jit,
      'jitPrepared': _jitPrepared,
      'runtimeMode': _initialized ? 'ready' : 'stopped',
    };
  }

  static Future<void> _prepareJitInternal() async {
    _emit(
      Rpcs3RuntimePhase.checkingJit,
      'Vérification du JIT RPCS3…',
      coreReady: _initialized,
    );

    // CS_DEBUGGED persists after detach. It is enough for the legacy backend,
    // but never proves that an iOS 26 Universal script is currently attached.
    final current = await _jitStatus();
    if (current['debugged'] == true &&
        current['requiresCoreHandshake'] != true) {
      _jitPrepared = true;
      _emit(
        Rpcs3RuntimePhase.jitReady,
        'JIT RPCS3 déjà actif.',
        jitReady: true,
        coreReady: _initialized,
      );
      _log.i('RPCS3 is reusing the JIT state already active on NeoStation.');
      return;
    }

    _jitPrepared = false;
    if (!await PairingFileService.hasStoredPairingFile()) {
      throw const Rpcs3InternalException(
        'pairingRequired',
        'Import the NeoStation Pairing File before starting RPCS3 JIT.',
      );
    }

    _emit(
      Rpcs3RuntimePhase.enablingJit,
      'Activation du JIT RPCS3 avec StikJIT…',
      jitReady: false,
      coreReady: _initialized,
    );

    final pairing = await PairingFileService.storedFile();
    var readingProgress = false;
    final progress = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (readingProgress) return;
      readingProgress = true;
      try {
        final status = await _jitStatus();
        final message = status['message']?.toString() ?? '';
        if (_state.phase == Rpcs3RuntimePhase.enablingJit &&
            message.isNotEmpty &&
            message != _state.message) {
          _emit(Rpcs3RuntimePhase.enablingJit, message, jitReady: false);
        }
      } catch (_) {
        // Progress is optional; the transaction reports the authoritative error.
      } finally {
        readingProgress = false;
      }
    });
    late final Map<String, dynamic> jit;
    try {
      jit = await _bounded(
        Rpcs3InternalBridge.prepareJit(pairingFilePath: pairing.path),
        _jitTimeout,
        'jitTimeout',
        'La préparation StikJIT/DDI ne répond plus. Relancez NeoStation avant de réessayer.',
      );
    } finally {
      progress.cancel();
    }
    if (jit['success'] != true) {
      throw Rpcs3InternalException(
        'jitFailed',
        jit['message']?.toString() ??
            'StikJIT could not enable JIT for NeoStation.',
      );
    }

    _jitCompletionPending = jit['requiresCompletion'] == true;

    final status = await _jitStatus();
    if (status['debugged'] != true) {
      throw const Rpcs3InternalException(
        'jitNotPersistent',
        'RPCS3 JIT did not remain active after StikJIT detached.',
      );
    }

    // Attached is not ready: Core initialization must still prepare and seal
    // the arena before completeJit can confirm success.
    _emit(
      Rpcs3RuntimePhase.initializingCore,
      'Helper JIT attaché. Préparation de la mémoire RPCS3…',
      jitReady: false,
      coreReady: _initialized,
    );
    _log.i(
      'RPCS3 internal JIT prepared for NeoStation pid=${jit['pid'] ?? 'unknown'}.',
    );
  }

  /// Ensures exactly one JIT transaction can be active at a time.
  static Future<void> _attachJitForCore() async {
    final pending = _jitPreparation;
    if (pending != null) return pending;

    final future = _prepareJitInternal();
    _jitPreparation = future;
    try {
      await future;
    } on Rpcs3InternalException catch (error) {
      _emit(
        Rpcs3RuntimePhase.error,
        error.message,
        jitReady: false,
        coreReady: _initialized,
        error: error.message,
      );
      rethrow;
    } finally {
      if (identical(_jitPreparation, future)) _jitPreparation = null;
    }
  }

  static Future<void> _ensureRuntime() {
    final pending = _runtimePreparation;
    if (pending != null) return pending;
    final future = _initializeRuntime();
    _runtimePreparation = future;
    return future.whenComplete(() {
      if (identical(_runtimePreparation, future)) _runtimePreparation = null;
    });
  }

  static Future<void> _initializeRuntime() async {
    if (!supported) {
      throw const Rpcs3InternalException(
        'unsupported',
        'RPCS3 internal is available on iOS only.',
      );
    }
    if (_restartRequired) {
      throw const Rpcs3InternalException(
        'restartRequired',
        'La transaction JIT précédente est incomplète. Fermez complètement NeoStation puis relancez-le avant de réessayer.',
      );
    }
    if (_initialized) {
      _emit(
        Rpcs3RuntimePhase.ready,
        'RPCS3 Core prêt.',
        jitReady: true,
        coreReady: true,
      );
      return;
    }

    try {
      // Resolve paths before attaching: once attached, advance straight into
      // Core initialization so the Universal script can service its BRKs.
      final data = await dataDirectory();
      final cache = await cacheDirectory();
      final preflight = await _bounded(
        Rpcs3InternalBridge.preflight(),
        _statusTimeout,
        'memoryPreflightTimeout',
        'La vérification mémoire RPCS3 ne répond pas.',
      );
      if (preflight['success'] != true) {
        throw Rpcs3InternalException(
          'memoryUnavailable',
          preflight['message']?.toString() ??
              'iOS refuse l’espace mémoire requis par RPCS3.',
        );
      }
      await _attachJitForCore();
      _emit(
        Rpcs3RuntimePhase.initializingCore,
        'Initialisation du Core RPCS3…',
        jitReady: _jitPrepared,
        coreReady: false,
      );

      final report = await _bounded(
        Rpcs3InternalBridge.initialize(
          supportPath: data.path,
          cachePath: cache.path,
          expandedJitRegion: true,
        ),
        _coreTimeout,
        'coreInitializeTimeout',
        'La préparation mémoire RPCS3 ne répond plus. Relancez NeoStation avant de réessayer.',
      );
      if (report['success'] != true) {
        throw Rpcs3InternalException(
          'coreInitializeFailed',
          report['message']?.toString() ?? 'RPCS3 Core could not initialize.',
        );
      }

      if (_jitCompletionPending) {
        final completion = await _bounded(
          Rpcs3InternalBridge.completeJit(),
          _jitCompletionTimeout,
          'jitCompletionTimeout',
          'Le helper JIT n’a pas confirmé sa fin. Relancez NeoStation avant de réessayer.',
        );
        if (completion['success'] != true) {
          throw Rpcs3InternalException(
            'jitCompletionFailed',
            completion['message']?.toString() ?? 'RPCS3 JIT did not complete.',
          );
        }
        _jitCompletionPending = false;
      }
      _jitPrepared = true;
      _initialized = true;
      _emit(
        Rpcs3RuntimePhase.ready,
        'RPCS3 Core prêt.',
        jitReady: true,
        coreReady: true,
      );
      _log.i('RPCS3 internal Core initialized with validated expanded JIT.');
    } on Rpcs3InternalException catch (error) {
      _restartRequired =
          _jitCompletionPending ||
          error.code == 'jitTimeout' ||
          error.code == 'coreInitializeTimeout';
      _emit(
        Rpcs3RuntimePhase.error,
        error.message,
        jitReady: _jitPrepared,
        coreReady: false,
        error: error.message,
      );
      rethrow;
    } catch (_) {
      _restartRequired = _jitCompletionPending;
      rethrow;
    }
  }

  /// A Universal attach cannot be pre-warmed independently of the Core.
  /// Opening the manager only inspects status; an explicit action starts JIT.
  static Future<void> prepareManager() async {
    await _jitStatus();
  }

  static Future<void> ensureJitReady() => _ensureRuntime();

  static Future<void> ensureManagementInitialized() => _ensureRuntime();
  static Future<void> ensureInitialized() => _ensureRuntime();
  static Future<void> ensureGameplayInitialized() => _ensureRuntime();
  static Future<void> closeManagementRuntime() async {}

  static Future<String> firmwareVersion() async {
    // RPCS3's utils::get_firmware_version reads this same file under dev_flash.
    // Opening a library must not dlopen the Core or request JIT just to read it.
    // Read the actual install every time, including installs from older builds
    // or the manager, instead of trusting a preference flag.
    final data = await dataDirectory();
    final file = File(
      path.join(data.path, 'dev_flash', 'vsh', 'etc', 'version.txt'),
    );
    if (!await file.exists()) return '';
    final size = await file.length();
    if (size == 0 || size > 65536) return '';
    final record = await file.readAsString();
    final match = RegExp(
      r'^release:(\d+)\.(\d+):',
      multiLine: true,
    ).firstMatch(record.trim());
    if (match == null) return '';
    final major = int.tryParse(match.group(1)!);
    if (major == null) return '';
    var minor = match.group(2)!;
    while (minor.length > 2 && minor.endsWith('0')) {
      minor = minor.substring(0, minor.length - 1);
    }
    return '$major.${minor.padRight(2, '0')}';
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
    // Present the picker immediately. JIT/Core preparation happens only after
    // the user has actually selected a firmware file.
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
      stagedPath = await _stageFirmware(sourcePath);
      await ensureManagementInitialized();
      _emit(
        Rpcs3RuntimePhase.installingFirmware,
        'Installation du firmware PS3…',
        jitReady: true,
        coreReady: true,
      );
      final report = await _bounded(
        Rpcs3InternalBridge.installFirmware(stagedPath),
        _firmwareInstallTimeout,
        'firmwareInstallTimeout',
        'L’installation du firmware RPCS3 a dépassé 10 minutes.',
      );
      if (report['success'] != true) {
        throw Rpcs3InternalException(
          'firmwareInstallFailed',
          report['message']?.toString() ?? 'RPCS3 rejected the PS3 firmware.',
        );
      }

      final version = (await _bounded(
        Rpcs3InternalBridge.firmwareVersion(),
        _statusTimeout,
        'firmwareStatusTimeout',
        'RPCS3 did not confirm the installed firmware.',
      )).trim();
      if (version.isEmpty) {
        throw const Rpcs3InternalException(
          'firmwareVerificationFailed',
          'RPCS3 did not report an installed firmware after import.',
        );
      }
      _emit(
        Rpcs3RuntimePhase.ready,
        'Firmware PS3 installé. RPCS3 est prêt.',
        jitReady: true,
        coreReady: true,
      );
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

    await ensureManagementInitialized();
    _emit(
      Rpcs3RuntimePhase.importingContent,
      'Import des jeux PS3…',
      jitReady: true,
      coreReady: true,
    );

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
        report = await _bounded(
          Rpcs3InternalBridge.installPackage(sourcePath),
          _contentInstallTimeout,
          'gameImportTimeout',
          '${item.name}: RPCS3 import timed out.',
        );
      } else if (extension == '.zip') {
        report = await _bounded(
          Rpcs3InternalBridge.installZip(sourcePath),
          _contentInstallTimeout,
          'gameImportTimeout',
          '${item.name}: RPCS3 import timed out.',
        );
      } else if (extension == '.iso') {
        final key = File(path.setExtension(sourcePath, '.key'));
        report = await _bounded(
          Rpcs3InternalBridge.installIso(
            sourcePath,
            keyPath: await key.exists() ? key.path : null,
          ),
          _contentInstallTimeout,
          'gameImportTimeout',
          '${item.name}: RPCS3 import timed out.',
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
    _emit(
      Rpcs3RuntimePhase.ready,
      'RPCS3 prêt.',
      jitReady: true,
      coreReady: true,
    );
    return Rpcs3ImportResult(
      imported: imported,
      rejected: rejected,
      errors: errors,
    );
  }

  static Future<bool> importExtractedGameFolder() async {
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Import extracted PlayStation 3 game folder',
    );
    if (folder == null) return false;

    await ensureManagementInitialized();
    _emit(
      Rpcs3RuntimePhase.importingContent,
      'Import du dossier PS3…',
      jitReady: true,
      coreReady: true,
    );
    final report = await _bounded(
      Rpcs3InternalBridge.installFolder(folder),
      _contentInstallTimeout,
      'gameImportTimeout',
      'RPCS3 folder import timed out.',
    );
    if (report['success'] != true) {
      throw Rpcs3InternalException(
        'gameImportFailed',
        report['message']?.toString() ?? 'RPCS3 rejected the selected folder.',
      );
    }
    await Rpcs3LibraryService.syncInternalLibrary();
    _emit(
      Rpcs3RuntimePhase.ready,
      'RPCS3 prêt.',
      jitReady: true,
      coreReady: true,
    );
    return true;
  }

  static Future<bool> launchTitle(String titleId, {String? savestateId}) async {
    final normalized = titleId.trim().toUpperCase();
    if (normalized.isEmpty) return false;

    await ensureGameplayInitialized();
    final firmware = (await _bounded(
      Rpcs3InternalBridge.firmwareVersion(),
      _statusTimeout,
      'firmwareStatusTimeout',
      'RPCS3 did not return the firmware state.',
    )).trim();
    if (firmware.isEmpty) {
      throw const Rpcs3InternalException(
        'firmwareRequired',
        'PlayStation 3 firmware is required before launching a game.',
      );
    }

    _emit(
      Rpcs3RuntimePhase.launching,
      'Lancement du jeu PS3…',
      jitReady: true,
      coreReady: true,
    );
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
    _emit(
      Rpcs3RuntimePhase.ready,
      'RPCS3 en cours d’exécution.',
      jitReady: true,
      coreReady: true,
    );
    return true;
  }

  static Future<bool> stop() => Rpcs3InternalBridge.stop();
}
