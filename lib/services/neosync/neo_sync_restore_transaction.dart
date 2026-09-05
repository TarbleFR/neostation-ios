import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// One member of a native save. The caller resolves its path and verifies the
/// downloaded bytes against the cloud size/checksum before returning them.
class NeoSyncRestoreEntry {
  final File destination;
  final Future<List<int>> Function() loadVerifiedBytes;
  final DateTime? modified;

  /// A caller-trusted emulator/save root. Its platform alias may be resolved,
  /// but symbolic links inside it are never followed when restoring members.
  final Directory? root;

  const NeoSyncRestoreEntry({
    required this.destination,
    required this.loadVerifiedBytes,
    this.modified,
    this.root,
  });
}

/// A concurrent local edit prevented rollback. Keep these originals for
/// recovery instead of deleting a backup or replacing the concurrent edit.
class NeoSyncRestoreRecoveryRequired implements Exception {
  final Object cause;
  final List<String> backupPaths;

  NeoSyncRestoreRecoveryRequired(this.cause, Iterable<String> backupPaths)
    : backupPaths = List.unmodifiable(backupPaths);

  @override
  String toString() => 'NeoSync restore interrupted: $cause. '
      'Original saves retained at: ${backupPaths.join(', ')}';
}

/// Stages a complete logical save before touching any existing member.
///
/// Each rename remains on the destination filesystem. A failed download,
/// account change, local edit, or failed commit rolls back earlier members.
/// This protects an in-process restore; it is not a crash-recovery journal.
class NeoSyncRestoreTransaction {
  static Future<void> restore(
    List<NeoSyncRestoreEntry> entries, {
    required FutureOr<bool> Function() isCurrentAccount,
    Future<void> Function(int index, File destination)? beforeCommit,
  }) async {
    final pending = <_PendingRestore>[];
    final createdDirectories = <Directory>[];
    Future<void> checkAccount() async {
      if (!await isCurrentAccount()) {
        throw StateError('NeoSync account changed; restore stopped');
      }
    }

    try {
      await checkAccount();
      final destinations = <String>{};
      for (final entry in entries) {
        final resolved = await _resolve(entry);
        final identity = _identity(resolved.destination.path);
        if (!destinations.add(identity) ||
            destinations.any((other) => other != identity &&
                (p.isWithin(other, identity) || p.isWithin(identity, other)))) {
          throw StateError('Duplicate or overlapping NeoSync restore paths');
        }
        await _checkPath(resolved.root, resolved.destination);
        resolved.original = await _Fingerprint.read(resolved.destination);
        pending.add(resolved);
      }

      for (final member in pending) {
        await checkAccount();
        final bytes = List<int>.from(await member.entry.loadVerifiedBytes());
        await checkAccount();
        await _createParents(member, createdDirectories);
        final directory = await member.destination.parent.createTemp(
          '.neosync-restore-',
        );
        member.stagingDirectory = directory;
        member.staged = File(p.join(directory.path, 'incoming'));
        member.backup = File(p.join(directory.path, 'original'));
        member.expectedHash = sha256.convert(bytes).toString();
        await member.staged!.writeAsBytes(bytes, flush: true);
        await _checkStaged(member);
      }

      // Check the whole save before the first write, and each member again
      // immediately before replacing it. A game may have saved during fetch.
      await checkAccount();
      for (final member in pending) {
        await _checkUnchanged(member);
      }
      for (var index = 0; index < pending.length; index++) {
        final member = pending[index];
        await checkAccount();
        if (beforeCommit != null) {
          await beforeCommit(index, member.destination);
        }
        await checkAccount();
        await _checkUnchanged(member);
        await _checkStaged(member);
        if (member.original != null) {
          await member.destination.rename(member.backup!.path);
          member.originalMoved = true;
        }
        await member.staged!.rename(member.destination.path);
        member.installed = true;
        if (member.entry.modified != null) {
          await member.destination.setLastModified(member.entry.modified!);
        }
        await checkAccount();
      }
    } catch (error, stack) {
      final retained = <String>[];
      for (final member in pending.reversed) {
        if (!member.originalMoved && !member.installed) continue;
        try {
          await _checkPath(member.root, member.destination);
          if (member.originalMoved) {
            await _checkPath(member.root, member.backup!);
            final original = await _Fingerprint.read(member.backup!);
            if (original == null || original.hash != member.original!.hash) {
              throw StateError('NeoSync original backup verification failed');
            }
          }
          if (member.installed) {
            final current = await _Fingerprint.read(member.destination);
            if (current != null && current.hash != member.expectedHash) {
              throw StateError('Restored member was edited during rollback');
            }
            if (current != null) await member.destination.delete();
          } else if (await FileSystemEntity.type(
                member.destination.path, followLinks: false,
              ) != FileSystemEntityType.notFound) {
            throw StateError('Restore destination appeared during rollback');
          }
          if (member.originalMoved) {
            await member.backup!.rename(member.destination.path);
            member.originalMoved = false;
          }
          member.installed = false;
        } catch (_) {
          // Never erase the only remaining original if rollback cannot finish.
          member.keepBackup = true;
          if (member.originalMoved) retained.add(member.backup!.path);
          if (!member.originalMoved) retained.add(member.destination.path);
        }
      }
      if (retained.isNotEmpty) {
        throw NeoSyncRestoreRecoveryRequired(error, retained);
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      for (final member in pending) {
        final directory = member.stagingDirectory;
        if (directory == null || member.keepBackup) continue;
        try {
          await directory.delete(recursive: true);
        } catch (_) {
          // A cleanup error must not misreport a successfully committed save.
        }
      }
      for (final directory in createdDirectories.reversed) {
        try {
          await directory.delete(); // Empty directories only, never save data.
        } catch (_) {
          // A successful restore or concurrent save may have filled it.
        }
      }
    }
  }

  static String _identity(String path) =>
      Platform.isIOS || Platform.isMacOS || Platform.isWindows
          ? path.toLowerCase() : path;

  static Future<_PendingRestore> _resolve(NeoSyncRestoreEntry entry) async {
    final originalPath = entry.destination.absolute.path;
    if (p.split(originalPath).contains('..')) {
      throw StateError('NeoSync destination contains parent traversal');
    }
    final destination = p.normalize(originalPath);
    var root = entry.root?.absolute ?? Directory(p.dirname(destination));
    if (entry.root == null) {
      while (!await root.exists()) {
        final parent = root.parent;
        if (parent.path == root.path) break;
        root = parent;
      }
    }
    final rootPath = p.normalize(root.absolute.path);
    if (!p.isWithin(rootPath, destination)) {
      throw StateError('NeoSync destination is outside its save root');
    }
    // Resolving only the trusted root supports iOS /var and selected aliases.
    final resolvedRoot = Directory(await root.resolveSymbolicLinks());
    final resolvedDestination = File(p.join(
      resolvedRoot.path, p.relative(destination, from: rootPath),
    ));
    return _PendingRestore(entry, resolvedRoot, resolvedDestination);
  }

  static Future<void> _checkPath(Directory root, File destination) async {
    if (!p.isWithin(root.path, destination.path)) {
      throw StateError('NeoSync destination escaped its save root');
    }
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await root.resolveSymbolicLinks() != root.path) {
      throw StateError('NeoSync save root changed during restore');
    }
    var current = root.path;
    final segments = p.split(p.relative(destination.path, from: root.path));
    for (var index = 0; index < segments.length; index++) {
      current = p.join(current, segments[index]);
      final type = await FileSystemEntity.type(current, followLinks: false);
      final leaf = index == segments.length - 1;
      if (type == FileSystemEntityType.link ||
          (type != FileSystemEntityType.notFound &&
              type != (leaf ? FileSystemEntityType.file : FileSystemEntityType.directory))) {
        throw StateError('Unsafe NeoSync restore path: $current');
      }
    }
  }

  static Future<void> _createParents(
    _PendingRestore member, List<Directory> created,
  ) async {
    await _checkPath(member.root, member.destination);
    var current = member.root.path;
    final segments = p.split(p.relative(
      member.destination.parent.path, from: member.root.path,
    ));
    for (final segment in segments) {
      if (segment == '.') continue;
      current = p.join(current, segment);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        final directory = Directory(current);
        await directory.create();
        created.add(directory);
      } else if (type != FileSystemEntityType.directory) {
        throw StateError('Unsafe NeoSync save directory: $current');
      }
    }
    await _checkPath(member.root, member.destination);
  }

  static Future<void> _checkUnchanged(_PendingRestore member) async {
    await _checkPath(member.root, member.destination);
    final current = await _Fingerprint.read(member.destination);
    if (!_Fingerprint.same(member.original, current)) {
      throw StateError('Local save changed during NeoSync restore: '
          '${member.destination.path}');
    }
  }

  static Future<void> _checkStaged(_PendingRestore member) async {
    await _checkPath(member.root, member.staged!);
    final staged = await _Fingerprint.read(member.staged!);
    if (staged == null || staged.hash != member.expectedHash) {
      throw StateError('NeoSync staged save verification failed');
    }
  }
}

class _PendingRestore {
  final NeoSyncRestoreEntry entry;
  final Directory root;
  final File destination;
  _Fingerprint? original;
  Directory? stagingDirectory;
  File? staged;
  File? backup;
  String? expectedHash;
  bool originalMoved = false;
  bool installed = false;
  bool keepBackup = false;

  _PendingRestore(this.entry, this.root, this.destination);
}

class _Fingerprint {
  final int size;
  final DateTime modified;
  final DateTime changed;
  final String hash;

  _Fingerprint(FileStat stat, this.hash)
    : size = stat.size, modified = stat.modified, changed = stat.changed;

  static Future<_Fingerprint?> read(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw StateError('NeoSync save member is not a regular file');
    }
    final before = await file.stat();
    final digest = await sha256.bind(file.openRead()).first;
    final after = await file.stat();
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file || before.size != after.size ||
        before.modified != after.modified || before.changed != after.changed) {
      throw StateError('NeoSync save member changed while reading');
    }
    return _Fingerprint(after, digest.toString());
  }

  static bool same(_Fingerprint? left, _Fingerprint? right) =>
      left == null ? right == null : right != null &&
          left.size == right.size && left.modified == right.modified &&
          left.changed == right.changed && left.hash == right.hash;
}
