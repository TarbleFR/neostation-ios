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
  static const Duration _spuNoProgressLimit = Duration(seconds: 75);

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

  /// Applies the mobile boot policy exported by our RPCS3 iOS Core.
  ///
  /// The Core exposes these settings through `rpcs3_ios_set_setting`. Keep the
  /// normal on-disk cache, but avoid the long up-front LLVM pass, use RPCS3's
  /// iOS memory-safe automatic compiler-thread limit, enable the mobile SPU
  /// scheduler, and compile larger SPU blocks so first boot has less work.
  static Future<void> _applyMobileBootProfile() async {
    await Rpcs3InternalService.ensureGameplayInitialized();
    const settings = <String, String>{
      'advanced.llvm_precompilation': 'false',
      'emulator.max_llvm_threads': '0',
      'experimental.mobile_spu_scheduling': 'Enabled',
      'cpu.spu_block_size': 'Mega',
    };

    for (final entry in settings.entries) {
      final report = await Rpcs3InternalBridge.setSetting(entry.key, entry.value);
      if (report['success'] != true) {
        _log.i(
          'RPCS3 mobile boot setting ${entry.key}=${entry.value} was not applied: '
          '${report['message'] ?? 'unknown Core response'}',
        );
      }
    }
  }

  /// Watches the native boot progress only while RPCS3 reports an active boot
  /// stage. This is not a fixed boot timeout: slow games may keep compiling as
  /// long as the counters move. It only aborts the known failure mode where
  /// "Building SPU Cache" stops advancing for an extended period.
  static Future<void> _waitForBootOrDetectStall(String titleId) async {
    String lastStage = '';
    int lastCurrent = -1;
    int lastTotal = -1;
    var lastMovement = DateTime.now();

    while (true) {
      final report = await Rpcs3InternalBridge.bootProgress();
      if (report['success'] != true) {
        // Older Core revisions may not expose progress. Boot normally rather
        // than turning an optional diagnostic API into a launch requirement.
        return;
      }

      final stage = report['stage']?.toString().trim() ?? '';
      final current = (report['current'] as num?)?.toInt() ?? 0;
      final total = (report['total'] as num?)?.toInt() ?? 0;
      if (stage.isEmpty) return;

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

      final spuStage = stage.toLowerCase().contains('spu') &&
          (stage.toLowerCase().contains('cache') ||
              stage.toLowerCase().contains('compil'));
      if (spuStage && DateTime.now().difference(lastMovement) > _spuNoProgressLimit) {
        await Rpcs3InternalBridge.stop();
        throw const Rpcs3InternalException(
          'spuCacheStalled',
          'La préparation du cache SPU n’avance plus. RPCS3 a arrêté ce démarrage au lieu de rester bloqué indéfiniment. Relancez le jeu : le profil SPU mobile et le cache déjà créé seront réutilisés.',
        );
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
      await _applyMobileBootProfile();
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
