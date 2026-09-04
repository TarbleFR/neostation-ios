import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'logger_service.dart';
import 'pairing_file_service.dart';

/// NeoStation-owned GameCube/Wii runtime and library.
///
/// Dolphin is intentionally treated as an implementation detail. No external
/// bundle identifier, URL scheme, Shortcut or DolphiniOS folder is referenced
/// anywhere in this service.
class DolphinEmbeddedService {
  DolphinEmbeddedService._();

  static const MethodChannel _channel = MethodChannel(
    'neostation/dolphin_internal',
  );
  static final LoggerService _log = LoggerService.instance;

  static const Set<String> _gameExtensions = {
    'iso',
    'gcm',
    'ciso',
    'gcz',
    'rvz',
    'wia',
    'wbfs',
    'dol',
    'elf',
    'tgc',
  };

  // Known retail GameCube IPL CRC32 values used by Dolphin itself. Triforce's
  // IPL (D1883221) is deliberately not accepted as a GameCube IPL.
  static const Set<int> _knownNtscIplCrc32 = {
    0x6dac1f2a,
    0xd5e6feea,
    0xd235e3f9,
    0x86573808,
    0x667d0b64,
  };
  static const Set<int> _knownPalIplCrc32 = {
    0x4f319f43,
    0xad1b7f16,
  };
  static const int _officialIplSize = 2 * 1024 * 1024;

  static bool isDolphinSystemFolder(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'gc' || normalized == 'wii';
  }

  static Future<DolphinDirectories> ensureLayout() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(path.join(support.path, 'NeoStation', 'Dolphin'));
    final library = Directory(path.join(root.path, 'Library'));
    final gameCube = Directory(path.join(library.path, 'gc'));
    final wii = Directory(path.join(library.path, 'wii'));
    final user = Directory(path.join(root.path, 'User'));
    final logs = Directory(path.join(root.path, 'Logs'));
    final metadata = Directory(path.join(root.path, 'Metadata'));
    final crashMarkers = Directory(path.join(root.path, 'CrashMarkers'));

    final required = <Directory>[
      root,
      library,
      gameCube,
      wii,
      user,
      logs,
      metadata,
      crashMarkers,
      Directory(path.join(user.path, 'Config')),
      Directory(path.join(user.path, 'GC', 'USA')),
      Directory(path.join(user.path, 'GC', 'EUR')),
      Directory(path.join(user.path, 'GC', 'JAP')),
      Directory(path.join(user.path, 'Wii')),
      Directory(path.join(user.path, 'StateSaves')),
      Directory(path.join(user.path, 'Cache')),
      Directory(path.join(user.path, 'Cache', 'Shaders')),
      Directory(path.join(user.path, 'Load')),
      Directory(path.join(user.path, 'Dump')),
      Directory(path.join(user.path, 'ScreenShots')),
    ];
    for (final directory in required) {
      await directory.create(recursive: true);
    }

    return DolphinDirectories(
      root: root,
      library: library,
      gameCube: gameCube,
      wii: wii,
      user: user,
      logs: logs,
      metadata: metadata,
      crashMarkers: crashMarkers,
    );
  }

  /// Root registered with NeoStation's scanner. It contains the canonical
  /// `gc` and `wii` system folders while remaining hidden from the user.
  static Future<String> internalLibraryRootPath() async {
    return (await ensureLayout()).library.path;
  }

  static Future<DolphinGameImportResult?> importGamesFromPicker(
    String systemFolder,
  ) async {
    final normalized = systemFolder.trim().toLowerCase();
    if (!isDolphinSystemFolder(normalized)) {
      throw ArgumentError.value(systemFolder, 'systemFolder');
    }

    final picked = await FilePicker.pickFiles(
      dialogTitle: normalized == 'gc'
          ? 'Import GameCube games'
          : 'Import Wii games',
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: _gameExtensions.toList()..sort(),
      withData: false,
      withReadStream: true,
    );
    if (picked == null || picked.files.isEmpty) return null;

    final directories = await ensureLayout();
    final destination = normalized == 'gc'
        ? directories.gameCube
        : directories.wii;
    var imported = 0;
    final rejected = <String, String>{};
    final importedPaths = <String>[];

    for (final selected in picked.files) {
      final safeName = path.basename(selected.name).trim();
      final extension = path.extension(safeName).replaceFirst('.', '').toLowerCase();
      if (safeName.isEmpty || !_gameExtensions.contains(extension)) {
        rejected[selected.name] = 'Unsupported GameCube/Wii image format.';
        continue;
      }
      if (selected.size <= 0) {
        rejected[selected.name] = 'The selected file is empty.';
        continue;
      }

      final target = await _availableDestination(destination, safeName);
      final temporary = File('${target.path}.importing');
      try {
        if (await temporary.exists()) await temporary.delete();
        await _copyPlatformFile(selected, temporary);
        if (!await temporary.exists() || await temporary.length() <= 0) {
          throw const FileSystemException('Imported file is empty');
        }
        await temporary.rename(target.path);
        imported++;
        importedPaths.add(target.path);
        await _appendEvent(
          directories,
          stage: 'library_import',
          status: 'success',
          details: {
            'system': normalized,
            'file': target.path,
            'bytes': await target.length(),
          },
        );
      } catch (error) {
        if (await temporary.exists()) {
          try {
            await temporary.delete();
          } catch (_) {}
        }
        rejected[selected.name] = error.toString();
        await _appendEvent(
          directories,
          stage: 'library_import',
          status: 'failure',
          details: {
            'system': normalized,
            'file': selected.name,
            'error': error.toString(),
          },
        );
      }
    }

    return DolphinGameImportResult(
      imported: imported,
      rejected: rejected,
      importedPaths: importedPaths,
    );
  }

  static Future<DolphinIplImportResult?> importIplFromPicker(
    DolphinIplRegion region,
  ) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Import GameCube IPL ${region.label}',
      allowMultiple: false,
      type: FileType.any,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return null;

    final selected = picked.files.single;
    final bytes = await _readPlatformFileBytes(selected);
    final validation = validateIpl(bytes, region);
    final directories = await ensureLayout();

    if (!validation.accepted) {
      await _appendEvent(
        directories,
        stage: 'ipl_validation',
        status: 'failure',
        details: {
          'region': region.label,
          'sourceName': selected.name,
          'reason': validation.message,
          'bytes': bytes.length,
          'crc32': validation.crc32Hex,
        },
      );
      return DolphinIplImportResult(
        accepted: false,
        region: region,
        message: validation.message,
        crc32Hex: validation.crc32Hex,
      );
    }

    final regionDirectory = Directory(
      path.join(directories.user.path, 'GC', region.directoryName),
    );
    await regionDirectory.create(recursive: true);
    final target = File(path.join(regionDirectory.path, 'IPL.bin'));
    final temporary = File('${target.path}.importing');
    if (await temporary.exists()) await temporary.delete();
    await temporary.writeAsBytes(bytes, flush: true);

    // Validate the actual staged bytes again. A successful picker read is not
    // considered installation until the exact on-disk copy also passes.
    final stagedValidation = validateIpl(await temporary.readAsBytes(), region);
    if (!stagedValidation.accepted) {
      await temporary.delete();
      await _appendEvent(
        directories,
        stage: 'ipl_install',
        status: 'failure',
        details: {
          'region': region.label,
          'reason': 'Staged IPL failed validation: ${stagedValidation.message}',
        },
      );
      return DolphinIplImportResult(
        accepted: false,
        region: region,
        message: 'The copied IPL failed final validation.',
        crc32Hex: stagedValidation.crc32Hex,
      );
    }

    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
    final manifest = File(
      path.join(directories.metadata.path, 'ipl_${region.name}.json'),
    );
    await manifest.writeAsString(
      jsonEncode({
        'schema': 1,
        'region': region.label,
        'directory': region.directoryName,
        'path': target.path,
        'bytes': bytes.length,
        'crc32': validation.crc32Hex,
        'validatedAt': DateTime.now().toUtc().toIso8601String(),
        'headerNintendo': true,
        'headerArtX': true,
        'knownRetailDump': true,
      }),
      flush: true,
    );

    await _appendEvent(
      directories,
      stage: 'ipl_install',
      status: 'success',
      details: {
        'region': region.label,
        'path': target.path,
        'crc32': validation.crc32Hex,
      },
    );
    return DolphinIplImportResult(
      accepted: true,
      region: region,
      message: 'IPL ${region.label} validated and installed.',
      crc32Hex: validation.crc32Hex,
      installedPath: target.path,
    );
  }

  static DolphinIplValidation validateIpl(
    List<int> input,
    DolphinIplRegion region,
  ) {
    if (input.length != _officialIplSize) {
      return DolphinIplValidation.rejected(
        'Invalid IPL size: expected exactly 2 MiB, found ${input.length} bytes.',
      );
    }

    final bytes = input is Uint8List ? input : Uint8List.fromList(input);
    final header = const Latin1Decoder(allowInvalid: true).convert(
      bytes.sublist(0, 0x100),
    );
    final hasNintendo = header.contains('Nintendo');
    final hasArtX = header.contains('ArtX Inc.');
    if (!hasNintendo || !hasArtX) {
      return DolphinIplValidation.rejected(
        'The expected Nintendo/ArtX IPL header is missing.',
      );
    }

    // Reject obviously blank/corrupt content even before the authoritative CRC
    // check. This also produces a clearer diagnostic for all-zero placeholders.
    var nonZero = 0;
    final seen = <int>{};
    for (var index = 0; index < bytes.length; index += 4096) {
      final value = bytes[index];
      if (value != 0) nonZero++;
      seen.add(value);
    }
    if (nonZero < 32 || seen.length < 8) {
      return DolphinIplValidation.rejected(
        'The IPL content appears blank, truncated or structurally corrupt.',
      );
    }

    final crc32 = _crc32(bytes);
    final knownNtsc = _knownNtscIplCrc32.contains(crc32);
    final knownPal = _knownPalIplCrc32.contains(crc32);
    if (!knownNtsc && !knownPal) {
      return DolphinIplValidation.rejected(
        'Unknown or damaged GameCube IPL dump (CRC32 ${_hex32(crc32)}).',
        crc32: crc32,
      );
    }

    if (region == DolphinIplRegion.eur && !knownPal) {
      return DolphinIplValidation.rejected(
        'This is an NTSC IPL and cannot be installed in the EUR slot.',
        crc32: crc32,
      );
    }
    if (region != DolphinIplRegion.eur && !knownNtsc) {
      return DolphinIplValidation.rejected(
        'This is a PAL IPL and cannot be installed in the ${region.label} slot.',
        crc32: crc32,
      );
    }

    // Retail USA and JAP dumps share CRCs for some hardware revisions. The
    // selected slot therefore supplies the USA/JAP distinction only after the
    // content has passed the exact known-good NTSC CRC gate.
    return DolphinIplValidation.accepted(crc32);
  }

  static Future<Set<DolphinIplRegion>> installedIplRegions() async {
    final directories = await ensureLayout();
    final installed = <DolphinIplRegion>{};
    for (final region in DolphinIplRegion.values) {
      final file = File(
        path.join(
          directories.user.path,
          'GC',
          region.directoryName,
          'IPL.bin',
        ),
      );
      if (!await file.exists()) continue;
      try {
        final validation = validateIpl(await file.readAsBytes(), region);
        if (validation.accepted) installed.add(region);
      } catch (_) {
        // A stale/corrupt file is intentionally not advertised as installed.
      }
    }
    return installed;
  }

  static Future<DolphinLaunchOutcome> launchGame({
    required String systemFolder,
    required String gamePath,
  }) async {
    final normalized = systemFolder.trim().toLowerCase();
    if (!isDolphinSystemFolder(normalized)) {
      return const DolphinLaunchOutcome.failure(
        'Internal Dolphin accepts only GameCube and Wii playlists.',
      );
    }

    final image = File(gamePath);
    if (!await image.exists()) {
      return DolphinLaunchOutcome.failure(
        'Game image is not readable.',
        details: gamePath,
      );
    }
    if (!await PairingFileService.hasStoredPairingFile()) {
      return const DolphinLaunchOutcome.failure(
        'A valid pairing file is required before Dolphin JIT can start.',
        details: 'Import a pairing file in NeoStation StikJIT settings.',
      );
    }

    final directories = await ensureLayout();
    final timestamp = DateTime.now().toUtc();
    final token = timestamp.toIso8601String().replaceAll(RegExp(r'[^0-9]'), '');
    final logFile = File(path.join(directories.logs.path, 'launch-$token.jsonl'));
    final markerFile = File(
      path.join(directories.crashMarkers.path, 'active-launch.json'),
    );
    final pairingFile = await PairingFileService.storedFile();

    await markerFile.writeAsString(
      jsonEncode({
        'schema': 1,
        'state': 'preparing',
        'system': normalized,
        'gamePath': gamePath,
        'logPath': logFile.path,
        'startedAt': timestamp.toIso8601String(),
      }),
      flush: true,
    );
    await _appendLaunchEvent(
      logFile,
      stage: 'launch_requested',
      status: 'success',
      details: {'system': normalized, 'gamePath': gamePath},
    );

    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'launchGame',
        {
          'gamePath': gamePath,
          'expectedSystem': normalized,
          'userDirectory': directories.user.path,
          'pairingFilePath': pairingFile.path,
          'logPath': logFile.path,
          'markerPath': markerFile.path,
        },
      );
      final result = response ?? const <String, dynamic>{};
      final requiredReady = result['stikjitConnected'] == true &&
          result['pidAttached'] == true &&
          result['legacyHandshakeValidated'] == true &&
          result['executableMemoryValidated'] == true &&
          result['jitArm64Initialized'] == true &&
          result['metalInitialized'] == true &&
          result['imageAccepted'] == true &&
          result['gameSubmitted'] == true;

      if (result['success'] == true && requiredReady) {
        await markerFile.writeAsString(
          jsonEncode({
            'schema': 1,
            'state': 'running',
            'system': normalized,
            'gamePath': gamePath,
            'logPath': logFile.path,
            'startedAt': timestamp.toIso8601String(),
            'native': result,
          }),
          flush: true,
        );
        _log.i('[DolphinInternal] launch gate passed for $gamePath');
        return DolphinLaunchOutcome.success(
          logPath: logFile.path,
          nativeDetails: result,
        );
      }

      final message = result['message']?.toString() ??
          'Dolphin launch readiness gate did not pass.';
      await _appendLaunchEvent(
        logFile,
        stage: 'launch_authorization',
        status: 'failure',
        details: {'message': message, 'native': result},
      );
      return DolphinLaunchOutcome.failure(
        message,
        details: logFile.path,
        nativeDetails: result,
      );
    } on PlatformException catch (error) {
      final details = '${error.code}: ${error.message ?? 'Unknown native error'}';
      await _appendLaunchEvent(
        logFile,
        stage: 'native_bridge',
        status: 'failure',
        details: {'error': details, 'details': error.details?.toString()},
      );
      _log.e('[DolphinInternal] $details');
      return DolphinLaunchOutcome.failure(
        error.message ?? 'Internal Dolphin failed before launch.',
        details: '${logFile.path}\n$details',
      );
    } catch (error, stackTrace) {
      await _appendLaunchEvent(
        logFile,
        stage: 'dart_bridge',
        status: 'failure',
        details: {'error': error.toString(), 'stack': stackTrace.toString()},
      );
      _log.e('[DolphinInternal] launch exception: $error');
      return DolphinLaunchOutcome.failure(
        'Internal Dolphin failed before launch.',
        details: '${logFile.path}\n$error',
      );
    }
  }

  static Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
  }

  static Future<File> _availableDestination(
    Directory directory,
    String fileName,
  ) async {
    final stem = path.basenameWithoutExtension(fileName);
    final extension = path.extension(fileName);
    var candidate = File(path.join(directory.path, fileName));
    var suffix = 2;
    while (await candidate.exists()) {
      candidate = File(path.join(directory.path, '$stem ($suffix)$extension'));
      suffix++;
    }
    return candidate;
  }

  static Future<void> _copyPlatformFile(
    PlatformFile selected,
    File destination,
  ) async {
    final sourcePath = selected.path;
    if (sourcePath != null) {
      final source = File(sourcePath);
      if (await source.exists()) {
        await source.openRead().pipe(destination.openWrite());
        return;
      }
    }
    final stream = selected.readStream;
    if (stream != null) {
      await stream.pipe(destination.openWrite());
      return;
    }
    final bytes = selected.bytes;
    if (bytes != null) {
      await destination.writeAsBytes(bytes, flush: true);
      return;
    }
    throw const FileSystemException('The selected file cannot be read.');
  }

  static Future<List<int>> _readPlatformFileBytes(PlatformFile selected) async {
    final sourcePath = selected.path;
    if (sourcePath != null) {
      final source = File(sourcePath);
      if (await source.exists()) return source.readAsBytes();
    }
    if (selected.bytes != null) return selected.bytes!;
    final stream = selected.readStream;
    if (stream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        builder.add(chunk);
        if (builder.length > _officialIplSize) break;
      }
      return builder.takeBytes();
    }
    throw const FileSystemException('The selected IPL cannot be read.');
  }

  static Future<void> _appendEvent(
    DolphinDirectories directories, {
    required String stage,
    required String status,
    required Map<String, Object?> details,
  }) async {
    final file = File(path.join(directories.logs.path, 'library.jsonl'));
    await _appendLaunchEvent(
      file,
      stage: stage,
      status: status,
      details: details,
    );
  }

  static Future<void> _appendLaunchEvent(
    File file, {
    required String stage,
    required String status,
    required Map<String, Object?> details,
  }) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode({
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'component': 'DolphinInternal',
        'stage': stage,
        'status': status,
        'details': details,
      })}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  static int _crc32(List<int> data) {
    var crc = 0xffffffff;
    for (final byte in data) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        final mask = -(crc & 1);
        crc = (crc >> 1) ^ (0xedb88320 & mask);
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  static String _hex32(int value) =>
      value.toUnsigned(32).toRadixString(16).padLeft(8, '0').toUpperCase();
}

class DolphinDirectories {
  const DolphinDirectories({
    required this.root,
    required this.library,
    required this.gameCube,
    required this.wii,
    required this.user,
    required this.logs,
    required this.metadata,
    required this.crashMarkers,
  });

  final Directory root;
  final Directory library;
  final Directory gameCube;
  final Directory wii;
  final Directory user;
  final Directory logs;
  final Directory metadata;
  final Directory crashMarkers;
}

class DolphinGameImportResult {
  const DolphinGameImportResult({
    required this.imported,
    required this.rejected,
    required this.importedPaths,
  });

  final int imported;
  final Map<String, String> rejected;
  final List<String> importedPaths;
}

enum DolphinIplRegion {
  usa('USA', 'USA'),
  eur('EUR', 'EUR'),
  jap('JAP', 'JAP');

  const DolphinIplRegion(this.label, this.directoryName);
  final String label;
  final String directoryName;
}

class DolphinIplValidation {
  const DolphinIplValidation._({
    required this.accepted,
    required this.message,
    this.crc32,
  });

  factory DolphinIplValidation.accepted(int crc32) => DolphinIplValidation._(
        accepted: true,
        message: 'Known retail GameCube IPL dump.',
        crc32: crc32,
      );

  factory DolphinIplValidation.rejected(String message, {int? crc32}) =>
      DolphinIplValidation._(
        accepted: false,
        message: message,
        crc32: crc32,
      );

  final bool accepted;
  final String message;
  final int? crc32;
  String? get crc32Hex => crc32 == null
      ? null
      : crc32!.toUnsigned(32).toRadixString(16).padLeft(8, '0').toUpperCase();
}

class DolphinIplImportResult {
  const DolphinIplImportResult({
    required this.accepted,
    required this.region,
    required this.message,
    this.crc32Hex,
    this.installedPath,
  });

  final bool accepted;
  final DolphinIplRegion region;
  final String message;
  final String? crc32Hex;
  final String? installedPath;
}

class DolphinLaunchOutcome {
  const DolphinLaunchOutcome._({
    required this.success,
    required this.message,
    this.details,
    this.logPath,
    this.nativeDetails = const <String, dynamic>{},
  });

  const DolphinLaunchOutcome.failure(
    String message, {
    String? details,
    Map<String, dynamic> nativeDetails = const <String, dynamic>{},
  }) : this._(
          success: false,
          message: message,
          details: details,
          nativeDetails: nativeDetails,
        );

  factory DolphinLaunchOutcome.success({
    required String logPath,
    required Map<String, dynamic> nativeDetails,
  }) => DolphinLaunchOutcome._(
        success: true,
        message: 'Internal Dolphin started.',
        logPath: logPath,
        nativeDetails: nativeDetails,
      );

  final bool success;
  final String message;
  final String? details;
  final String? logPath;
  final Map<String, dynamic> nativeDetails;
}
