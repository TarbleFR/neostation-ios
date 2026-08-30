import 'dart:io';

import 'package:flutter/material.dart';
import 'package:neostation/l10n/pairing_file_locale.dart';
import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/pairing_file_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

/// Experimental built-in StikJIT path dedicated to RPCS3.
///
/// This service is independent from the validated MeloNX and ARMSX2 paths.
/// RPCS3 currently has no supported direct-game callback, so the integrated
/// path launches RPCS3 with JIT enabled and leaves its native Start/game
/// selection screen responsible for the rest, matching the existing StikDebug
/// behaviour without opening StikDebug.
class StikJitRpcs3Service {
  StikJitRpcs3Service._();

  static final _log = LoggerService.instance;
  static String? _lastError;

  static String? get lastError => _lastError;

  static const bool isExperimentalEnabled = bool.fromEnvironment(
    'NEOSTATION_EXPERIMENTAL_STIKJIT_RPCS3',
    defaultValue: false,
  );

  // This is only a preferred hint. The native bridge confirms the installed
  // RPCS3 app through installation_proxy because sideloaders can rewrite the
  // bundle identifier.
  static const String _bundleId = String.fromEnvironment(
    'NEOSTATION_RPCS3_BUNDLE_ID',
    defaultValue: 'com.xitrix.RPCS3',
  );

  static Future<bool> launch({
    required String titleId,
    String? displayTitle,
    String? sourcePath,
    String? sourceKind,
  }) async {
    if (!Platform.isIOS || !isExperimentalEnabled) return false;

    final normalizedTitleId = titleId.trim().toUpperCase();
    if (normalizedTitleId.isEmpty) {
      _lastError = 'Invalid RPCS3 title ID.';
      return false;
    }

    _lastError = null;
    await _writeDiagnostic(
      'STATE: START\n'
      'Title ID: $normalizedTitleId\n'
      'Title: ${displayTitle?.trim() ?? ''}\n'
      'Source kind: ${sourceKind?.trim() ?? ''}\n'
      'Source path: ${sourcePath?.trim() ?? ''}\n'
      'Bundle hint: $_bundleId\n',
    );

    try {
      final pairingFile = await _ensurePairingFile();
      if (pairingFile == null) {
        _lastError = 'Pairing file selection was cancelled.';
        _log.w('StikJitRpcs3Service: pairing file selection was cancelled.');
        await _appendDiagnostic('STATE: CANCELLED\nError: $_lastError\n');
        return false;
      }

      await _appendDiagnostic(
        'STATE: PAIRING_READY\n'
        'Stored pairing file: ${path.basename(pairingFile.path)}\n'
        'Pairing bytes: ${await pairingFile.length()}\n',
      );

      final jit = await StikjitBridge.enableRpcs3Jit(
        pairingFilePath: pairingFile.path,
        bundleId: _bundleId,
        titleId: normalizedTitleId,
      );

      _log.i(
        'StikJitRpcs3Service: JIT ready for RPCS3 pid=${jit.pid} '
        'bundle=${jit.bundleId ?? 'unknown'} '
        'txm=${jit.txmPresent ?? 'unknown'}.',
      );
      for (final message in jit.logs) {
        _log.d('StikJIT RPCS3: $message');
      }

      await _appendDiagnostic(
        'STATE: RPCS3_JIT_READY\n'
        'PID: ${jit.pid}\n'
        'Detected bundle ID: ${jit.bundleId ?? 'unknown'}\n'
        'TXM: ${jit.txmPresent ?? 'unknown'}\n'
        'RPCS3 is responsible for its native Start/game selection screen.\n'
        'Native log:\n${jit.logs.join('\n')}\n',
      );
      return true;
    } catch (error, stackTrace) {
      _lastError = error.toString();
      _log.e(
        'StikJitRpcs3Service: built-in JIT launch failed: $error',
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
        'StikJitRpcs3Service: no navigator context for pairing explanation; '
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
    return File(path.join(documents.path, 'stikjit_rpcs3_debug.txt'));
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
