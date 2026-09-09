import 'dart:async';
import 'dart:io';

import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/rpcs3_internal_service.dart';
import 'package:rpcs3_internal_bridge/rpcs3_internal_bridge.dart';

/// Direct launcher for the in-process RPCS3 engine.
///
/// NeoStation enables JIT for its own process and calls the embedded RPCS3
/// Core's `rpcs3_ios_boot_game` entry point directly. No external RPCS3
/// application is queried, opened or foregrounded.
abstract final class Rpcs3LaunchService {
  static final LoggerService _log = LoggerService.instance;
  static final RegExp _titleIdPattern = RegExp(r'^[A-Z0-9._-]{3,32}$');

  static const Duration _bootPollInterval = Duration(seconds: 1);
  static const Duration _bootStageGrace = Duration(seconds: 12);
  static const Duration _spuNoProgressLimit = Duration(seconds: 90);
  static const Duration _ppuNoProgressLimit = Duration(seconds: 120);
  static const Duration _finishedStageLimit = Duration(seconds: 45);

  static String? _lastError;
  static String? _lastErrorCode;

  static String? get lastError => _lastError;
  static String? get lastErrorCode => _lastErrorCode;

  static String? normalizeTitleId(String? value) {
    final titleId = value?.trim().toUpperCase() ?? '';
    return _titleIdPattern.hasMatch(titleId) ? titleId : null;
  }

  static Future<void> initialize() async {
    if (!Platform.isIOS) return;
    await Rpcs3InternalService.rootDirectory();
  }

  /// Applies an iOS-safe boot policy both globally and to the title itself.
  ///
  /// RPCS3 reloads a title's own configuration during boot, so a global-only
  /// override can be replaced just before PPU/SPU preparation begins. Build 230
  /// could therefore still enter the long "Compiling PPU Modules" path even
  /// though LLVM precompilation had been disabled globally. Persist the same
  /// policy through `rpcs3_ios_set_game_setting` before boot so the title cannot
  /// re-enable the blocking precompile when its configuration is loaded.
  ///
  /// `Safe` deliberately replaces the previous forced `Mega` SPU block size,
  /// and mobile SPU scheduling returns to `Automatic` for compatibility. The
  /// existing on-disk caches remain reusable; only the aggressive boot policy
  /// is changed.
  static Future<void> _applyMobileBootProfile(String titleId) async {
    await Rpcs3InternalService.ensureGameplayInitialized();
    const settings = <String, String>{
      'advanced.llvm_precompilation': 'false',
      'emulator.max_llvm_threads': '0',
      'experimental.mobile_spu_scheduling': 'Automatic',
      'cpu.spu_block_size': 'Safe',
    };

    for (final entry in settings.entries) {
      final global = await Rpcs3InternalBridge.setSetting(entry.key, entry.value);
      if (global['success'] != true) {
        _log.i(
          'RPCS3 global mobile boot setting ${entry.key}=${entry.value} was not applied: '
          '${global['message'] ?? 'unknown Core response'}',
        );
      }

      final perGame = await Rpcs3InternalBridge.setGameSetting(
        titleId,
        entry.key,
        entry.value,
      );
      if (perGame['success'] != true) {
        _log.i(
          'RPCS3 per-title boot setting $titleId ${entry.key}=${entry.value} was not applied: '
          '${perGame['message'] ?? 'unknown Core response'}',
        );
      }
    }
  }

  static Duration? _stallLimitForStage(String stage) {
    final value = stage.toLowerCase();
    final ppuStage = value.contains('ppu') &&
        (value.contains('compil') ||
            value.contains('applying') ||
            value.contains('linking') ||
            value.contains('code'));
    if (ppuStage) return _ppuNoProgressLimit;

    final spuStage = value.contains('spu') &&
        (value.contains('cache') || value.contains('compil'));
    if (spuStage) return _spuNoProgressLimit;
    return null;
  }

  /// Watches the native boot preparation without imposing a total boot limit.
  ///
  /// Slow titles may compile for as long as they need while progress moves.
  /// The guard only aborts the known deadlock cases where PPU compilation,
  /// "Applying PPU Code", or SPU cache building reports the same stage/counter
  /// for an extended period. A completed counter (for example 46/46) gets a
  /// shorter transition grace so the UI can never sit at 100% forever.
  static Future<void> _waitForBootOrDetectStall(String titleId) async {
    String lastStage = '';
    int lastCurrent = -1;
    int lastTotal = -1;
    var lastMovement = DateTime.now();
    final started = DateTime.now();
    var sawActiveStage = false;

    while (true) {
      final report = await Rpcs3InternalBridge.bootProgress();
      if (report['success'] != true) {
        // Boot-progress support is diagnostic. Never make an older compatible
        // Core fail to launch solely because that optional symbol is absent.
        return;
      }

      final stage = report['stage']?.toString().trim() ?? '';
      final current = (report['current'] as num?)?.toInt() ?? 0;
      final total = (report['total'] as num?)?.toInt() ?? 0;

      if (stage.isEmpty) {
        if (!sawActiveStage &&
            DateTime.now().difference(started) < _bootStageGrace) {
          await Future<void>.delayed(_bootPollInterval);
          continue;
        }
        return;
      }
      sawActiveStage = true;

      if (stage != lastStage || current != lastCurrent || total != lastTotal) {
        lastStage = stage;
        lastCurrent = current;
        lastTotal = total;
        lastMovement = DateTime.now();
        _log.i(
          'RPCS3 boot progress $titleId: $stage '
          '${total > 0 ? '$current/$total' : current.toString()}',
        );
      }

      final limit = _stallLimitForStage(stage);
      if (limit != null) {
        final noMovement = DateTime.now().difference(lastMovement);
        final stageComplete = total > 0 && current >= total;
        final effectiveLimit = stageComplete ? _finishedStageLimit : limit;
        if (noMovement > effectiveLimit) {
          try {
            await Rpcs3InternalBridge.stop().timeout(const Duration(seconds: 12));
          } catch (_) {
            // The error below is the useful user-facing outcome even if an old
            // Core revision takes longer to acknowledge stop during teardown.
          }
          final progress = total > 0 ? ' ($current/$total)' : '';
          throw Rpcs3InternalException(
            'bootPreparationStalled',
            'La préparation RPCS3 est restée bloquée sur « $stage »$progress. '
                'Le démarrage a été arrêté au lieu de rester figé. Le profil '
                'PPU/SPU sûr est maintenant enregistré pour ce jeu ; relancez-le.',
          );
        }
      }

      await Future<void>.delayed(_bootPollInterval);
    }
  }

  static Future<bool> launchTitle(
    String? rawTitleId, {
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
      final launched = await Rpcs3InternalService.launchTitle(titleId);
      if (!launched) return false;
      await _waitForBootOrDetectStall(titleId);
      return true;
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
