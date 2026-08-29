import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/services/logger_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';
import 'package:url_launcher/url_launcher.dart';

/// Experimental built-in StikJIT path for MeloNX.
///
/// The feature is compile-time gated so normal NeoStation builds keep using
/// the existing Apple Shortcut -> StikDebug flow unchanged. The experimental
/// Codemagic build enables this service with a Dart define.
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
      );

      _log.i(
        'StikJitMeloNxService: JIT ready for MeloNX pid=${jit.pid} '
        'bundle=${jit.bundleId ?? 'unknown'} '
        'txm=${jit.txmPresent ?? 'unknown'}.',
      );
      for (final message in jit.logs) {
        _log.d('StikJIT: $message');
      }

      await _appendDiagnostic(
        'STATE: JIT_READY\n'
        'PID: ${jit.pid}\n'
        'Detected bundle ID: ${jit.bundleId ?? 'unknown'}\n'
        'TXM: ${jit.txmPresent ?? 'unknown'}\n'
        'Native log:\n${jit.logs.join('\n')}\n',
      );

      // StikJIT has completed and detached. MeloNX is now running with JIT, so
      // deliver the exact frontend deep link that the old Shortcut received as
      // Shortcut Input. No StikDebug app transition is needed.
      final opened = await launchUrl(
        gameUri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        _lastError = 'JIT succeeded, but the MeloNX game URL could not be opened.';
        await _appendDiagnostic('STATE: ERROR\nError: $_lastError\n');
        return false;
      }

      await _appendDiagnostic('STATE: GAME_URL_OPENED\n');
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
    final support = await getApplicationSupportDirectory();
    final directory = Directory(path.join(support.path, 'StikJIT'));
    await directory.create(recursive: true);

    final stored = File(
      path.join(directory.path, 'pairing.mobiledevicepairing'),
    );
    if (await stored.exists() && await stored.length() > 0) {
      return stored;
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

    // file_picker 12.0.0-beta.3 exposes the static FilePicker facade but still
    // returns a nullable FilePickerResult. The direct List<PlatformFile> return
    // type arrived in a later beta, so keep using the result.files wrapper here.
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Veuillez sélectionner votre pairing file',
      allowMultiple: false,
      type: FileType.any,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return null;

    final selected = picked.files.single;
    final sourcePath = selected.path;
    if (sourcePath != null) {
      final source = File(sourcePath);
      if (await source.exists() && await source.length() > 0) {
        await source.copy(stored.path);
        return stored;
      }
    }

    final bytes = selected.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      await stored.writeAsBytes(bytes, flush: true);
      return stored;
    }

    throw StateError('The selected pairing file could not be read.');
  }

  static Future<bool> _confirmPairingFileImport() async {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) {
      // The launch normally originates from the visible game screen, so a
      // navigator context should exist. Do not make JIT unusable if it does not:
      // fall back to the native picker and leave a diagnostic breadcrumb.
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
        title: const Text('Pairing file requis'),
        content: const Text(
          'Pour utiliser MeloNX avec le JIT intégré, NeoStation doit importer '
          'une fois le pairing file de cet iPhone.\n\n'
          'Veuillez sélectionner votre fichier .mobiledevicepairing. Il sera '
          'conservé localement par NeoStation et ne vous sera redemandé que si '
          'le fichier est supprimé ou si l’application est réinstallée.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.folder_open),
            label: const Text('Choisir le pairing file'),
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
