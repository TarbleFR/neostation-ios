import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:rpcs3_internal_bridge/rpcs3_internal_bridge.dart';

import 'rpcs3_internal_service.dart';
import 'rpcs3_library_service.dart';

class Rpcs3ContentImportProgress {
  const Rpcs3ContentImportProgress({
    required this.itemName,
    required this.itemIndex,
    required this.itemCount,
    required this.current,
    required this.total,
    required this.detail,
  });

  final String itemName;
  final int itemIndex;
  final int itemCount;
  final int current;
  final int total;
  final String detail;

  double? get fraction {
    if (total <= 0) return null;
    return (current / total).clamp(0.0, 1.0);
  }
}

/// RPCS3-only content importer.
///
/// iOS document URLs are opened in-place and kept security-scoped until the
/// Core finishes consuming them. This avoids FilePicker's intermediate copies
/// for multi-gigabyte PS3 content and restores the unpacked/decrypted folder
/// workflow supported by the standalone RPCS3 iOS application.
class Rpcs3ContentImportService {
  Rpcs3ContentImportService._();

  static final _progressController =
      StreamController<Rpcs3ContentImportProgress>.broadcast(sync: true);

  static Stream<Rpcs3ContentImportProgress> get progress =>
      _progressController.stream;

  static String _itemName = '';
  static int _itemIndex = 0;
  static int _itemCount = 0;

  static void _emit({
    int current = 0,
    int total = 0,
    String detail = '',
  }) {
    _progressController.add(
      Rpcs3ContentImportProgress(
        itemName: _itemName,
        itemIndex: _itemIndex,
        itemCount: _itemCount,
        current: current,
        total: total,
        detail: detail,
      ),
    );
  }

  static Future<T> _withNativeProgress<T>(Future<T> Function() action) async {
    final subscription = Rpcs3InternalBridge.installProgress.listen((event) {
      _emit(
        current: event.current,
        total: event.total,
        detail: event.detail,
      );
    });
    try {
      return await action();
    } finally {
      await subscription.cancel();
    }
  }

  static Future<Rpcs3ImportResult> importGames() async {
    final selected = await Rpcs3InternalBridge.pickGameFilesOpenInPlace();
    if (selected == null || selected.isEmpty) {
      return const Rpcs3ImportResult(imported: 0, rejected: 0);
    }

    final selectedKeys = <String, String>{};
    final gamePaths = <String>[];
    var rejected = 0;
    final errors = <String>[];

    for (final filePath in selected) {
      final extension = path.extension(filePath).toLowerCase();
      if (extension == '.key') {
        selectedKeys[path.withoutExtension(filePath).toLowerCase()] = filePath;
      } else if (const {'.pkg', '.zip', '.iso'}.contains(extension)) {
        gamePaths.add(filePath);
      } else {
        rejected++;
        errors.add('${path.basename(filePath)}: unsupported game format.');
      }
    }

    if (gamePaths.isEmpty) {
      await Rpcs3InternalBridge.releaseScopedResources();
      return Rpcs3ImportResult(
        imported: 0,
        rejected: rejected,
        errors: errors,
      );
    }

    var imported = 0;
    try {
      await Rpcs3InternalService.ensureManagementInitialized();
      _itemCount = gamePaths.length;

      for (var index = 0; index < gamePaths.length; index++) {
        final filePath = gamePaths[index];
        final name = path.basename(filePath);
        _itemName = name;
        _itemIndex = index + 1;
        _emit(detail: 'Preparing $name…');

        final extension = path.extension(filePath).toLowerCase();
        final report = await _withNativeProgress(() async {
          if (extension == '.pkg') {
            return Rpcs3InternalBridge.installPackage(filePath);
          }
          if (extension == '.zip') {
            return Rpcs3InternalBridge.installZip(filePath);
          }

          final stem = path.withoutExtension(filePath).toLowerCase();
          final selectedKey = selectedKeys[stem];
          String? keyPath = selectedKey;
          if (keyPath == null) {
            final sibling = File(path.setExtension(filePath, '.key'));
            if (await sibling.exists()) keyPath = sibling.path;
          }
          return Rpcs3InternalBridge.installIso(
            filePath,
            keyPath: keyPath,
          );
        });

        if (report['success'] == true) {
          imported++;
          _emit(current: 1, total: 1, detail: '$name imported.');
        } else {
          rejected++;
          errors.add(
            '$name: ${report['message'] ?? 'RPCS3 import failed.'}',
          );
        }
      }

      if (imported > 0) await Rpcs3LibraryService.syncInternalLibrary();
      return Rpcs3ImportResult(
        imported: imported,
        rejected: rejected,
        errors: errors,
      );
    } finally {
      _itemName = '';
      _itemIndex = 0;
      _itemCount = 0;
      await Rpcs3InternalBridge.releaseScopedResources();
    }
  }

  static Future<String?> _resolveUnpackedGameFolder(String selectedPath) async {
    Future<bool> directLayout(String root) async {
      return File(path.join(root, 'PARAM.SFO')).existsSync() &&
          File(path.join(root, 'USRDIR', 'EBOOT.BIN')).existsSync();
    }

    Future<bool> discLayout(String root) async {
      return File(path.join(root, 'PS3_GAME', 'PARAM.SFO')).existsSync() &&
          File(
            path.join(root, 'PS3_GAME', 'USRDIR', 'EBOOT.BIN'),
          ).existsSync();
    }

    if (await directLayout(selectedPath) || await discLayout(selectedPath)) {
      return selectedPath;
    }

    // Some decrypted dumps add one wrapper directory around PS3_GAME. A child
    // remains within the exact security scope granted for the selected folder.
    final root = Directory(selectedPath);
    if (await root.exists()) {
      final children = await root
          .list(followLinks: false)
          .where((entry) => entry is Directory)
          .cast<Directory>()
          .take(16)
          .toList();
      for (final child in children) {
        if (await directLayout(child.path) || await discLayout(child.path)) {
          return child.path;
        }
      }
    }
    return null;
  }

  static Future<bool> importExtractedGameFolder() async {
    final selected = await Rpcs3InternalBridge.pickGameFolderOpenInPlace();
    if (selected == null || selected.isEmpty) return false;

    try {
      final folder = await _resolveUnpackedGameFolder(selected);
      if (folder == null) {
        throw const Rpcs3InternalException(
          'invalidGameFolder',
          'Select a decrypted PS3 game folder containing PS3_GAME/PARAM.SFO and PS3_GAME/USRDIR/EBOOT.BIN, or PARAM.SFO and USRDIR/EBOOT.BIN.',
        );
      }

      await Rpcs3InternalService.ensureManagementInitialized();
      _itemName = path.basename(folder);
      _itemIndex = 1;
      _itemCount = 1;
      _emit(detail: 'Preparing decrypted game folder…');

      final report = await _withNativeProgress(
        () => Rpcs3InternalBridge.installFolder(folder),
      );
      if (report['success'] != true) {
        throw Rpcs3InternalException(
          'gameImportFailed',
          report['message']?.toString() ??
              'RPCS3 rejected the selected decrypted game folder.',
        );
      }

      await Rpcs3LibraryService.syncInternalLibrary();
      _emit(current: 1, total: 1, detail: 'Game folder imported.');
      return true;
    } finally {
      _itemName = '';
      _itemIndex = 0;
      _itemCount = 0;
      await Rpcs3InternalBridge.releaseScopedResources();
    }
  }
}
