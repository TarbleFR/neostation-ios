import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_7zip/flutter_7zip.dart' as f7z;
import 'config_service.dart';
import '../utils/optimized_md5_utils.dart';
import 'package:neostation/services/logger_service.dart';

/// Service responsible for managing compressed archive operations (ZIP, 7z).
///
/// Primarily used to temporarily extract ROM files stored in archives before
/// passing them to emulators that do not support reading from compressed containers.
class ArchiveService {
  static final _log = LoggerService.instance;

  /// Extracts a ROM from a ZIP or 7z archive into a temporary system-specific directory.
  ///
  /// The extraction target is located at `user-data/temp/[systemFolderName]/[archiveName]`.
  /// Identifies and returns the path to the largest file within the archive,
  /// which is typically the actual ROM image.
  /// Returns null if extraction fails or no file is found.
  static Future<String?> extractRom(
    String archivePath,
    String systemFolderName,
  ) async {
    try {
      final userDataPath = await ConfigService.getUserDataPath();
      final archiveName = path.basename(archivePath);
      final extension = path.extension(archivePath).toLowerCase();

      final tempDirPath = path.join(
        userDataPath,
        'temp',
        systemFolderName,
        archiveName,
      );
      final tempDir = Directory(tempDirPath);

      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      await tempDir.create(recursive: true);

      if (extension == '.7z') {
        return await _extract7z(archivePath, tempDirPath);
      } else {
        return await _extractZip(archivePath, tempDirPath);
      }
    } catch (e) {
      _log.e('Error extracting file $archivePath: $e');
      return null;
    }
  }

  /// Internal logic for 7z extraction using the native 7zip library.
  ///
  /// Handles Scoped Storage (SAF) on Android by copying the archive to a
  /// temporary file if necessary.
  static Future<String?> _extract7z(
    String archivePath,
    String tempDirPath,
  ) async {
    try {
      String pathToExtract = archivePath;
      bool isTempFile = false;

      if (Platform.isAndroid && archivePath.startsWith('content://')) {
        final tempFile = File(path.join(tempDirPath, 'temp_rom.7z'));
        final bytes = await OptimizedMd5Utils.readAllBytes(archivePath);
        await tempFile.writeAsBytes(bytes);
        pathToExtract = tempFile.path;
        isTempFile = true;
      }

      final archive = f7z.SZArchive.open(pathToExtract);
      String? largestFilePath;
      int largestSize = -1;
      int largestIndex = -1;

      for (int i = 0; i < archive.numFiles; i++) {
        final file = archive.getFile(i);
        if (!file.isDirectory) {
          if (file.size > largestSize) {
            largestSize = file.size;
            largestIndex = i;
          }
        }
      }

      if (largestIndex != -1) {
        final file = archive.getFile(largestIndex);
        final outPath = path.join(tempDirPath, file.name);

        final outFile = File(outPath);
        if (!await outFile.parent.exists()) {
          await outFile.parent.create(recursive: true);
        }

        archive.extractToFile(largestIndex, outPath);
        largestFilePath = outPath;
      }

      archive.dispose();

      if (isTempFile) {
        await File(pathToExtract).delete();
      }

      return largestFilePath;
    } catch (e) {
      _log.e('Error extracting 7z $archivePath: $e');
      return null;
    }
  }

  /// Internal logic for ZIP extraction using the pure Dart [Archive] package.
  ///
  /// Decodes bytes directly to support Scoped Storage (SAF) URI sources.
  static Future<String?> _extractZip(String zipPath, String tempDirPath) async {
    try {
      final bytes = await OptimizedMd5Utils.readAllBytes(zipPath);
      final archive = ZipDecoder().decodeBytes(bytes);

      ArchiveFile? largestFile;

      for (final file in archive) {
        if (file.isFile) {
          if (largestFile == null || file.size > largestFile.size) {
            largestFile = file;
          }
        }
      }

      if (largestFile != null) {
        final filePath = path.join(tempDirPath, largestFile.name);
        final outFile = File(filePath);
        await outFile.create(recursive: true);

        await outFile.writeAsBytes(largestFile.content as List<int>);

        return filePath;
      }
      return null;
    } catch (e) {
      _log.e('Error extracting ZIP $zipPath: $e');
      return null;
    }
  }

  /// Recursively deletes the temporary folder created during extraction.
  ///
  /// Should be called after the emulator process terminates to free up disk space.
  static Future<void> cleanupTempFolder(
    String systemFolderName,
    String zipPath,
  ) async {
    try {
      final userDataPath = await ConfigService.getUserDataPath();
      final zipName = path.basename(zipPath);
      final tempDirPath = path.join(
        userDataPath,
        'temp',
        systemFolderName,
        zipName,
      );
      final tempDir = Directory(tempDirPath);

      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (e) {
      _log.e('Error deleting temp folder: $e');
    }
  }
}
