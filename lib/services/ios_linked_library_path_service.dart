import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps iOS security-scoped library roots stable across File Provider path
/// churn. The logical bookmark stays the same even when iOS resolves it under a
/// different absolute container prefix after an app relaunch or re-sign.
class IosLinkedLibraryPathService {
  IosLinkedLibraryPathService._();

  static const retroArchPathKey = 'ios_linked_retroarch_resolved_path_v2';
  static const manicEmuPathKey = 'ios_linked_manicemu_resolved_path_v2';

  static Future<void> rememberRetroArch(String value) =>
      _remember(retroArchPathKey, value);

  static Future<void> rememberManicEmu(String value) =>
      _remember(manicEmuPathKey, value);

  static Future<void> _remember(String key, String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, normalized);
  }

  static Future<List<String>> reconcile({
    required List<String> configuredFolders,
    required String? retroArchPath,
    required String? manicEmuPath,
    int maximumFolders = 5,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final folders = <String>[...configuredFolders];
    final protected = <String>{
      if (retroArchPath?.trim().isNotEmpty == true) retroArchPath!.trim(),
      if (manicEmuPath?.trim().isNotEmpty == true) manicEmuPath!.trim(),
    };

    Future<void> reconcileOne(String key, String? currentValue) async {
      final current = currentValue?.trim();
      if (current == null || current.isEmpty) return;

      final already = folders.indexWhere(
        (value) => path.equals(value, current),
      );
      if (already >= 0) {
        await prefs.setString(key, current);
        return;
      }

      String? replacement;
      final previous = prefs.getString(key)?.trim();
      if (previous != null && previous.isNotEmpty) {
        final previousIndex = folders.indexWhere(
          (value) => path.equals(value, previous),
        );
        if (previousIndex >= 0) replacement = folders[previousIndex];
      }

      // Migration for builds that predate the resolved-path marker. The old
      // and new security-scoped locations normally keep the same final folder
      // name while only the File Provider/container prefix changes.
      if (replacement == null) {
        final basename = path.basename(current).toLowerCase();
        final sameNameUnavailable = <String>[];
        for (final candidate in folders) {
          if (protected.any((value) => path.equals(value, candidate))) continue;
          if (path.basename(candidate).toLowerCase() != basename) continue;
          if (!await isReadableFolder(candidate)) {
            sameNameUnavailable.add(candidate);
          }
        }
        if (sameNameUnavailable.length == 1) {
          replacement = sameNameUnavailable.single;
        }
      }

      // Older App Store-era builds did not persist a logical path marker. If
      // exactly one dead security-scoped File Provider root remains, it is the
      // safe migration candidate for the currently resolved bookmark.
      if (replacement == null) {
        final staleScoped = <String>[];
        for (final candidate in folders) {
          if (protected.any((value) => path.equals(value, candidate))) continue;
          if (!_looksSecurityScoped(candidate)) continue;
          if (!await isReadableFolder(candidate)) staleScoped.add(candidate);
        }
        if (staleScoped.length == 1) replacement = staleScoped.single;
      }

      if (replacement != null) {
        final index = folders.indexOf(replacement);
        if (index >= 0) folders[index] = current;
      } else if (folders.length < maximumFolders) {
        folders.add(current);
      }

      await prefs.setString(key, current);
    }

    await reconcileOne(retroArchPathKey, retroArchPath);
    await reconcileOne(manicEmuPathKey, manicEmuPath);

    final deduplicated = <String>[];
    for (final folder in folders) {
      if (!deduplicated.any((existing) => path.equals(existing, folder))) {
        deduplicated.add(folder);
      }
    }
    return deduplicated;
  }

  static Future<List<String>> unreadableFolders(
    Iterable<String> folders,
  ) async {
    final unavailable = <String>[];
    for (final folder in folders) {
      final value = folder.trim();
      if (value.isEmpty) continue;
      if (!await isReadableFolder(value)) unavailable.add(value);
    }
    return unavailable;
  }

  static Future<bool> isReadableFolder(String value) async {
    try {
      final directory = Directory(value);
      if (!await directory.exists()) return false;
      await directory
          .list(recursive: false, followLinks: false)
          .take(1)
          .drain<void>()
          .timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool _looksSecurityScoped(String value) {
    final lower = value.replaceAll('\\', '/').toLowerCase();
    return lower.contains('/file provider storage/') ||
        lower.contains('/containers/shared/appgroup/');
  }
}
