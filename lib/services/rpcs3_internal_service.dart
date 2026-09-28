import 'dart:async';
import 'dart:io';

import '../data/datasources/sqlite_service.dart';
import 'rpcs3_game_deletion.dart';
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

  static Future<void>? _runtimePreparation;
  static bool _initialized = false;
  static bool _libraryMutationInProgress = false;
  static bool _jitPrepared = false;
  static Rpcs3RuntimeState _state = const Rpcs3RuntimeState.idle();

  static bool get supported => Platform.isIOS;
  static bool get initialized => _initialized;
  static bool get jitPrepared => _jitPrepared;
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

  static Future<Directory> filesWorkspaceDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final root = Directory(path.join(documents.path, 'RPCS3'));
    await root.create(recursive: true);
    for (final relative in const <String>[
      'Import/Game Saves',
      'Import/Savestates',
      'Export/Game Saves',
      'Export/Savestates',
    ]) {
      await Directory(path.join(root.path, relative)).create(recursive: true);
    }
    final readme = File(path.join(root.path, 'README.txt'));
    if (!await readme.exists()) {
      await readme.writeAsString(
        'NeoStation RPCS3 manual save exchange\n\n'
        'Import/Game Saves     : place PS3 savedata folders here.\n'
        'Import/Savestates     : place .SAVESTAT/.zst/.gz states here.\n'
        'Export/Game Saves     : current savedata snapshot from RPCS3.\n'
        'Export/Savestates     : current RPCS3 savestate snapshot.\n\n'
        'Import is consumed automatically when NeoStation starts.\n'
        'Export is refreshed automatically at startup.\n',
        flush: true,
      );
    }
    return root;
  }

  static bool _allowedSavestateFile(String filePath) {
    final lower = filePath.toLowerCase();
    return lower.endsWith('.savestat') ||
        lower.endsWith('.savestat.zst') ||
        lower.endsWith('.savestat.gz');
  }

  static Future<void> _copyReplacing(File source, File target) async {
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.neostation-sync-tmp');
    if (await temp.exists()) await temp.delete();
    await source.copy(temp.path);
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
  }

  static Future<int> _copyTree({
    required Directory source,
    required Directory destination,
    required bool savestates,
    required bool consumeSource,
  }) async {
    if (!await source.exists()) return 0;
    await destination.create(recursive: true);
    var copied = 0;
    await for (final entity in source.list(recursive: true, followLinks: false)) {
      final relative = path.relative(entity.path, from: source.path);
      if (relative == '.' || relative == '..' || relative.startsWith('../')) continue;
      final targetPath = path.join(destination.path, relative);
      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
        continue;
      }
      if (entity is! File || path.basename(entity.path) == '.DS_Store') continue;
      if (savestates && !_allowedSavestateFile(entity.path)) continue;
      await _copyReplacing(entity, File(targetPath));
      copied++;
      if (consumeSource) {
        try { await entity.delete(); } catch (_) {}
      }
    }
    return copied;
  }

  /// Physical Files workspace: consumes Import then refreshes Export.
  static Future<({int imported, int exported})> synchronizeFilesWorkspace() async {
    if (!supported) return (imported: 0, exported: 0);
    final workspace = await filesWorkspaceDirectory();
    final data = await dataDirectory();

    var imported = 0;
    imported += await _copyTree(
      source: Directory(path.join(workspace.path, 'Import', 'Game Saves')),
      destination: Directory(path.join(data.path, 'dev_hdd0', 'home', '00000001', 'savedata')),
      savestates: false,
      consumeSource: true,
    );
    imported += await _copyTree(
      source: Directory(path.join(workspace.path, 'Import', 'Savestates')),
      destination: Directory(path.join(data.path, 'savestates')),
      savestates: true,
      consumeSource: true,
    );

    final exportRoot = Directory(path.join(workspace.path, 'Export'));
    if (await exportRoot.exists()) await exportRoot.delete(recursive: true);
    await Directory(path.join(exportRoot.path, 'Game Saves')).create(recursive: true);
    await Directory(path.join(exportRoot.path, 'Savestates')).create(recursive: true);

    var exported = 0;
    exported += await _copyTree(
      source: Directory(path.join(data.path, 'dev_hdd0', 'home', '00000001', 'savedata')),
      destination: Directory(path.join(workspace.path, 'Export', 'Game Saves')),
      savestates: false,
      consumeSource: false,
    );
    exported += await _copyTree(
      source: Directory(path.join(data.path, 'savestates')),
      destination: Directory(path.join(workspace.path, 'Export', 'Savestates')),
      savestates: true,
      consumeSource: false,
    );
    return (imported: imported, exported: exported);
  }

  static Future<Map<String, dynamic>> _jitStatus() => _bounded(
    Rpcs3InternalBridge.jitStatus(),
    _statusTimeout,
    'jitStatusTimeout',
    'RPCS3 could not read the current JIT state.',
  );

  /// UI-level JIT state. Unlike the RPCS3 Core launch gate, this intentionally
  /// accepts the kernel CS_DEBUGGED bit as proof that integrated StikJIT has
  /// enabled JIT for the current NeoStation process. The stricter live
  /// debugger/nonce handshake remains mandatory for Core loading.
  static Future<bool> jitEnabledForUi() async {
    if (!supported) return false;
    if (_jitPrepared || _state.jitReady) return true;
    try {
      final status = await _jitStatus();
      return status['debugged'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> diagnostics() async {
    final core = await _bounded(
      Rpcs3InternalBridge.diagnostics(),
      _statusTimeout,
      'diagnosticsTimeout',
      'RPCS3 diagnostics did not respond.',
    );
    final jit = await _jitStatus();
    final jitEnabled =
        _jitPrepared || _state.jitReady || jit['debugged'] == true;
    return <String, dynamic>{
      ...core,
      'jit': jit,
      'jitPrepared': _jitPrepared,
      'jitEnabled': jitEnabled,
      'runtimeMode': _initialized ? 'ready' : 'stopped',
    };
  }

  /// Single RPCS3 startup owner.
  ///
  /// The launch path is deliberately linear:
  /// LocalDevVPN route -> pairing -> StikJIT attach -> Core load/initialize
  /// -> helper completion -> ready. There is no automatic retry, Core shutdown,
  /// JIT status polling, memory preflight, watchdog, fallback, or second attach.
  static Future<void> _ensureRuntime() {
    if (_libraryMutationInProgress) {
      throw const Rpcs3InternalException(
        'libraryBusy',
        'A game deletion is still running.',
      );
    }
    if (_initialized) return Future<void>.value();

    final pending = _runtimePreparation;
    if (pending != null) return pending;

    final future = _initializeRuntime();
    _runtimePreparation = future;
    return future.whenComplete(() {
      if (identical(_runtimePreparation, future)) {
        _runtimePreparation = null;
      }
    });
  }

  static Future<void> _initializeRuntime() async {
    if (!supported) {
      throw const Rpcs3InternalException(
        'unsupported',
        'RPCS3 internal is available on iOS only.',
      );
    }
    if (_initialized) return;

    // Manual Files imports belong to the explicit RPCS3 launch path, never
    // NeoStation cold startup. This keeps the physical Import folder useful
    // without delaying the app's first real frame.
    try {
      await synchronizeFilesWorkspace();
    } catch (error) {
      _log.w('RPCS3 Files workspace preflight failed: $error');
    }

    var completionPending = false;
    try {
      _emit(
        Rpcs3RuntimePhase.checkingJit,
        'Vérification de la route LocalDevVPN…',
        jitReady: false,
        coreReady: false,
      );
      try {
        await LocalDevVpnRouteService.ensureReachable();
      } on LocalDevVpnRouteException catch (error) {
        throw Rpcs3InternalException(
          'RPCS3_ROUTE_UNAVAILABLE',
          '${error.message} (nativeRouteCode=${error.code})',
        );
      }

      if (!await PairingFileService.hasStoredPairingFile()) {
        throw const Rpcs3InternalException(
          'RPCS3_PAIRING_FILE_INVALID',
          'Import the NeoStation Pairing File before starting RPCS3 JIT.',
        );
      }

      final data = await dataDirectory();
      final cache = await cacheDirectory();
      final pairing = await PairingFileService.storedFile();

      _emit(
        Rpcs3RuntimePhase.enablingJit,
        'Activation du JIT RPCS3 avec StikJIT…',
        jitReady: false,
        coreReady: false,
      );
      final jit = await _bounded(
        Rpcs3InternalBridge.prepareJit(pairingFilePath: pairing.path),
        _jitTimeout,
        'RPCS3_JIT_PREPARATION_TIMEOUT',
        'La préparation StikJIT/DDI ne répond plus.',
      );
      if (jit['success'] != true) {
        throw Rpcs3InternalException(
          jit['code']?.toString() ?? 'RPCS3_JIT_ATTACH_FAILED',
          jit['message']?.toString() ??
              'StikJIT could not attach NeoStation.',
        );
      }
      completionPending = jit['requiresCompletion'] == true;

      _emit(
        Rpcs3RuntimePhase.initializingCore,
        'Initialisation du Core RPCS3…',
        jitReady: false,
        coreReady: false,
      );
      final core = await _bounded(
        Rpcs3InternalBridge.initialize(
          supportPath: data.path,
          cachePath: cache.path,
          expandedJitRegion: false,
        ),
        _coreTimeout,
        'RPCS3_CORE_INITIALIZE_TIMEOUT',
        'Le Core RPCS3 ne répond pas à initialize.',
      );
      if (core['success'] != true) {
        throw Rpcs3InternalException(
          core['code']?.toString() ?? 'RPCS3_CORE_INITIALIZE_FAILED',
          core['message']?.toString() ?? 'RPCS3 Core could not initialize.',
        );
      }

      if (completionPending) {
        final completion = await _bounded(
          Rpcs3InternalBridge.completeJit(),
          _jitCompletionTimeout,
          'RPCS3_JIT_DETACH_TIMEOUT',
          'La fermeture de la transaction JIT n’est pas confirmée.',
        );
        if (completion['success'] != true) {
          throw Rpcs3InternalException(
            completion['code']?.toString() ?? 'RPCS3_JIT_DETACH_FAILED',
            completion['message']?.toString() ??
                'RPCS3 JIT helper did not detach cleanly.',
          );
        }
        completionPending = false;
      }

      _jitPrepared = true;
      _initialized = true;
      _emit(
        Rpcs3RuntimePhase.ready,
        'RPCS3 prêt.',
        jitReady: true,
        coreReady: true,
      );
      _log.i('RPCS3 minimal startup complete.');
    } on Rpcs3InternalException catch (error) {
      // Cleanup only the helper transaction. Never shutdown or reinitialize the
      // Core automatically: a failed startup remains the original failure.
      if (completionPending) {
        try {
          await Rpcs3InternalBridge.completeJit().timeout(
            _jitCompletionTimeout,
          );
        } catch (_) {}
      }
      _jitPrepared = false;
      _emit(
        Rpcs3RuntimePhase.error,
        error.message,
        jitReady: false,
        coreReady: false,
        error: error.message,
      );
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

  /// Management of files must remain usable when VPN/JIT/Core startup fails.
  static Future<void> deleteInstalledGame(String titleId) async {
    if (_libraryMutationInProgress ||
        _runtimePreparation != null ||
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

    final exportRoot = await filesWorkspaceDirectory();
    final destination = Directory(path.join(exportRoot.path, 'Export'));
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
        await Directory(path.join(staging.path, entry.key)).create(recursive: true);
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

  /// Restores user-managed PS3 saves and RPCS3 savestates from the Files-visible
  /// exchange folder created by [exportSaveData].
  ///
  /// Users may edit/copy files in:
  /// On My iPhone/NeoStation/RPCS3/Import/Game Saves
  /// On My iPhone/NeoStation/RPCS3/Import/Savestates
  /// and then call this method to copy them back into RPCS3's private live tree.
  static Future<int> importSaveDataFromFiles() async {
    if (!supported) {
      throw const Rpcs3InternalException(
        'unsupported',
        'RPCS3 save import is available on iOS only.',
      );
    }
    if (_libraryMutationInProgress ||
        _runtimePreparation != null ||
        GameLaunchManager().isActive ||
        _state.phase == Rpcs3RuntimePhase.importingContent) {
      throw const Rpcs3InternalException(
        'saveImportBusy',
        'Stop the current game or RPCS3 operation before importing saves.',
      );
    }

    final workspace = await filesWorkspaceDirectory();
    final exchangeRoot = Directory(path.join(workspace.path, 'Import'));
    if (!await exchangeRoot.exists()) {
      await Directory(path.join(exchangeRoot.path, 'Game Saves')).create(recursive: true);
      await Directory(path.join(exchangeRoot.path, 'Savestates')).create(recursive: true);
      throw const Rpcs3InternalException(
        'saveImportFolderMissing',
        'Le dossier RPCS3/Import vient d’être créé dans Fichiers. Ajoutez vos fichiers dans Game Saves ou Savestates, puis relancez Importer.',
      );
    }
    await Directory(path.join(exchangeRoot.path, 'Game Saves')).create(recursive: true);
    await Directory(path.join(exchangeRoot.path, 'Savestates')).create(recursive: true);

    final data = await dataDirectory();
    final mappings = <({String sourceName, Directory destination, bool savestate})>[
      (
        sourceName: 'Game Saves',
        destination: Directory(
          path.join(data.path, 'dev_hdd0', 'home', '00000001', 'savedata'),
        ),
        savestate: false,
      ),
      (
        sourceName: 'Savestates',
        destination: Directory(path.join(data.path, 'savestates')),
        savestate: true,
      ),
    ];

    _libraryMutationInProgress = true;
    var copiedFiles = 0;
    try {
      for (final mapping in mappings) {
        final source = Directory(path.join(exchangeRoot.path, mapping.sourceName));
        if (!await source.exists()) continue;
        await mapping.destination.create(recursive: true);

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
          final targetPath = path.join(mapping.destination.path, relative);

          if (entity is Directory) {
            await Directory(targetPath).create(recursive: true);
            continue;
          }
          if (entity is! File) continue;

          if (mapping.savestate) {
            final name = entity.path.toLowerCase();
            final valid =
                name.endsWith('.savestat') ||
                name.endsWith('.savestat.zst') ||
                name.endsWith('.savestat.gz');
            if (!valid) continue;
          } else if (path.basename(entity.path) == '.DS_Store') {
            continue;
          }

          await Directory(path.dirname(targetPath)).create(recursive: true);
          final target = File(targetPath);
          final backup = File('$targetPath.neostation-import-backup');
          if (await backup.exists()) await backup.delete();
          if (await target.exists()) await target.rename(backup.path);
          try {
            await entity.copy(target.path);
            if (await backup.exists()) await backup.delete();
            copiedFiles++;
          } catch (_) {
            if (await target.exists()) await target.delete();
            if (await backup.exists()) await backup.rename(target.path);
            rethrow;
          }
        }
      }

      if (copiedFiles == 0) {
        throw const Rpcs3InternalException(
          'saveImportEmpty',
          'Aucun fichier de sauvegarde RPCS3 valide n’a été trouvé dans RPCS3/Import.',
        );
      }
      _log.i('RPCS3 save import completed: $copiedFiles file(s).');
      return copiedFiles;
    } on Rpcs3InternalException {
      rethrow;
    } catch (error) {
      throw Rpcs3InternalException(
        'saveImportFailed',
        'Impossible d’importer les sauvegardes RPCS3 : $error',
      );
    } finally {
      _libraryMutationInProgress = false;
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

  static Future<bool> launchTitle(
    String titleId, {
    required String uiLocale,
    String? savestateId,
  }) async {
    final normalized = titleId.trim().toUpperCase();
    if (normalized.isEmpty) return false;

    if (!_initialized) {
      throw const Rpcs3InternalException(
        'RPCS3_RUNTIME_NOT_READY',
        'RPCS3 runtime was not initialized before boot.',
      );
    }
    final launchTimer = Stopwatch()..start();
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

    final bootTimer = Stopwatch()..start();
    final report = await Rpcs3InternalBridge.launchGame(
      titleId: normalized,
      uiLocale: uiLocale,
      savestateId: savestateId,
    );
    if (report['success'] != true) {
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

    _emit(
      Rpcs3RuntimePhase.ready,
      'RPCS3 en cours d’exécution.',
      jitReady: true,
      coreReady: true,
    );
    return true;
  }

  static Future<bool> stop() async {
    final stopped = await Rpcs3InternalBridge.stop();
    if (stopped) {
      try {
        await synchronizeFilesWorkspace();
      } catch (error) {
        _log.w('RPCS3 Files workspace refresh after stop failed: $error');
      }
    }
    return stopped;
  }
}
