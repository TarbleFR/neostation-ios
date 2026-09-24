import 'dart:io';

import 'package:file_picker/file_picker.dart';
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

class KartPadDiscIdentity {
  const KartPadDiscIdentity({
    required this.gameId,
    required this.discNumber,
    required this.revision,
  });
  final String gameId;
  final int discNumber;
  final int revision;
}

/// Stage-1 user-data boundary for the future embedded KartPad Core.
class KartPadInternalService {
  KartPadInternalService._();

  static const String displayTitle = 'Mario Kart Wii';
  static const String supportedDiscId = 'RMCP01';
  static const int supportedDiscNumber = 0;
  static const int supportedRevision = 0;
  static const Set<String> supportedGameExtensions = <String>{'iso'};

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

    final identity = await inspectRawIso(source);
    if (identity == null || identity.gameId != supportedDiscId) {
      return KartPadImportResult(
        imported: 0,
        rejected: 1,
        errors: <KartPadImportIssue>[
          KartPadImportIssue(picked.name, 'kartpadUnsupportedDisc'),
        ],
      );
    }
    if (identity.discNumber != supportedDiscNumber ||
        identity.revision != supportedRevision) {
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
    final output = File(path.join(destination.path, '$displayTitle.iso'));
    final temporary = File('${output.path}.part');
    try {
      if (await temporary.exists()) await temporary.delete();
      await source.copy(temporary.path);
      if (await temporary.length() != await source.length()) {
        throw const FileSystemException('Copied file length mismatch');
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

  static Future<bool> ownsGamePath(String gamePath) async {
    final games = await gamesDirectory();
    final root = path.normalize(games.path);
    final candidate = path.normalize(gamePath);
    return path.equals(root, candidate) || path.isWithin(root, candidate);
  }
}
