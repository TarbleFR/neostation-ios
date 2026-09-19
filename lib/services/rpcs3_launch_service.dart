import 'dart:async';
import 'dart:io';

import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/rpcs3_game_profile_service.dart';
import 'package:neostation/services/rpcs3_internal_service.dart';
import 'package:rpcs3_internal_bridge/rpcs3_internal_bridge.dart';

typedef Rpcs3BootProgressReader = Future<Map<String, dynamic>> Function();
typedef Rpcs3BootControl = Future<void> Function();
typedef Rpcs3BootProgressLogger =
    void Function(String stage, int current, int total);

/// Guards only the synchronous native boot transaction.
///
/// RPCS3 can legitimately spend time compiling while `boot_game` is still on
/// the Core queue, so progress is watched until that call settles. Once the
/// native call succeeds or fails, its result is authoritative: a missing or
/// stale diagnostic progress stage must never keep the launch UI waiting.
class Rpcs3BootWatchdog {
  const Rpcs3BootWatchdog({
    this.pollInterval = const Duration(seconds: 1),
    this.spuNoProgressLimit = const Duration(seconds: 90),
    this.ppuNoProgressLimit = const Duration(minutes: 10),
    this.ppuApplyNoProgressLimit = const Duration(minutes: 5),
    this.finishedStageLimit = const Duration(minutes: 5),
    this.abortTimeout = const Duration(seconds: 8),
    this.stopTimeout = const Duration(seconds: 12),
    this.recoveryStopTimeout = const Duration(seconds: 20),
    this.clock,
  });

  final Duration pollInterval;
  final Duration spuNoProgressLimit;
  final Duration ppuNoProgressLimit;
  final Duration ppuApplyNoProgressLimit;
  final Duration finishedStageLimit;
  final Duration abortTimeout;
  final Duration stopTimeout;
  final Duration recoveryStopTimeout;
  final DateTime Function()? clock;

  DateTime _now() => clock?.call() ?? DateTime.now();

  bool _isPpuStage(String stage) => stage.toLowerCase().contains('ppu');

  Duration? _stallLimitForStage(String stage) {
    final value = stage.toLowerCase();
    final ppuStage =
        value.contains('ppu') &&
        (value.contains('compil') ||
            value.contains('applying') ||
            value.contains('linking') ||
            value.contains('code'));
    if (ppuStage) {
      return value.contains('applying')
          ? ppuApplyNoProgressLimit
          : ppuNoProgressLimit;
    }

    final spuStage =
        value.contains('spu') &&
        (value.contains('cache') || value.contains('compil'));
    if (spuStage) return spuNoProgressLimit;
    return null;
  }

  Future<void> _waitForPollOrLaunch(Future<void> launchSettled) {
    final completer = Completer<void>();
    final timer = Timer(pollInterval, () {
      if (!completer.isCompleted) completer.complete();
    });
    unawaited(
      launchSettled.then((_) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete();
      }),
    );
    return completer.future;
  }

  Future<void> _monitor({
    required Future<void> launchSettled,
    required bool Function() launchCompleted,
    required Rpcs3BootProgressReader readProgress,
    required Rpcs3BootControl abortBoot,
    required Rpcs3BootControl stop,
    required Rpcs3BootProgressLogger logProgress,
  }) async {
    String lastStage = '';
    int lastCurrent = -1;
    int lastTotal = -1;
    var lastMovement = _now();

    while (!launchCompleted()) {
      final report = await Future.any<Map<String, dynamic>?>([
        readProgress(),
        launchSettled.then<Map<String, dynamic>?>((_) => null),
      ]);
      if (report == null || launchCompleted()) return;
      if (report['success'] != true) {
        // Boot progress is diagnostic. An older compatible Core may omit it;
        // the native launch future remains the source of truth.
        return;
      }

      final stage = report['stage']?.toString().trim() ?? '';
      final current = (report['current'] as num?)?.toInt() ?? 0;
      final total = (report['total'] as num?)?.toInt() ?? 0;

      if (stage.isNotEmpty &&
          (stage != lastStage ||
              current != lastCurrent ||
              total != lastTotal)) {
        lastStage = stage;
        lastCurrent = current;
        lastTotal = total;
        lastMovement = _now();
        logProgress(stage, current, total);
      }

      final limit = stage.isEmpty ? null : _stallLimitForStage(stage);
      if (limit != null && !launchCompleted()) {
        final noMovement = _now().difference(lastMovement);
        final stageComplete = total > 0 && current >= total;
        final effectiveLimit = stageComplete ? finishedStageLimit : limit;
        if (noMovement > effectiveLimit && !launchCompleted()) {
          // The normal stop path is serialized behind BootGame. Interrupt the
          // pending native call through the independent tuning queue first.
          try {
            await abortBoot().timeout(abortTimeout);
          } catch (_) {}
          try {
            await stop().timeout(stopTimeout);
          } catch (_) {}

          final progress = total > 0 ? ' ($current/$total)' : '';
          final ppuStage = _isPpuStage(stage);
          throw Rpcs3InternalException(
            ppuStage ? 'ppuBootPreparationStalled' : 'bootPreparationStalled',
            ppuStage
                ? 'La préparation RPCS3 est restée bloquée sur « $stage »$progress. '
                      'Consultez RPCS3-diagnostic.log ; les caches sont conservés.'
                : 'La préparation RPCS3 est restée bloquée sur « $stage »$progress. '
                      'Le démarrage a été arrêté au lieu de rester figé.',
          );
        }
      }

      if (launchCompleted()) return;
      await _waitForPollOrLaunch(launchSettled);
    }
  }

  Future<T> guard<T>({
    required Future<T> launchFuture,
    required Rpcs3BootProgressReader readProgress,
    required Rpcs3BootControl abortBoot,
    required Rpcs3BootControl stop,
    required Rpcs3BootProgressLogger logProgress,
  }) async {
    var completed = false;
    T? launched;
    Object? launchError;
    StackTrace? launchStackTrace;
    final launchSettled = Completer<void>();

    unawaited(
      launchFuture.then(
        (value) {
          launched = value;
          completed = true;
          if (!launchSettled.isCompleted) launchSettled.complete();
        },
        onError: (Object error, StackTrace stackTrace) {
          launchError = error;
          launchStackTrace = stackTrace;
          completed = true;
          if (!launchSettled.isCompleted) launchSettled.complete();
        },
      ),
    );

    try {
      await _monitor(
        launchSettled: launchSettled.future,
        launchCompleted: () => completed,
        readProgress: readProgress,
        abortBoot: abortBoot,
        stop: stop,
        logProgress: logProgress,
      );
    } on Rpcs3InternalException catch (error) {
      if (error.code == 'ppuBootPreparationStalled' ||
          error.code == 'bootPreparationStalled') {
        // Do not start a recovery launch while the interrupted BootGame call is
        // still unwinding on the native Core queue.
        try {
          await launchFuture.timeout(recoveryStopTimeout);
        } catch (_) {}
      }
      rethrow;
    }

    if (!completed) {
      // Progress is optional. If it is unavailable, await the native result.
      return launchFuture;
    }
    if (launchError != null) {
      Error.throwWithStackTrace(
        launchError!,
        launchStackTrace ?? StackTrace.current,
      );
    }
    return launched as T;
  }
}

/// Direct launcher for the in-process RPCS3 engine.
///
/// NeoStation enables JIT for its own process and calls the embedded RPCS3
/// Core's `rpcs3_ios_boot_game` entry point directly. No external RPCS3
/// application is queried, opened or foregrounded.
abstract final class Rpcs3LaunchService {
  static final LoggerService _log = LoggerService.instance;
  static const Rpcs3BootWatchdog _bootWatchdog = Rpcs3BootWatchdog();

  static String? _lastError;
  static String? _lastErrorCode;

  static String? get lastError => _lastError;
  static String? get lastErrorCode => _lastErrorCode;

  static String? normalizeTitleId(String? value) {
    return Rpcs3GameProfileService.normalizeSerial(value);
  }

  static Future<void> initialize() async {
    if (!Platform.isIOS) return;
    await Rpcs3InternalService.rootDirectory();
  }

  /// Publishes the serial-keyed, partial profile before boot.
  ///
  /// No global RPCS3 setting is mutated here. The Core layers only this game's
  /// managed keys over the global configuration selected by the user.
  static Future<void> _applyMobileBootProfile(String titleId) async {
    await Rpcs3InternalService.ensureGameplayInitialized();
    final report = await Rpcs3GameProfileService.applyForLaunch(titleId);
    if (report['success'] != true) {
      throw Rpcs3InternalException(
        'gameProfileFailed',
        report['message']?.toString() ??
            'RPCS3 could not load the serial-specific compatibility profile.',
      );
    }
  }

  static Future<bool> _launchWithBootWatchdog(
    String titleId, {
    required String uiLocale,
  }) async {
    final launchFuture = Rpcs3InternalService.launchTitle(
      titleId,
      uiLocale: uiLocale,
    );
    return _bootWatchdog.guard<bool>(
      launchFuture: launchFuture,
      readProgress: Rpcs3InternalBridge.bootProgress,
      abortBoot: () async {
        await Rpcs3InternalBridge.abortBoot();
      },
      stop: () async {
        await Rpcs3InternalBridge.stop();
      },
      logProgress: (stage, current, total) {
        _log.i(
          'RPCS3 boot progress $titleId: $stage '
          '${total > 0 ? '$current/$total' : current.toString()}',
        );
      },
    );
  }

  static Future<bool> launchTitle(
    String? rawTitleId, {
    required String uiLocale,
    String? displayTitle,
    String? sourcePath,
    String? sourceKind,
  }) async {
    if (!Platform.isIOS) return false;
    final titleId = normalizeTitleId(rawTitleId);
    if (titleId == null) return false;

    _lastError = null;
    _lastErrorCode = null;
    _log.i(
      'RPCS3 internal launch: titleId=$titleId '
      'title=${displayTitle?.trim() ?? ''} '
      'sourceKind=${sourceKind?.trim() ?? ''} '
      'sourcePath=${sourcePath?.trim() ?? ''}',
    );

    try {
      await _applyMobileBootProfile(titleId);
      // A timeout alone is not evidence of a corrupt cache. Never delete
      // compiled objects or start a second native boot automatically.
      return await _launchWithBootWatchdog(titleId, uiLocale: uiLocale);
    } on Rpcs3InternalException catch (error, stackTrace) {
      _lastError = error.message;
      _lastErrorCode = error.code;
      _log.e(
        'RPCS3 internal launch failed at ${error.code}: ${error.message}',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    } catch (error, stackTrace) {
      _lastError = error.toString();
      _lastErrorCode = 'unknown';
      _log.e(
        'RPCS3 internal launch failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }
}
