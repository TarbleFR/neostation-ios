import 'dart:io';

import 'package:flutter/material.dart';
import 'package:neostation/l10n/pairing_file_locale.dart';
import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/services/jit_backend_preference_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/pairing_file_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

/// Experimental built-in StikJIT path dedicated to ARMSX2.
///
/// This service intentionally stays separate from the existing MeloNX service
/// and uses a different compile-time gate, native method channel, bundle
/// discovery path, and diagnostic file. Normal builds continue using the
/// NeoStation+ARMSX2+JIT Shortcut unchanged.
class StikJitArmsx2Service {
  StikJitArmsx2Service._();

  static final _log = LoggerService.instance;
  static String? _lastError;

  static String? get lastError => _lastError;

  static const bool isExperimentalEnabled = bool.fromEnvironment(
    'NEOSTATION_EXPERIMENTAL_STIKJIT_ARMSX2',
    defaultValue: false,
  );

  // Sideloaders may rewrite this identifier. The native bridge treats it only
  // as a preferred hint and confirms the installed app through
  // installation_proxy before launching anything.
  static const String _bundleId = String.fromEnvironment(
    'NEOSTATION_ARMSX2_BUNDLE_ID',
    defaultValue: 'com.armsx2.ios',
  );

  static Future<bool> launch({required String gameUrl}) async {
    if (!Platform.isIOS || !isExperimentalEnabled) return false;

    _lastError = null;
    await _writeDiagnostic(
      'STATE: START\n'
      'Game URL: $gameUrl\n'
      'Bundle hint: $_bundleId\n',
    );

    final gameUri = Uri.tryParse(gameUrl);
    if (gameUri == null || gameUri.scheme.toLowerCase() != 'armsx2') {
      _lastError = 'Invalid ARMSX2 game URL.';
      _log.e('StikJitArmsx2Service: invalid ARMSX2 game URL.');
      await _appendDiagnostic('STATE: ERROR\nError: $_lastError\n');
      return false;
    }

    try {
      final fallbackAutoLoadLastGame =
          await JitBackendPreferenceService.useArmsx2AutoLoadLastGame();
      await _appendDiagnostic(
        'Saved NeoStation fallback mode before ARMSX2 detection: '
        '${fallbackAutoLoadLastGame ? 'Automatic Load Last Game' : 'Natural post-JIT URL handoff'}\n',
      );

      final pairingFile = await _ensurePairingFile();
      if (pairingFile == null) {
        _lastError = 'Pairing file selection was cancelled.';
        _log.w('StikJitArmsx2Service: pairing file selection was cancelled.');
        await _appendDiagnostic('STATE: CANCELLED\nError: $_lastError\n');
        return false;
      }

      await _appendDiagnostic(
        'STATE: PAIRING_READY\n'
        'Stored pairing file: ${path.basename(pairingFile.path)}\n'
        'Pairing bytes: ${await pairingFile.length()}\n',
      );

      final jit = await StikjitBridge.enableArmsx2Jit(
        pairingFilePath: pairingFile.path,
        bundleId: _bundleId,
        gameUrl: gameUrl,
        autoLoadLastGame: fallbackAutoLoadLastGame,
      );

      final detectedAutoLoadLastGame = jit.detectedAutoLoadLastGame;
      final effectiveAutoLoadLastGame =
          jit.effectiveAutoLoadLastGame ??
          detectedAutoLoadLastGame ??
          fallbackAutoLoadLastGame;

      if (detectedAutoLoadLastGame != null &&
          detectedAutoLoadLastGame != fallbackAutoLoadLastGame) {
        await JitBackendPreferenceService.setUseArmsx2AutoLoadLastGame(
          detectedAutoLoadLastGame,
        );
      }

      _log.i(
        'StikJitArmsx2Service: JIT ready for ARMSX2 pid=${jit.pid} '
        'bundle=${jit.bundleId ?? 'unknown'} '
        'txm=${jit.txmPresent ?? 'unknown'} '
        'urlOpened=${jit.gameUrlOpened ?? 'unknown'} '
        'jitReady=${jit.jitReady ?? 'unknown'} '
        'detectedAutoLoad=${detectedAutoLoadLastGame ?? 'unavailable'} '
        'effectiveAutoLoad=$effectiveAutoLoadLastGame '
        'modeSource=${jit.autoLoadModeSource ?? 'unknown'}.',
      );
      for (final message in jit.logs) {
        _log.d('StikJIT ARMSX2: $message');
      }

      await _appendDiagnostic(
        'STATE: JIT_READY\n'
        'PID: ${jit.pid}\n'
        'Detected bundle ID: ${jit.bundleId ?? 'unknown'}\n'
        'TXM: ${jit.txmPresent ?? 'unknown'}\n'
        'JIT ready: ${jit.jitReady ?? 'unknown'}\n'
        'Detected ARMSX2 Automatic Load Last Game: '
        '${detectedAutoLoadLastGame ?? 'unavailable'}\n'
        'Detected preference key: '
        '${jit.detectedAutoLoadPreferenceKey ?? 'unavailable'}\n'
        'Launch mode source: ${jit.autoLoadModeSource ?? 'unknown'}\n'
        'Effective Automatic Load Last Game: $effectiveAutoLoadLastGame\n'
        'Native game URL opened: ${jit.gameUrlOpened ?? 'unknown'}\n'
        'Native log:\n${jit.logs.join('\n')}\n',
      );

      if (jit.gameUrlOpened != true) {
        // ARMSX2 is already on screen with JIT enabled at this point. Reporting
        // a hard failure here would surface an error dialog *behind* ARMSX2 and
        // make NeoStation look like it changed state while the user was playing.
        // Treat a JIT-ready launch without URL delivery as a soft success only
        // when Automatic Load Last Game is actually enabled.
        if (jit.jitReady == true && effectiveAutoLoadLastGame) {
          _lastError = null;
          _log.w(
            'StikJitArmsx2Service: JIT is ready but the direct game URL was not '
            'delivered; Automatic Load Last Game is enabled, so ARMSX2 can continue without changing NeoStation state.',
          );
          await _appendDiagnostic(
            'STATE: ARMSX2_GAME_URL_NOT_DELIVERED_JIT_READY\n'
            'ARMSX2 is running with JIT. NeoStation stays exactly where it was.\n',
          );
          return true;
        }

        _lastError =
            'JIT succeeded, but NeoStation could not complete the direct ARMSX2 game handoff.';
        await _appendDiagnostic(
          'STATE: ARMSX2_GAME_URL_POST_JIT_OPEN_FAILED\n'
          'Error: $_lastError\n',
        );
        return false;
      }

      await _appendDiagnostic(
        'STATE: ARMSX2_GAME_URL_POST_JIT_OPENED\n'
        'NeoStation delivered the ARMSX2 game URL to the already-JITed process.\n',
      );
      return true;
    } catch (error, stackTrace) {
      _lastError = error.toString();
      _log.e(
        'StikJitArmsx2Service: built-in JIT launch failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      await _appendDiagnostic(
        'STATE: ERROR\n'
        'Error: $error\n'
        'Stack: $stackTrace\n',
      );
      return false;
    }
  }

  static Future<File?> _ensurePairingFile() async {
    if (await PairingFileService.hasStoredPairingFile()) {
      return PairingFileService.storedFile();
    }

    await _appendDiagnostic(
      'STATE: PAIRING_REQUIRED\n'
      'No stored pairing file was found. Showing the shared JIT explanation before the iOS picker.\n',
    );

    final confirmed = await _confirmPairingFileImport();
    if (!confirmed) {
      await _appendDiagnostic('STATE: PAIRING_PROMPT_CANCELLED\n');
      return null;
    }

    final context = rootNavigatorKey.currentContext;
    final dialogTitle = context != null && context.mounted
        ? PairingFileLocale.get(context, PairingFileLocale.pickerTitle)
        : 'Select your pairing file';

    final imported = await PairingFileService.importFromPicker(
      dialogTitle: dialogTitle,
    );
    return imported?.file;
  }

  static Future<bool> _confirmPairingFileImport() async {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) {
      _log.w(
        'StikJitArmsx2Service: no navigator context for pairing explanation; '
        'opening the picker directly.',
      );
      await _appendDiagnostic(
        'PAIRING UI: navigator context unavailable; picker opened directly.\n',
      );
      return true;
    }

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          PairingFileLocale.get(
            dialogContext,
            PairingFileLocale.setupTitle,
          ),
        ),
        content: Text(
          PairingFileLocale.get(
            dialogContext,
            PairingFileLocale.setupBody,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              PairingFileLocale.get(
                dialogContext,
                PairingFileLocale.later,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.folder_open),
            label: Text(
              PairingFileLocale.get(
                dialogContext,
                PairingFileLocale.chooseFile,
              ),
            ),
          ),
        ],
      ),
    );

    return accepted ?? false;
  }

  static Future<File> _diagnosticFile() async {
    final documents = await getApplicationDocumentsDirectory();
    return File(path.join(documents.path, 'stikjit_armsx2_debug.txt'));
  }

  static Future<void> _writeDiagnostic(String content) async {
    try {
      final file = await _diagnosticFile();
      await file.writeAsString(content, flush: true);
    } catch (_) {
      // Diagnostic persistence must never block launching.
    }
  }

  static Future<void> _appendDiagnostic(String content) async {
    try {
      final file = await _diagnosticFile();
      await file.writeAsString(content, mode: FileMode.append, flush: true);
    } catch (_) {
      // Diagnostic persistence must never block launching.
    }
  }
}
