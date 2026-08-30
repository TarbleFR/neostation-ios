import 'dart:io';

import 'package:flutter/material.dart';
import 'package:neostation/l10n/pairing_file_locale.dart';
import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/pairing_file_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

/// Experimental built-in StikJIT path for MeloNX.
///
/// The feature is compile-time gated so normal NeoStation builds keep using
/// the existing Apple Shortcut -> StikDebug flow unchanged. The experimental
/// build enables this service with a Dart define.
class StikJitMeloNxService {
  StikJitMeloNxService._();

  static final _log = LoggerService.instance;
  static String? _lastError;

  static String? get lastError => _lastError;

  static const bool isExperimentalEnabled = bool.fromEnvironment(
    'NEOSTATION_EXPERIMENTAL_STIKJIT_MELONX',
    defaultValue: false,
  );

  // This is now only a hint. The native bridge discovers the actual installed
  // MeloNX bundle identifier because SideStore/Plume can rewrite it.
  static const String _bundleId = String.fromEnvironment(
    'NEOSTATION_MELONX_BUNDLE_ID',
    defaultValue: 'com.nur.nx',
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
    if (gameUri == null || gameUri.scheme.isEmpty) {
      _lastError = 'Invalid MeloNX game URL.';
      _log.e('StikJitMeloNxService: invalid MeloNX game URL.');
      await _appendDiagnostic('STATE: ERROR\nError: $_lastError\n');
      return false;
    }

    try {
      final pairingFile = await _ensurePairingFile();
      if (pairingFile == null) {
        _lastError = 'Pairing file selection was cancelled.';
        _log.w('StikJitMeloNxService: pairing file selection was cancelled.');
        await _appendDiagnostic('STATE: CANCELLED\nError: $_lastError\n');
        return false;
      }

      await _appendDiagnostic(
        'STATE: PAIRING_READY\n'
        'Stored pairing file: ${path.basename(pairingFile.path)}\n'
        'Pairing bytes: ${await pairingFile.length()}\n',
      );

      final jit = await StikjitBridge.enableMeloNxJit(
        pairingFilePath: pairingFile.path,
        bundleId: _bundleId,
        gameUrl: gameUrl,
      );

      _log.i(
        'StikJitMeloNxService: JIT ready for MeloNX pid=${jit.pid} '
        'bundle=${jit.bundleId ?? 'unknown'} '
        'txm=${jit.txmPresent ?? 'unknown'} '
        'urlOpened=${jit.gameUrlOpened ?? 'unknown'}.',
      );
      for (final message in jit.logs) {
        _log.d('StikJIT: $message');
      }

      await _appendDiagnostic(
        'STATE: JIT_READY\n'
        'PID: ${jit.pid}\n'
        'Detected bundle ID: ${jit.bundleId ?? 'unknown'}\n'
        'TXM: ${jit.txmPresent ?? 'unknown'}\n'
        'Native game URL opened: ${jit.gameUrlOpened ?? 'unknown'}\n'
        'Native log:\n${jit.logs.join('\n')}\n',
      );

      if (jit.gameUrlOpened != true) {
        _lastError =
            'JIT succeeded, but NeoStation could not complete the direct MeloNX game handoff.';
        await _appendDiagnostic(
          'STATE: GAME_URL_POST_JIT_OPEN_FAILED\n'
          'Error: $_lastError\n',
        );
        return false;
      }

      await _appendDiagnostic(
        'STATE: GAME_URL_POST_JIT_OPENED\n'
        'NeoStation regained the foreground after JIT and delivered the frontend URL to the already-JITed MeloNX process.\n',
      );
      return true;
    } catch (error, stackTrace) {
      _lastError = error.toString();
      _log.e(
        'StikJitMeloNxService: built-in JIT launch failed: $error',
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
      'No stored pairing file was found. Showing setup explanation before the iOS picker.\n',
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
      // The launch normally originates from the visible game screen, so a
      // navigator context should exist. If it does not, fall back to the picker.
      _log.w(
        'StikJitMeloNxService: no navigator context for pairing explanation; '
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
    return File(path.join(documents.path, 'stikjit_melonx_debug.txt'));
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
