import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:retroarch_internal_bridge/retroarch_internal_bridge.dart';

import 'frontend_media_gate.dart';
import 'logger_service.dart';
import 'retroarch_core_catalog.dart';
import 'retroarch_core_preferences.dart';

/// Keeps native diagnostics separate from the translated launch explanation.
class RetroArchLaunchResult {
  const RetroArchLaunchResult({
    required this.success,
    this.stage,
    this.errorCode,
    this.detail = '',
    this.logPath,
    this.sessionOwned = false,
  });

  final bool success;
  final String? stage;
  final String? errorCode;
  final String detail;
  final String? logPath;
  final bool sessionOwned;

  String get technicalDetails => <String>[
    if (stage != null) 'RetroArch stage: $stage',
    if (errorCode != null) 'Code: $errorCode',
    if (detail.isNotEmpty) detail,
    if (logPath != null && logPath!.isNotEmpty) 'Log: $logPath',
    'Native session owned: $sessionOwned',
  ].join('\n');
}

/// File and lifetime boundary for the in-process RetroArch frontend.
///
/// The runtime receives a curated core identifier, never a caller-supplied
/// dylib path. Imported BIOS, configurations and saves remain user-owned.
abstract final class RetroArchInternalService {
  static const sessionExecutable = 'ios_retroarch_internal';
  static bool get hasSession =>
      _launchPending || RetroArchInternalBridge.hasSession;
  static Object? _mediaOwner;
  static int? _ownedTransaction;
  static Completer<void>? _releaseCompleter;
  static StreamSubscription<Map<String, dynamic>>? _sessionSubscription;
  static bool _launchPending = false;

  /// Frontend audio restoration must also await a retained failed start. The
  /// completion follows the native release acknowledgement, not an iOS resume.
  static Future<void> waitForSessionEnd() =>
      _releaseCompleter?.future ?? Future<void>.value();

  static void _releaseMedia(Object owner) {
    FrontendMediaGate.instance.release(owner);
    if (!identical(_mediaOwner, owner)) return;
    _mediaOwner = null;
    _ownedTransaction = null;
    final completion = _releaseCompleter;
    _releaseCompleter = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  static Future<Directory> rootDirectory() async => Directory(
    path.join((await getApplicationDocumentsDirectory()).path, 'RetroArch'),
  );

  static Future<Directory> _directory(String name) async =>
      Directory(path.join((await rootDirectory()).path, name));
  static Future<Directory> systemDirectory() => _directory('system');
  static Future<Directory> savesDirectory() => _directory('saves');
  static Future<Directory> statesDirectory() => _directory('states');
  static Future<Directory> configDirectory() => _directory('config');
  static Future<Directory> shadersDirectory() => _directory('shaders');
  static Future<Directory> overlaysDirectory() => _directory('overlays');
  static Future<Directory> cheatsDirectory() => _directory('cheats');
  static Future<Directory> logsDirectory() => _directory('logs');
  static Future<Directory> gamesDirectory([String? systemFolderName]) async {
    final root = await _directory('games');
    if (systemFolderName == null) return root;
    final folder = systemFolderName.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(folder)) {
      throw ArgumentError.value(systemFolderName, 'systemFolderName');
    }
    return Directory(path.join(root.path, folder));
  }

  static Future<void> ensureLayout() async {
    final root = await rootDirectory();
    for (final folder in const <String>[
      'system',
      'games',
      'saves',
      'states',
      'config',
      'shaders',
      'overlays',
      'cheats',
      'logs',
    ]) {
      await Directory(path.join(root.path, folder)).create(recursive: true);
    }
  }

  /// A catalogue row is not evidence that the matching callable frontend and
  /// signed core framework were packaged. Missing diagnostics fail closed.
  static Future<bool> frontendAvailable() async {
    try {
      final diagnostics = await RetroArchInternalBridge.diagnostics();
      return diagnostics['backendAvailable'] == true;
    } catch (_) {
      return false;
    }
  }

  static Set<String> _packagedCoreIds(Map<String, dynamic> diagnostics) {
    final packaged = diagnostics['availableCoreIds'];
    if (packaged is! List || packaged.any((value) => value is! String)) {
      throw const FormatException('RETROARCH_PACKAGE_METADATA_INVALID');
    }
    final ids = packaged.whereType<String>().toSet();
    return RetroArchCoreCatalog.cores
        .where((core) => ids.contains(core.identifier))
        .map((core) => core.identifier)
        .toSet();
  }

  /// Signed curated framework metadata may be shown during first-run setup
  /// before its callable frontend is ready. This does not imply launchability.
  static Future<Set<String>> packagedCoreIdentifiers() async =>
      _packagedCoreIds(await RetroArchInternalBridge.diagnostics());

  static Future<Set<String>> availableCoreIdentifiers() async {
    try {
      final diagnostics = await RetroArchInternalBridge.diagnostics();
      if (diagnostics['backendAvailable'] != true) return <String>{};
      return _packagedCoreIds(diagnostics);
    } catch (_) {
      return <String>{};
    }
  }

  /// An explicit embedded choice is never silently replaced after catalogue
  /// updates. Legacy choices migrate only when they are valid for this console.
  static Future<RetroArchCoreDescriptor> resolveCore({
    required String systemFolderName,
    required String romname,
    String? legacyEmulatorId,
    String? legacyCoreId,
  }) async {
    final saved = await RetroArchCorePreferences.gameCoreOverride(
      systemFolderName,
      romname,
    );
    if (saved != null && saved.isNotEmpty) {
      final chosen = RetroArchCoreCatalog.findCore(systemFolderName, saved);
      if (chosen == null) {
        throw StateError(
          'RETROARCH_CORE_UNAVAILABLE: system=$systemFolderName core=$saved',
        );
      }
      return chosen;
    }
    if (saved == null) {
      final legacy =
          RetroArchCoreCatalog.findCore(systemFolderName, legacyEmulatorId) ??
          RetroArchCoreCatalog.findCore(systemFolderName, legacyCoreId);
      if (legacy != null) return legacy;
    }
    return RetroArchCorePreferences.preferredCore(systemFolderName);
  }

  static void _observeSessionEnd() {
    _sessionSubscription ??= RetroArchInternalBridge.sessionEvents.listen((
      event,
    ) {
      if (event['type'] != 'sessionEnded' ||
          event['transaction'] != _ownedTransaction) {
        return;
      }
      LoggerService.instance.i(
        '[RetroArch session] ended transaction=${event['transaction']} '
        'reason=${event['reason'] ?? 'unknown'} '
        'runtimeReleased=${event['runtimeReleased']}',
      );
      final owner = _mediaOwner;
      if (owner != null) _releaseMedia(owner);
    });
  }

  static Future<void> _logBoundary(String text) async {
    LoggerService.instance.i('[RetroArch launch] $text');
    try {
      final logs = await logsDirectory();
      await logs.create(recursive: true);
      await File(
        path.join(logs.path, 'neostation-retroarch.log'),
      ).writeAsString(
        '${DateTime.now().toUtc().toIso8601String()} $text\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (error) {
      LoggerService.instance.w(
        'RetroArch boundary log could not be written: $error',
      );
    }
  }

  static Future<RetroArchLaunchResult> launch({
    required String systemFolderName,
    required String coreId,
    required String gamePath,
    required String gameTitle,
    required String locale,
    required Map<String, String> uiText,
  }) async {
    final core = RetroArchCoreCatalog.findCore(systemFolderName, coreId);
    if (core == null) {
      return RetroArchLaunchResult(
        success: false,
        stage: 'input',
        errorCode: 'RETROARCH_CORE_UNAVAILABLE',
        detail: 'system=$systemFolderName core=$coreId',
      );
    }
    if (_launchPending || RetroArchInternalBridge.hasSession) {
      return const RetroArchLaunchResult(
        success: false,
        stage: 'session',
        errorCode: 'RETROARCH_SESSION_ACTIVE',
        sessionOwned: true,
      );
    }
    _launchPending = true;
    final mediaOwner = Object();
    _mediaOwner = mediaOwner;
    _releaseCompleter = Completer<void>();
    // A duplicate end callback for the previous transaction must not release
    // this launch's barrier while its filesystem/media preparation is pending.
    _ownedTransaction = null;
    _observeSessionEnd();
    try {
      await FrontendMediaGate.instance.hold(mediaOwner);
      await ensureLayout();
      final uri = Uri.tryParse(gamePath);
      if (uri != null && uri.hasScheme && uri.scheme != 'file') {
        return RetroArchLaunchResult(
          success: false,
          stage: 'input',
          errorCode: 'RETROARCH_GAME_IMPORT_REQUIRED',
          detail: 'A library launch URL is not a readable game file: $gamePath',
        );
      }
      try {
        final file = File(gamePath);
        if (!await file.exists() || await file.length() == 0) {
          return RetroArchLaunchResult(
            success: false,
            stage: 'input',
            errorCode: 'RETROARCH_GAME_UNREADABLE',
            detail: 'Game file missing or empty: $gamePath',
          );
        }
        // Bookmarked external and iCloud files remain usable in place while
        // their app-session security scope is active. Prove actual read access
        // instead of treating a directory listing or cache row as a game.
        final handle = await file.open(mode: FileMode.read);
        try {
          if (await handle.readByte() == -1) {
            throw FileSystemException('Empty game file', gamePath);
          }
        } finally {
          await handle.close();
        }
      } on FileSystemException catch (error) {
        return RetroArchLaunchResult(
          success: false,
          stage: 'input',
          errorCode: 'RETROARCH_GAME_UNREADABLE',
          detail: '$error',
        );
      }
      await _logBoundary(
        'begin system=$systemFolderName core=$coreId game=$gamePath',
      );
      final launchOperation = RetroArchInternalBridge.launch(
        coreId: core.identifier,
        gamePath: gamePath,
        gameTitle: gameTitle,
        locale: locale,
        uiText: uiText,
      );
      _ownedTransaction = RetroArchInternalBridge.transaction;
      final response = await launchOperation;
      final success = response['success'] == true;
      final stage = response['stage']?.toString();
      final errorCode = response['errorCode']?.toString();
      await _logBoundary(
        'result success=$success stage=$stage code=$errorCode '
        'transaction=${response['transaction']} '
        'sessionOwned=${RetroArchInternalBridge.hasSession}',
      );
      // A failed first-frame acknowledgement can still own a renderer. Stop
      // that exact transaction; keep the media barrier until native teardown
      // is acknowledged if stopping also fails.
      var stopDetail = '';
      if (!success && RetroArchInternalBridge.hasSession) {
        try {
          final stopped = await RetroArchInternalBridge.stop();
          stopDetail = 'Stop result: $stopped';
        } catch (error) {
          stopDetail = 'Stop failed: $error';
        }
      }
      return RetroArchLaunchResult(
        success: success,
        stage: stage,
        errorCode: errorCode,
        detail: <String>[
          if (response['detail'] != null) response['detail'].toString(),
          if (response['message'] != null) response['message'].toString(),
          if (stopDetail.isNotEmpty) stopDetail,
        ].join('\n'),
        logPath: response['logPath']?.toString(),
        sessionOwned: RetroArchInternalBridge.hasSession,
      );
    } catch (error) {
      await _logBoundary('exception $error');
      var stopDetail = '';
      if (RetroArchInternalBridge.hasSession) {
        try {
          stopDetail = 'Stop result: ${await RetroArchInternalBridge.stop()}';
        } catch (stopError) {
          stopDetail = 'Stop failed: $stopError';
        }
      }
      return RetroArchLaunchResult(
        success: false,
        stage: 'bridge',
        errorCode: 'RETROARCH_BRIDGE_ERROR',
        detail: ['$error', if (stopDetail.isNotEmpty) stopDetail].join('\n'),
        sessionOwned: RetroArchInternalBridge.hasSession,
      );
    } finally {
      _launchPending = false;
      if (!RetroArchInternalBridge.hasSession) {
        _releaseMedia(mediaOwner);
      }
    }
  }
}
