import 'dart:async';
import 'dart:io';

import '../data/datasources/sqlite_service.dart';
import 'rpcs3_game_deletion.dart';
import 'rpcs3_startup_transaction.dart';
import 'game_launch_manager.dart';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:rpcs3_internal_bridge/rpcs3_internal_bridge.dart';

import 'logger_service.dart';
import 'local_dev_vpn_route_service.dart';
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
/// The ABI-compatible RPCS3 iOS Core with v0.9-era JIT backports requires JIT before libRPCS3Core.dylib is dlopened. The
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

  static final _startup = Rpcs3StartupTransaction();
  static bool _initialized = false;
  static bool _libraryMutationInProgress = false;
  static bool _jitPrepared = false;
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

  static Future<Map<String, dynamic>> _prepareJitInternal() async {
    final transactionTimer = Stopwatch()..start();
    _emit(
      Rpcs3RuntimePhase.checkingJit,
      'Vérification du JIT RPCS3…',
      coreReady: _initialized,
    );

    // CS_DEBUGGED is diagnostic information only. It never authorizes a new
    // RPCS3 startup by itself: every launch transaction performs one explicit
    // StikJIT prepare/attach and later proves generated-code execution.
    _jitPrepared = false;
    if (!await PairingFileService.hasStoredPairingFile()) {
      throw const Rpcs3InternalException(
        'RPCS3_PAIRING_FILE_INVALID',
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
    // Do not poll JIT state while StikJIT owns the startup transaction. The
    // prepareJit result is authoritative for connect/attach readiness.
    late final Map<String, dynamic> jit;
    final attachTimer = Stopwatch()..start();
    jit = await _bounded(
      Rpcs3InternalBridge.prepareJit(pairingFilePath: pairing.path),
      _jitTimeout,
      'RPCS3_JIT_PREPARATION_TIMEOUT',
      'La préparation StikJIT/DDI ne répond plus.',
    );
    if (jit['success'] != true) {
      final rawMessage =
          jit['message']?.toString() ??
          'StikJIT could not enable JIT for NeoStation.';
      throw Rpcs3InternalException(
        jit['code']?.toString() ?? 'RPCS3_JIT_ATTACH_FAILED',
        rawMessage,
      );
    }

    _log.i(
      'RPCS3 startup timing: stage=debugger_attach; '
      'elapsedMs=${attachTimer.elapsedMilliseconds}; '
      'helperConnectedMs=${jit['helperConnectedMs'] ?? 'unknown'}; '
      'debuggerAttachedMs=${jit['debuggerAttachedMs'] ?? 'unknown'}; '
      'transactionMs=${transactionTimer.elapsedMilliseconds}.',
    );

    // Attached is not ready: Core initialization must still prepare and seal
    // the arena before completeJit can confirm success.
    _emit(
      Rpcs3RuntimePhase.initializingCore,
      'Helper JIT attaché. Initialisation du Core RPCS3…',
      jitReady: false,
      coreReady: _initialized,
    );
    _log.i(
      'RPCS3 debugger attached to NeoStation pid=${jit['pid'] ?? 'unknown'}; '
      'final Core-load nonce proof pending.',
    );
    return jit;
  }

  static Future<void> _ensureRuntime() {
    if (_libraryMutationInProgress) {
      throw const Rpcs3InternalException(
        'libraryBusy',
        'A game deletion is still running.',
      );
    }
    return _initializeRuntime();
  }

  static Future<void> _initializeRuntime() async {
    if (!supported) {
      throw const Rpcs3InternalException(
        'unsupported',
        'RPCS3 internal is available on iOS only.',
      );
    }
    late Directory data;
    late Directory cache;
    Future<Map<String, dynamic>> native(
      Future<Map<String, dynamic>> operation,
      Duration timeout,
      String code,
      String message,
    ) async {
      try {
        return await _bounded(operation, timeout, code, message);
      } on Rpcs3InternalException catch (error) {
        throw Rpcs3StartupFailure(
          error.code,
          error.message,
          _startup.phase.name,
        );
      }
    }

    try {
      await _startup.ensure(
        Rpcs3StartupOperations(
          route: () async {
            try {
              await LocalDevVpnRouteService.ensureReachable();
            } on LocalDevVpnRouteException catch (error) {
              throw Rpcs3StartupFailure(
                'RPCS3_ROUTE_UNAVAILABLE',
                '${error.message} (nativeRouteCode=${error.code})',
                'route',
              );
            }
            return {'success': true};
          },
          attach: () async {
            try {
              return await _prepareJitInternal();
            } on Rpcs3InternalException catch (error) {
              throw Rpcs3StartupFailure(error.code, error.message, 'attach');
            }
          },
          initialize: () async {
            data = await dataDirectory();
            cache = await cacheDirectory();
            return native(
              Rpcs3InternalBridge.initialize(
                supportPath: data.path,
                cachePath: cache.path,
                expandedJitRegion: false,
              ),
              _coreTimeout,
              'RPCS3_CORE_INITIALIZE_TIMEOUT',
              'Le Core ne répond pas à initialize.',
            );
          },
          complete: () => native(
            Rpcs3InternalBridge.completeJit(),
            _jitCompletionTimeout,
            'RPCS3_JIT_DETACH_TIMEOUT',
            'La fermeture de la transaction JIT n’est pas confirmée.',
          ),
          verify: () => native(
            Rpcs3InternalBridge.verifyJitExecution(),
            const Duration(seconds: 30),
            'RPCS3_JIT_EXECUTION_TEST_TIMEOUT',
            'Le test d’exécution JIT ne répond pas.',
          ),
          abort: () => native(
            Rpcs3InternalBridge.abortStartup(),
            _jitCompletionTimeout,
            'RPCS3_STARTUP_ABORT_TIMEOUT',
            'L’annulation n’est pas confirmée. L’erreur initiale est conservée.',
          ),
          onPhase: (phase) {
            final ready = phase == Rpcs3StartupPhase.ready;
            _jitPrepared = ready;
            _initialized = ready;
            if (ready) {
              _emit(
                Rpcs3RuntimePhase.ready,
                'RPCS3 prêt : JIT, Core, détachement et exécution vérifiés.',
                jitReady: true,
                coreReady: true,
              );
            } else if (phase != Rpcs3StartupPhase.blocked &&
                phase != Rpcs3StartupPhase.idle) {
              _emit(
                Rpcs3RuntimePhase.initializingCore,
                switch (phase) {
                  Rpcs3StartupPhase.route =>
                    'Vérification de la route LocalDevVPN…',
                  Rpcs3StartupPhase.attaching =>
                    'Attachement StikJIT au processus NeoStation…',
                  Rpcs3StartupPhase.initializing =>
                    'Préparation du Core et de la mémoire JIT…',
                  Rpcs3StartupPhase.completing =>
                    'Confirmation de fermeture du helper JIT…',
                  Rpcs3StartupPhase.verifying =>
                    'Test d’exécution du code JIT…',
                  Rpcs3StartupPhase.aborting =>
                    'Annulation de la transaction et libération des ressources…',
                  _ => phase.name,
                },
                jitReady: false,
                coreReady: false,
              );
            }
          },
        ),
      );
    } on Rpcs3StartupFailure catch (error) {
      _emit(
        Rpcs3RuntimePhase.error,
        error.message,
        jitReady: false,
        coreReady: false,
        error: error.message,
      );
      throw Rpcs3InternalException(error.code, error.message);
    }
  }

  /// A Universal attach cannot be pre-warmed independently of the Core.
  /// Opening the manager only inspects status; an explicit action starts JIT.
  static Future<void> prepareManager() async {
    await _jitStatus();
  }

  static Future<void> ensureJitReady() => _ensureRuntime();

  static Future<void> ensureManagementInitialized() => _ensureRuntime();

  /// Management of files must remain usable when VPN/JIT/Core startup fails.
  static Future<void> deleteInstalledGame(String titleId) async {
    if (_libraryMutationInProgress ||
        _startup.inProgress ||
        GameLaunchManager().isActive ||
        _state.phase == Rpcs3RuntimePhase.importingContent) {
      throw const Rpcs3InternalException(
        'libraryBusy',
        'Stop the current launch or import before deleting a game.',
      );
    }
    _libraryMutationInProgress = true;
    final id = titleId.trim().toUpperCase();
    _log.i('Rpcs3Delete[$id] begin; coreInitialized=$_initialized');
    try {
      if (_initialized) {
        final emulation = await Rpcs3InternalBridge.emulationState();
        if (emulation != 0 && emulation != 1) {
          throw const Rpcs3InternalException(
            'gameRunning',
            'Stop emulation before deleting a game.',
          );
        }
      }
      final root = await dataDirectory();
      await Rpcs3GameDeletion.delete(dataRoot: root.path, titleId: id);
      _log.i('Rpcs3Delete[$id] filesystem_and_registration_complete');
      await SqliteService.deleteRpcs3Title(id);
      await Rpcs3LibraryService.forgetDeletedTitle(id);
      await Rpcs3LibraryService.syncInternalLibrary();
      _log.i('Rpcs3Delete[$id] database_cache_and_ui_complete');
    } catch (error, stack) {
      _log.e('Rpcs3Delete[$id] failed', error: error, stackTrace: stack);
      rethrow;
    } finally {
      _libraryMutationInProgress = false;
    }
  }

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

  /// Publishes a detached snapshot of RPCS3's user saves in NeoStation's
  /// Documents container. iOS exposes that container in Files, while the live
  /// RPCS3 tree remains in Application Support where the Core expects it.
  ///
  /// The export contains regular PS3 savedata and RPCS3 savestates only.
  /// Firmware, games, caches, trophies and configuration stay private.
  static Future<Directory> exportSaveData() async {
    if (!supported) {
      throw const Rpcs3InternalException(
        'unsupported',
        'RPCS3 save export is available on iOS only.',
      );
    }

    final data = await dataDirectory();
    final sources = <String, Directory>{
      'Game Saves': Directory(
        path.join(data.path, 'dev_hdd0', 'home', '00000001', 'savedata'),
      ),
      'Savestates': Directory(path.join(data.path, 'savestates')),
    };

    final documents = await getApplicationDocumentsDirectory();
    final exportRoot = Directory(path.join(documents.path, 'RPCS3'));
    await exportRoot.create(recursive: true);
    final destination = Directory(path.join(exportRoot.path, 'Saves'));
    final staging = Directory(
      path.join(
        exportRoot.path,
        '.Saves-${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    final previous = Directory(path.join(exportRoot.path, '.Saves.previous'));

    var copiedFiles = 0;
    try {
      await staging.create(recursive: true);
      for (final entry in sources.entries) {
        final source = entry.value;
        if (!await source.exists()) continue;
        await for (final entity in source.list(
          recursive: true,
          followLinks: false,
        )) {
          final relative = path.relative(entity.path, from: source.path);
          if (relative == '.' ||
              relative == '..' ||
              relative.startsWith('../')) {
            continue;
          }
          final target = path.join(staging.path, entry.key, relative);
          if (entity is Directory) {
            await Directory(target).create(recursive: true);
          } else if (entity is File) {
            await Directory(path.dirname(target)).create(recursive: true);
            await entity.copy(target);
            copiedFiles++;
          }
        }
      }

      if (copiedFiles == 0) {
        throw const Rpcs3InternalException(
          'saveDataEmpty',
          'Aucune sauvegarde RPCS3 n’est encore disponible à exporter.',
        );
      }

      // Prepare the full snapshot before swapping it into place. If the final
      // rename fails, restore the previous exported copy; RPCS3's live saves
      // are never moved or modified by this operation.
      if (await previous.exists()) {
        await previous.delete(recursive: true);
      }
      if (await destination.exists()) {
        await destination.rename(previous.path);
      }
      try {
        final exported = await staging.rename(destination.path);
        if (await previous.exists()) {
          await previous.delete(recursive: true);
        }
        return exported;
      } catch (_) {
        if (!(await destination.exists()) && (await previous.exists())) {
          await previous.rename(destination.path);
        }
        rethrow;
      }
    } on Rpcs3InternalException {
      rethrow;
    } catch (error) {
      throw Rpcs3InternalException(
        'saveExportFailed',
        'Impossible de préparer les sauvegardes RPCS3 : $error',
      );
    } finally {
      if (await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {}
      }
      if ((await previous.exists()) && !(await destination.exists())) {
        try {
          await previous.rename(destination.path);
        } catch (_) {}
      }
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

  static Future<File> _bootCrashMarker() async {
    final cache = await cacheDirectory();
    return File(path.join(cache.path, 'incomplete-boot-title.txt'));
  }

  static Future<void> _consumePreviousIncompleteBootMarker(
    String titleId,
  ) async {
    final marker = await _bootCrashMarker();
    if (!await marker.exists()) return;

    String previous = '';
    try {
      previous = (await marker.readAsString()).trim().toUpperCase();
    } catch (_) {}
    try {
      await marker.delete();
    } catch (_) {}

    if (previous != titleId) return;

    // A process crash does not prove that RPCS3's compiled PPU cache is
    // corrupt. Build 283 deleted it automatically, forcing expensive
    // recompilation/linking on the next attempt. Preserve the cache and let
    // RPCS3 validate/reuse it normally.
    _log.w(
      'RPCS3 previous boot for $titleId ended before RUNNING; '
      'preserving the title PPU cache for the retry.',
    );
  }

  static Future<File> _armBootCrashMarker(String titleId) async {
    final marker = await _bootCrashMarker();
    await marker.writeAsString(titleId, flush: true);
    return marker;
  }

  static Future<void> _clearBootCrashMarkerWhenRunning(File marker) async {
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final state = await Rpcs3InternalBridge.emulationState().timeout(
          const Duration(seconds: 2),
        );
        // ABI 30: 5=running, 6=paused.
        if (state == 5 || state == 6) {
          if (await marker.exists()) await marker.delete();
          return;
        }
        if (state == 1) {
          // A clean stop is not a process crash and must not poison next boot.
          if (await marker.exists()) await marker.delete();
          return;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  static Future<bool> launchTitle(
    String titleId, {
    required String uiLocale,
    String? savestateId,
  }) async {
    final normalized = titleId.trim().toUpperCase();
    if (normalized.isEmpty) return false;

    final launchTimer = Stopwatch()..start();
    await ensureGameplayInitialized();
    _log.i(
      'RPCS3 launch timing $normalized: stage=runtime_ready; '
      'elapsedMs=${launchTimer.elapsedMilliseconds}.',
    );
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

    await _consumePreviousIncompleteBootMarker(normalized);

    _emit(
      Rpcs3RuntimePhase.launching,
      'Lancement du jeu PS3…',
      jitReady: true,
      coreReady: true,
    );

    final bootMarker = await _armBootCrashMarker(normalized);
    final bootTimer = Stopwatch()..start();
    final report = await Rpcs3InternalBridge.launchGame(
      titleId: normalized,
      uiLocale: uiLocale,
      savestateId: savestateId,
    );
    if (report['success'] != true) {
      try {
        if (await bootMarker.exists()) await bootMarker.delete();
      } catch (_) {}
      throw Rpcs3InternalException(
        report['code']?.toString() ?? 'RPCS3_GAME_BOOT_FAILED',
        report['message']?.toString() ?? 'RPCS3 could not boot this game.',
      );
    }
    _log.i(
      'RPCS3 launch timing $normalized: stage=boot_submitted; '
      'bootMs=${bootTimer.elapsedMilliseconds}; '
      'totalMs=${launchTimer.elapsedMilliseconds}.',
    );

    // boot_game may return before PPU linking reaches RUNNING. Keep the marker
    // until the Core actually publishes RUNNING/PAUSED so an abrupt process
    // death during PPU linking can be recovered on the next launch.
    unawaited(_clearBootCrashMarkerWhenRunning(bootMarker));

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
