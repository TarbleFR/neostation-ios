import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../models/neo_sync_models.dart';

/// A game is synchronized only when every native save/state has a matching
/// cloud object with the same content. Listing order, size and mtime alone are
/// insufficient: two different saves can have identical sizes and timestamps.
class NeoSyncStatusRules {
  static String identity(String value) {
    final normalized = value.replaceAll('\\', '/');
    const compressionSuffix = '.neosync.gz';
    return normalized.toLowerCase().endsWith(compressionSuffix)
        ? normalized.substring(0, normalized.length - compressionSuffix.length)
        : normalized;
  }

  static bool _hasHash(String? value) => value != null &&
      RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(value);

  static Future<GameSyncStatus> compare(
    LocalSaveFile? local,
    NeoSyncFile? cloud, {
    Future<Map<String, dynamic>?> Function(String path)? readSyncState,
  }) async {
    if (local == null) return cloud == null
        ? GameSyncStatus.noSaveFound : GameSyncStatus.cloudOnly;
    if (cloud == null) return GameSyncStatus.localOnly;
    if (identity(local.relativePath) != identity(cloud.sourceSavePath)) {
      throw StateError('Cannot compare different NeoSync save identities');
    }

    try {
      final file = File(local.filePath);
      final before = await file.stat();
      if (before.type == FileSystemEntityType.notFound) return GameSyncStatus.cloudOnly;
      if (before.type != FileSystemEntityType.file ||
          await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
        return GameSyncStatus.error;
      }
      final bytes = await file.readAsBytes();
      final after = await file.stat();
      if (before.size != after.size || before.modified != after.modified ||
          bytes.length != before.size) {
        return GameSyncStatus.localOnly;
      }
      final localHash = md5.convert(bytes).toString();
      final compressed = cloud.fileName.toLowerCase().endsWith('.neosync.gz') ||
          cloud.sourceSavePath.toLowerCase().endsWith('.neosync.gz');
      final payloadHash = compressed ? md5.convert(gzip.encode(bytes)).toString() : localHash;
      final cloudHash = cloud.checksum?.toLowerCase();
      if (_hasHash(cloudHash) && payloadHash == cloudHash) return GameSyncStatus.upToDate;

      // ARMSX2 cards can retain an old filesystem timestamp after an in-game
      // write. An existing different card must never be replaced by clock age.
      if (cloud.sourceSavePath.toLowerCase().contains('/ps2/armsx2/') &&
          identity(cloud.sourceSavePath).toLowerCase().endsWith('.ps2')) {
        return GameSyncStatus.localOnly;
      }

      final cloudTime = cloud.fileModifiedAtTimestamp ?? 0;
      final localTime = after.modified.millisecondsSinceEpoch;
      final saved = await readSyncState?.call(local.filePath);
      if (saved != null) {
        final savedHash = saved['file_hash']?.toString().toLowerCase();
        final savedLocal = int.tryParse('${saved['local_modified_at']}') ?? 0;
        final savedCloud = int.tryParse('${saved['cloud_updated_at']}') ?? 0;
        final localChanged = _hasHash(savedHash)
            ? savedHash != localHash && savedHash != payloadHash
            : (localTime - savedLocal).abs() > 2000;
        final cloudChanged = cloudTime > savedCloud;
        if (localChanged) return GameSyncStatus.localOnly;
        if (cloudChanged) return GameSyncStatus.cloudOnly;
      }
      // Equal clocks are not proof of equal bytes; preserve the local copy
      // until upload/check confirms it, instead of displaying a false check.
      return cloudTime > localTime
          ? GameSyncStatus.cloudOnly : GameSyncStatus.localOnly;
    } catch (_) {
      return GameSyncStatus.error;
    }
  }

  static Future<GameSyncStatus> aggregate(
    List<LocalSaveFile> locals,
    List<NeoSyncFile> clouds, {
    Future<Map<String, dynamic>?> Function(String path)? readSyncState,
  }) async {
    final localByKey = <String, LocalSaveFile>{};
    final cloudByKey = <String, NeoSyncFile>{};
    for (final local in locals) {
      final key = identity(local.relativePath);
      // Two distinct roots cannot be certified against a single remote file.
      if (localByKey.containsKey(key) && localByKey[key]!.filePath != local.filePath) {
        return GameSyncStatus.error;
      }
      localByKey[key] = local;
    }
    for (final cloud in clouds) {
      final key = identity(cloud.sourceSavePath);
      final previous = cloudByKey[key];
      if (previous != null && previous.checksum?.toLowerCase() != cloud.checksum?.toLowerCase()) {
        return GameSyncStatus.error;
      }
      cloudByKey[key] = cloud;
    }
    final keys = <String>{...localByKey.keys, ...cloudByKey.keys};
    if (keys.isEmpty) return GameSyncStatus.noSaveFound;
    var uploadPending = false;
    var downloadPending = false;
    for (final key in keys) {
      final status = await compare(localByKey[key], cloudByKey[key], readSyncState: readSyncState);
      if (status == GameSyncStatus.error) return GameSyncStatus.error;
      uploadPending |= status == GameSyncStatus.localOnly;
      downloadPending |= status == GameSyncStatus.cloudOnly;
    }
    if (uploadPending) return GameSyncStatus.localOnly;
    if (downloadPending) return GameSyncStatus.cloudOnly;
    return GameSyncStatus.upToDate;
  }
}
