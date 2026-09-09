import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'dolphin_internal_v2_service.dart';
import 'logger_service.dart';

class DolphinSmartImportResult {
  const DolphinSmartImportResult({
    required this.imported,
    required this.rejected,
    required this.changedSystems,
    this.errors = const <String>[],
  });

  final int imported;
  final int rejected;
  final Set<String> changedSystems;
  final List<String> errors;
}

/// Routes every selected Dolphin image by the platform reported by DiscIO,
/// never by the library screen from which the picker was opened.
///
/// The native `saveIdentity` bridge is intentionally used here because it can
/// inspect ISO, RVZ, WIA, GCZ, CISO, WBFS and WAD metadata without starting the
/// Dolphin core or requiring JIT. This keeps GameCube images out of the Wii
/// playlist and Wii images out of the GameCube playlist.
class DolphinSmartImportService {
  DolphinSmartImportService._();

  static const MethodChannel _channel = MethodChannel(
    'neostation/dolphin_internal',
  );
  static final _log = LoggerService.instance;

  static Set<String> get supportedExtensions => <String>{
    ...DolphinInternalV2Service.extensionsFor('gc'),
    ...DolphinInternalV2Service.extensionsFor('wii'),
  };

  static Future<String?> detectSystem(String gamePath) async {
    for (final system in const <String>['gc', 'wii']) {
      try {
        final identity = await _channel.invokeMapMethod<String, dynamic>(
          'saveIdentity',
          <String, dynamic>{'gamePath': gamePath, 'system': system},
        );
        if (identity != null && identity['system']?.toString() == system) {
          return system;
        }
      } on PlatformException catch (error) {
        _log.w(
          'Dolphin platform detection failed for $gamePath/$system: $error',
        );
      }
    }
    return null;
  }

  static Future<DolphinSmartImportResult> importGames({
    required String requestedSystem,
  }) async {
    final requested = requestedSystem.trim().toLowerCase();
    if (!DolphinInternalV2Service.isDolphinSystem(requested)) {
      throw ArgumentError.value(requestedSystem, 'requestedSystem');
    }

    await DolphinInternalV2Service.ensureLayout();
    final extensions = supportedExtensions.toList()..sort();
    final selection = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: extensions,
      withData: false,
      lockParentWindow: true,
    );
    if (selection == null) {
      return const DolphinSmartImportResult(
        imported: 0,
        rejected: 0,
        changedSystems: <String>{},
      );
    }

    var imported = 0;
    var rejected = 0;
    final changedSystems = <String>{};
    final errors = <String>[];

    for (final picked in selection.files) {
      final sourcePath = picked.path;
      final extension = path
          .extension(picked.name)
          .replaceFirst('.', '')
          .toLowerCase();
      if (sourcePath == null || !extensions.contains(extension)) {
        rejected++;
        errors.add('${picked.name}: unsupported Dolphin image.');
        continue;
      }

      final source = File(sourcePath);
      if (!await source.exists()) {
        rejected++;
        errors.add('${picked.name}: source file is not readable.');
        continue;
      }

      final actualSystem = await detectSystem(source.path);
      if (actualSystem == null) {
        rejected++;
        errors.add('${picked.name}: Dolphin could not identify this image.');
        continue;
      }

      try {
        final destination = await DolphinInternalV2Service.libraryDirectory(
          actualSystem,
        );
        await destination.create(recursive: true);
        final output = await _uniqueDestination(destination, picked.name);
        await source.copy(output.path);
        final sourceLength = await source.length();
        final outputLength = await output.length();
        if (sourceLength <= 0 || sourceLength != outputLength) {
          await _deleteIfExists(output);
          throw FileSystemException('Copied image length mismatch');
        }

        imported++;
        changedSystems.add(actualSystem);
        _log.i(
          actualSystem == requested
              ? 'Dolphin imported ${picked.name} into $actualSystem.'
              : 'Dolphin auto-routed ${picked.name} from $requested to $actualSystem.',
        );
      } catch (error) {
        rejected++;
        errors.add('${picked.name}: $error');
      }
    }

    return DolphinSmartImportResult(
      imported: imported,
      rejected: rejected,
      changedSystems: changedSystems,
      errors: errors,
    );
  }

  /// Silently repairs files imported by older builds into the opposite private
  /// playlist. A valid image is moved only when DiscIO positively identifies
  /// the other platform; unreadable/unknown files are left untouched.
  static Future<Set<String>> repairLibraryPlacement() async {
    await DolphinInternalV2Service.ensureLayout();
    final changedSystems = <String>{};

    for (final declaredSystem in const <String>['gc', 'wii']) {
      final sourceDirectory = await DolphinInternalV2Service.libraryDirectory(
        declaredSystem,
      );
      if (!await sourceDirectory.exists()) continue;

      await for (final entity in sourceDirectory.list(followLinks: false)) {
        if (entity is! File) continue;
        final extension = path
            .extension(entity.path)
            .replaceFirst('.', '')
            .toLowerCase();
        if (!supportedExtensions.contains(extension)) continue;

        final actualSystem = await detectSystem(entity.path);
        if (actualSystem == null || actualSystem == declaredSystem) continue;

        final targetDirectory = await DolphinInternalV2Service.libraryDirectory(
          actualSystem,
        );
        await targetDirectory.create(recursive: true);
        final output = await _uniqueDestination(
          targetDirectory,
          path.basename(entity.path),
        );

        try {
          await entity.rename(output.path);
        } on FileSystemException {
          await entity.copy(output.path);
          final sourceLength = await entity.length();
          final outputLength = await output.length();
          if (sourceLength <= 0 || sourceLength != outputLength) {
            await _deleteIfExists(output);
            continue;
          }
          await entity.delete();
        }

        changedSystems
          ..add(declaredSystem)
          ..add(actualSystem);
        _log.i(
          'Dolphin repaired ${path.basename(entity.path)}: '
          '$declaredSystem -> $actualSystem.',
        );
      }
    }

    return changedSystems;
  }

  static Future<File> _uniqueDestination(
    Directory directory,
    String originalName,
  ) async {
    final safeName = path.basename(originalName);
    var candidate = File(path.join(directory.path, safeName));
    if (!await candidate.exists()) return candidate;

    final stem = path.basenameWithoutExtension(safeName);
    final extension = path.extension(safeName);
    for (var index = 2; index < 10000; index++) {
      candidate = File(
        path.join(directory.path, '$stem ($index)$extension'),
      );
      if (!await candidate.exists()) return candidate;
    }
    throw FileSystemException('No free destination name for $safeName');
  }

  static Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
