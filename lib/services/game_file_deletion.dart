import 'dart:io';

import 'package:external_folder_access/external_folder_access.dart';

import 'saf_directory_service.dart';

/// File removal is authoritative: a permission/I/O error must reach the UI
/// before database rows or media are removed. Never treat exists()==false as
/// proof of absence: on iOS it also hides denied security-scoped access.
class GameFileDeletion {
  static Future<void> delete(String value) async {
    final uri = Uri.tryParse(value);
    if (uri?.scheme == 'content') {
      if (!await SafDirectoryService.deleteFile(value)) {
        throw FileSystemException(
          'The document provider refused deletion',
          value,
        );
      }
      return;
    }
    if (uri != null && uri.hasScheme && uri.scheme != 'file') {
      throw FileSystemException(
        'This library URI requires its emulator deletion service',
        value,
      );
    }
    final target = uri?.scheme == 'file' ? uri!.toFilePath() : value;
    if (target.isEmpty || !File(target).isAbsolute) {
      throw FileSystemException(
        'Deletion requires an absolute game path',
        target,
      );
    }
    if (Platform.isIOS) {
      await ExternalFolderAccess.deleteGameFile(target);
      return;
    }
    try {
      // File.delete refuses directories; never recursively remove an arbitrary
      // ROM root. RPCS3 folder installations have their own bounded planner.
      await File(target).delete();
    } on FileSystemException catch (error) {
      // POSIX ENOENT only. EACCES/EPERM and all other failures stay visible.
      if (error.osError?.errorCode != 2) rethrow;
      // Verify that its parent is accessible before removing a stale DB row.
      await Directory(File(target).parent.path).list().drain<void>();
    }
  }
}
