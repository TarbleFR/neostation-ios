import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'rpcs3_library_service.dart';

/// Deletes only installations below the private RPCS3 Data root. No Core/JIT
/// is needed. Save data, savestates, firmware, licenses and caches are retained.
class Rpcs3GameDeletion {
  static Future<void> delete({
    required String dataRoot,
    required String titleId,
  }) async {
    final id = titleId.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]{4}[0-9]{5}$').hasMatch(id)) {
      throw ArgumentError.value(titleId, 'titleId', 'Invalid PS3 title ID');
    }
    final root = await Directory(dataRoot).resolveSymbolicLinks();
    final targets = <String>{};
    // Mirror the Core installation layout, including its legacy DiscImgs alias.
    final roots = <String>['dev_hdd0/game'];
    final games = Directory(path.join(root, 'games'));
    if (await games.exists()) {
      await for (final entry in games.list(followLinks: false)) {
        if ([
          'extractedgames',
          'discimages',
          'discimgs',
        ].contains(path.basename(entry.path).toLowerCase())) {
          if (entry is! Directory)
            throw FileSystemException('Invalid installation root', entry.path);
          final canonical = await entry.resolveSymbolicLinks();
          if (canonical != entry.path)
            throw FileSystemException('Linked installation root', entry.path);
          roots.add(path.relative(entry.path, from: root));
        }
      }
    }
    for (final relative in roots) {
      final directory = Directory(path.join(root, relative));
      try {
        if (await directory.resolveSymbolicLinks() != directory.path) {
          throw FileSystemException('Linked installation root', directory.path);
        }
        await for (final entry in directory.list(followLinks: false)) {
          final name = path.basename(entry.path).toUpperCase();
          if (name == id ||
              name.startsWith('${id}_') ||
              (entry is File && path.basenameWithoutExtension(name) == id)) {
            targets.add(entry.path);
          } else if (entry is Directory) {
            // Imported extracted folders can retain a human-readable name.
            for (final sfoPath in ['PARAM.SFO', 'PS3_GAME/PARAM.SFO']) {
              final sfo = File(path.join(entry.path, sfoPath));
              try {
                final values = Rpcs3LibraryService.parseParamSfoBytes(
                  await sfo.readAsBytes(),
                );
                if (values['TITLE_ID']?.toString().trim().toUpperCase() == id) {
                  targets.add(entry.path);
                }
              } on FileSystemException catch (error) {
                if (error.osError?.errorCode != 2) rethrow;
              }
            }
          }
        }
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode != 2) rethrow;
      }
    }

    // Validate the entire plan before removing anything. Symlinks (including
    // parent directory aliases) must never redirect this operation outside Data.
    for (final target in targets) {
      if (await FileSystemEntity.isLink(target)) {
        throw FileSystemException('Refusing linked installation', target);
      }
      final resolved = await File(target).resolveSymbolicLinks();
      if (!path.isWithin(root, resolved) ||
          path.normalize(resolved) != path.normalize(target)) {
        throw FileSystemException(
          'Installation escapes its private root',
          target,
        );
      }
    }
    for (final target in targets) {
      final type = await FileSystemEntity.type(target, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        await Directory(target).delete(recursive: true);
      } else {
        await File(target).delete();
      }
    }

    // games.yml is a registration cache, never authority for choosing files.
    // Drop only this exact key and preserve every other line verbatim.
    final registrations = File(path.join(root, 'games.yml'));
    try {
      final text = await registrations.readAsString();
      final key = RegExp('^\\s*["\']?$id["\']?\\s*:');
      final lines = const LineSplitter().convert(text);
      final retained = lines.where((line) => !key.hasMatch(line)).toList();
      if (retained.length != lines.length) {
        final staging = File('${registrations.path}.neostation-delete');
        await staging.writeAsString('${retained.join('\n')}\n', flush: true);
        await staging.rename(registrations.path);
      }
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != 2) rethrow;
    }
  }
}
