import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:kartpad_internal_bridge/kartpad_internal_bridge.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class KartPadImportIssue {
  const KartPadImportIssue(this.fileName, this.messageKey, [this.details]);
  final String fileName;
  final String messageKey;
  final String? details;
}

class KartPadImportResult {
  const KartPadImportResult({
    required this.imported,
    required this.rejected,
    this.errors = const <KartPadImportIssue>[],
    this.importedPaths = const <String>[],
  });
  final int imported;
  final int rejected;
  final List<KartPadImportIssue> errors;
  final List<String> importedPaths;
}

class KartPadLaunchResult {
  const KartPadLaunchResult({
    required this.success,
    required this.message,
    this.stage,
    this.errorCode,
    this.technicalDetails = '',
  });

  final bool success;
  final String message;
  final String? stage;
  final String? errorCode;
  final String technicalDetails;
}

class KartPadDiscIdentity {
  const KartPadDiscIdentity({
    required this.gameId,
    this.discNumber,
    this.revision,
  });
  final String gameId;
  final int? discNumber;
  final int? revision;

  bool get hasExactRevisionMetadata =>
      discNumber != null && revision != null;
}

/// User-data boundary for the embedded KartPad Core.
class KartPadInternalService {
  KartPadInternalService._();

  static const String displayTitle = 'Mario Kart Wii';
  static const String supportedDiscId = 'RMCP01';
  static const int supportedDiscNumber = 0;
  static const int supportedRevision = 0;
  static const Set<String> supportedGameExtensions = <String>{'iso', 'wbfs'};
  static const MethodChannel _discIdentityChannel =
      MethodChannel('neostation/dolphin_internal');

  static Future<Directory> rootDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory(path.join(documents.path, 'Ports', 'KartPad'));
  }

  static Future<Directory> gamesDirectory() async =>
      Directory(path.join((await rootDirectory()).path, 'Games'));
  static Future<Directory> savesDirectory() async =>
      Directory(path.join((await rootDirectory()).path, 'Saves'));
  static Future<Directory> configDirectory() async =>
      Directory(path.join((await rootDirectory()).path, 'Config'));
  static Future<Directory> modsDirectory() async =>
      Directory(path.join((await rootDirectory()).path, 'Mods'));
  static Future<Directory> logsDirectory() async =>
      Directory(path.join((await rootDirectory()).path, 'Logs'));

  static Future<void> ensureLayout() async {
    for (final directory in <Directory>[
      await rootDirectory(),
      await gamesDirectory(),
      await savesDirectory(),
      await configDirectory(),
      await modsDirectory(),
      await logsDirectory(),
      Directory(path.join((await rootDirectory()).path, 'Metadata')),
    ]) {
      await directory.create(recursive: true);
    }
  }

  static Future<KartPadImportResult> importGame() async {
    await ensureLayout();
    final selection = await FilePicker.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: supportedGameExtensions.toList(),
      withData: false,
      lockParentWindow: true,
    );
    if (selection == null || selection.files.isEmpty) {
      return const KartPadImportResult(imported: 0, rejected: 0);
    }
    final picked = selection.files.single;
    final sourcePath = picked.path;
    final extension =
        path.extension(picked.name).replaceFirst('.', '').toLowerCase();
    if (sourcePath == null || !supportedGameExtensions.contains(extension)) {
      return KartPadImportResult(
        imported: 0,
        rejected: 1,
        errors: <KartPadImportIssue>[
          KartPadImportIssue(picked.name, 'kartpadFormatUnsupported'),
        ],
      );
    }

    final source = File(sourcePath);
    if (!await source.exists() || await source.length() < 0x20) {
      return KartPadImportResult(
        imported: 0,
        rejected: 1,
        errors: <KartPadImportIssue>[
          KartPadImportIssue(picked.name, 'kartpadUnsupportedDisc'),
        ],
      );
    }

    final identity = await inspectGameFile(source);
    if (identity == null || identity.gameId != supportedDiscId) {
      return KartPadImportResult(
        imported: 0,
        rejected: 1,
        errors: <KartPadImportIssue>[
          KartPadImportIssue(picked.name, 'kartpadUnsupportedDisc'),
        ],
      );
    }
    if (identity.hasExactRevisionMetadata &&
        (identity.discNumber != supportedDiscNumber ||
            identity.revision != supportedRevision)) {
      return KartPadImportResult(
        imported: 0,
        rejected: 1,
        errors: <KartPadImportIssue>[
          KartPadImportIssue(
            picked.name,
            'kartpadUnsupportedRevision',
            'disc=${identity.discNumber} revision=${identity.revision}',
          ),
        ],
      );
    }

    final destination = await gamesDirectory();
    final output = File(path.join(destination.path, '$displayTitle.$extension'));
    final temporary = File('${output.path}.part');
    try {
      if (await temporary.exists()) await temporary.delete();
      await source.copy(temporary.path);
      if (await temporary.length() != await source.length()) {
        throw const FileSystemException('Copied file length mismatch');
      }
      for (final existingExtension in supportedGameExtensions) {
        final existing = File(
          path.join(destination.path, '$displayTitle.$existingExtension'),
        );
        if (await existing.exists() && !path.equals(existing.path, output.path)) {
          await existing.delete();
        }
      }
      if (await output.exists()) await output.delete();
      await temporary.rename(output.path);
      return KartPadImportResult(
        imported: 1,
        rejected: 0,
        importedPaths: <String>[output.path],
      );
    } catch (error) {
      if (await temporary.exists()) await temporary.delete();
      return KartPadImportResult(
        imported: 0,
        rejected: 1,
        errors: <KartPadImportIssue>[
          KartPadImportIssue(picked.name, 'kartpadImportFailed', '$error'),
        ],
      );
    }
  }

  static Future<KartPadDiscIdentity?> inspectGameFile(File file) async {
    final extension =
        path.extension(file.path).replaceFirst('.', '').toLowerCase();
    if (extension == 'iso') return inspectRawIso(file);
    if (extension != 'wbfs') return null;

    try {
      final data = await _discIdentityChannel.invokeMapMethod<String, dynamic>(
        'saveIdentity',
        <String, dynamic>{'gamePath': file.path, 'system': 'wii'},
      );
      final gameId = data?['gameId']?.toString().trim().toUpperCase();
      if (gameId == null || gameId.isEmpty) return null;
      // Dolphin DiscIO validates the WBFS container and Wii volume here.
      // The current bridge does not expose disc/revision metadata, so KartPad's
      // own importer performs that final RMCP01 rev0 check before guest start.
      return KartPadDiscIdentity(gameId: gameId);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<KartPadDiscIdentity?> inspectRawIso(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final header = await handle.read(0x20);
      if (header.length < 0x20) return null;
      final gameId = String.fromCharCodes(header.sublist(0, 6)).toUpperCase();
      final magic = (header[0x18] << 24) |
          (header[0x19] << 16) |
          (header[0x1a] << 8) |
          header[0x1b];
      if (magic != 0x5D1C9EA3) return null;
      return KartPadDiscIdentity(
        gameId: gameId,
        discNumber: header[6],
        revision: header[7],
      );
    } catch (_) {
      return null;
    } finally {
      await handle?.close();
    }
  }

  static Future<KartPadLaunchResult> launch(
    String gamePath, {
    Map<String, String> uiText = const <String, String>{},
  }) async {
    await ensureLayout();
    final game = File(gamePath);
    if (!await game.exists() || await game.length() < 0x20) {
      return const KartPadLaunchResult(
        success: false,
        message: 'The selected Mario Kart Wii file is not readable.',
        stage: 'input',
        errorCode: 'KARTPAD_GAME_UNREADABLE',
      );
    }

    final identity = await inspectGameFile(game);
    if (identity == null ||
        identity.gameId != supportedDiscId ||
        (identity.hasExactRevisionMetadata &&
            (identity.discNumber != supportedDiscNumber ||
                identity.revision != supportedRevision))) {
      return const KartPadLaunchResult(
        success: false,
        message: 'KartPad requires Mario Kart Wii PAL RMCP01, disc 0, revision 0.',
        stage: 'input',
        errorCode: 'KARTPAD_GAME_UNSUPPORTED',
      );
    }

    if (!await ownsGamePath(gamePath)) {
      return const KartPadLaunchResult(
        success: false,
        message: 'Import Mario Kart Wii through the Ports menu before launching KartPad.',
        stage: 'ownership',
        errorCode: 'KARTPAD_GAME_OUTSIDE_LIBRARY',
      );
    }

    final temporary = await getTemporaryDirectory();
    final response = await KartPadInternalBridge.launch(
      gamePath: game.path,
      supportPath: (await rootDirectory()).path,
      cachePath: path.join(temporary.path, 'KartPad'),
      uiText: uiText,
    );
    final success = response['success'] == true;
    return KartPadLaunchResult(
      success: success,
      message: response['message']?.toString() ??
          (success
              ? 'KartPad session started.'
              : 'KartPadCore returned no launch detail.'),
      stage: response['stage']?.toString(),
      errorCode: response['errorCode']?.toString(),
      technicalDetails: <String>[
        if (response['buildNumber'] != null) 'Build: ${response['buildNumber']}',
        if (response['corePath'] != null) 'Core: ${response['corePath']}',
        if (response['runtimeIdentity'] != null)
          'Runtime: ${response['runtimeIdentity']}',
      ].join('\n'),
    );
  }

  static Future<bool> ownsGamePath(String gamePath) async {
    final games = await gamesDirectory();
    final root = path.normalize(games.path);
    final candidate = path.normalize(gamePath);
    return path.equals(root, candidate) || path.isWithin(root, candidate);
  }
}
