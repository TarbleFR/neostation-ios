import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Files-visible home for NeoStation diagnostic artifacts.
class DiagnosticsDirectory {
  DiagnosticsDirectory._();

  static Future<Directory> directory() async {
    final documents = await getApplicationDocumentsDirectory();
    final diagnostics = Directory(path.join(documents.path, 'Diagnostics'));
    await diagnostics.create(recursive: true);
    return diagnostics;
  }

  static Future<File> file(String name) async {
    final diagnostics = await directory();
    return File(path.join(diagnostics.path, path.basename(name)));
  }

  static bool _isLegacyRootDiagnostic(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('_debug.txt') ||
        lower.endsWith('-debug.txt') ||
        lower.startsWith('diagnostic-') ||
        lower == 'rpcs3-diagnostic.log' ||
        lower == 'rpcs3-milestones.log';
  }

  /// Moves logs left by older builds out of the Files-visible Documents root.
  static Future<int> migrateLegacyRootFiles() async {
    final documents = await getApplicationDocumentsDirectory();
    final diagnostics = await directory();
    var moved = 0;

    await for (final entity in documents.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = path.basename(entity.path);
      if (!_isLegacyRootDiagnostic(name)) continue;

      var target = File(path.join(diagnostics.path, name));
      if (await target.exists()) {
        final stem = path.basenameWithoutExtension(name);
        final ext = path.extension(name);
        target = File(path.join(
          diagnostics.path,
          '$stem-legacy-${DateTime.now().microsecondsSinceEpoch}$ext',
        ));
      }
      try {
        await entity.rename(target.path);
        moved++;
      } catch (_) {
        try {
          await entity.copy(target.path);
          await entity.delete();
          moved++;
        } catch (_) {}
      }
    }
    return moved;
  }
}
