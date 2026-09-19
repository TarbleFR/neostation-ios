import 'dart:io';

import 'package:armsx2_internal_bridge/armsx2_internal_bridge.dart';
import 'package:flutter/material.dart';
import 'package:neostation/l10n/pairing_file_locale.dart';
import 'package:neostation/main.dart' show rootNavigatorKey;
import 'package:neostation/services/armsx2_folder_service.dart';
import 'package:neostation/services/armsx2_internal_service.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/pairing_file_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

/// Native ARMSX2 launch transaction.
///
/// This path targets NeoStation's own PID. It never launches an ARMSX2 app,
/// Shortcut, custom URL, or VPN. LocalDevVPN is only probed as the existing
/// RemotePairing transport and is never toggled here.
class StikJitArmsx2Service {
  StikJitArmsx2Service._();

  static final _log = LoggerService.instance;
  static String? _lastError;
  static bool _busy = false;
  static int _transactionSeed = 0;

  static String? get lastError => _lastError;

  static Future<bool> launch({required String gamePath}) async {
    if (!Platform.isIOS || _busy) {
      _lastError = _busy ? 'An ARMSX2 launch is already active.' : null;
      return false;
    }
    final normalized = path.normalize(gamePath.trim());
    if (!path.isAbsolute(normalized) || !await File(normalized).exists()) {
      _lastError = 'The selected PS2 game is not readable.';
      return false;
    }

    _busy = true;
    _lastError = null;
    final transaction =
        (DateTime.now().microsecondsSinceEpoch << 8) | ((_transactionSeed++) & 0xff);

    try {
      await _writeDiagnostic(
        'STATE: START\nTransaction: $transaction\nGame: $normalized\n',
      );

      final pairingFile = await _ensurePairingFile();
      if (pairingFile == null) {
        _lastError = 'Pairing file selection was cancelled.';
        return false;
      }

      // Embedded ARMSX2 owns a Files-visible NeoStation/Documents root.
      // Games, BIOS and live saves all remain inside this canonical layout.
      await Armsx2InternalService.ensureLayout();
      final root = await Armsx2InternalService.rootDirectory();
      final games = await Armsx2InternalService.gamesDirectory();
      final bios = await Armsx2InternalService.biosDirectory();
      ConfigService.linkedArmsx2FolderPath = root.path;
      ConfigService.linkedArmsx2GameFolderPath = games.path;
      if (!Armsx2FolderService.ownsRomPath(normalized, games.path)) {
        _lastError = 'The selected PS2 game is outside NeoStation/ARMSX2/Games.';
        return false;
      }

      final biosDirectory = bios.path;
      final dataPath = root.path;

      // TCP reachability is a proof only. It has no side effect on either VPN.
      final route = await StikjitBridge.probeLocalDevVpnRoute();
      await _appendDiagnostic(
        'STATE: ROUTE_READY\n'
        'Route: ${route.host}:${route.port}\n'
        'ElapsedMs: ${route.elapsedMs}\n',
      );

      final jit = await Armsx2InternalBridge.prepareJit(
        pairingFilePath: pairingFile.path,
      );
      if (jit['success'] != true ||
          jit['helperConnected'] != true ||
          jit['pidAttached'] != true ||
          jit['debugged'] != true) {
        throw StateError(
          jit['message']?.toString() ?? 'ARMSX2 JIT attachment failed.',
        );
      }
      await _appendDiagnostic(
        'STATE: JIT_ATTACHED\n'
        'PID: ${jit['pid']}\n'
        'Message: ${jit['message']}\n',
      );

      final launch = await Armsx2InternalBridge.launch(
        transaction: transaction,
        gamePath: normalized,
        dataPath: dataPath,
        biosDirectory: biosDirectory,
      );
      if (launch['success'] != true) {
        throw StateError(
          launch['message']?.toString() ?? 'ARMSX2 boot failed.',
        );
      }

      await _appendDiagnostic(
        'STATE: RUNNING\n'
        'BootKind: ${launch['bootKind']}\n'
        'Source: ${launch['sourceRevision']}\n',
      );
      _log.i(
        'ARMSX2 embedded Core running transaction=$transaction '
        'game=$normalized.',
      );
      return true;
    } catch (error, stackTrace) {
      _lastError = error.toString();
      _log.e(
        'Embedded ARMSX2 launch failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      try {
        await Armsx2InternalBridge.stop();
      } catch (_) {}
      await _appendDiagnostic(
        'STATE: ERROR\nError: $error\nStack: $stackTrace\n',
      );
      return false;
    } finally {
      _busy = false;
    }
  }

  static Future<File?> _ensurePairingFile() async {
    if (await PairingFileService.hasStoredPairingFile()) {
      return PairingFileService.storedFile();
    }

    final context = rootNavigatorKey.currentContext;
    if (context != null && context.mounted) {
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            PairingFileLocale.get(dialogContext, PairingFileLocale.setupTitle),
          ),
          content: Text(
            PairingFileLocale.get(dialogContext, PairingFileLocale.setupBody),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                PairingFileLocale.get(dialogContext, PairingFileLocale.later),
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
      if (accepted != true) return null;
    }

    final dialogTitle = context != null && context.mounted
        ? PairingFileLocale.get(context, PairingFileLocale.pickerTitle)
        : 'Select your pairing file';
    final imported = await PairingFileService.importFromPicker(
      dialogTitle: dialogTitle,
    );
    return imported?.file;
  }

  static Future<File> _diagnosticFile() async {
    final documents = await getApplicationDocumentsDirectory();
    return File(path.join(documents.path, 'armsx2_internal_debug.txt'));
  }

  static Future<void> _writeDiagnostic(String content) async {
    try {
      await (await _diagnosticFile()).writeAsString(content, flush: true);
    } catch (_) {}
  }

  static Future<void> _appendDiagnostic(String content) async {
    try {
      await (await _diagnosticFile()).writeAsString(
        content,
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }
}
