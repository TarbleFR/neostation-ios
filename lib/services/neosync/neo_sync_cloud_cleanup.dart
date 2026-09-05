import '../../models/neo_sync_models.dart';
import 'neo_sync_save_policy.dart';

class NeoSyncOriginIndex {
  final Map<String, Set<String>> _paths = {};
  String _key(String leaf, int size, String hash) => '$leaf/$size/${hash.toLowerCase()}';

  void add({required String path, required String leaf, required int size,
      required String checksum}) {
    final origin = NeoSyncSavePolicy.canonical(path);
    final switchSave = origin != null && origin.system == 'switch' &&
        origin.scope == 'game' && !origin.isState &&
        NeoSyncSavePolicy.classify(path) != NeoSyncSaveKind.foreign;
    if (!NeoSyncSavePolicy.isRpcs3Payload(path) && !switchSave) return;
    _paths.putIfAbsent(_key(leaf, size, checksum), () => <String>{}).add(path);
  }

  NeoSyncFile resolve(NeoSyncFile file) {
    if (file.saveKind != NeoSyncSaveKind.unresolved ||
        file.checksum == null) return file;
    final leaf = NeoSyncSavePolicy.unwrap(file.fileName).split('/').last;
    final candidates = _paths[_key(leaf, file.fileSize, file.checksum!)];
    if (candidates == null) return file;
    final known = NeoSyncSavePolicy.canonical(file.sourceSavePath);
    final matches = candidates.where((candidate) {
      if (known == null) return true;
      final origin = NeoSyncSavePolicy.canonical(candidate)!;
      // A shared icon/config hash cannot reassign an already known console or
      // game to another title that happens to retain identical bytes locally.
      return origin.system == known.system && origin.emulatorSlug == known.emulatorSlug &&
          origin.scope == known.scope && origin.gameName == known.gameName &&
          (origin.filePath == known.filePath || origin.filePath.endsWith('/${known.filePath}'));
    }).toList();
    return matches.length == 1 ? file.withVerifiedSourcePath(matches.single) : file;
  }
}

class NeoSyncCleanupResult {
  final List<NeoSyncFile> remaining;
  final List<String> deletedIds;
  final List<String> failedIds;
  final int unresolved;
  const NeoSyncCleanupResult(this.remaining, this.deletedIds, this.failedIds,
      this.unresolved);
}

/// Run only after a successful complete inventory and source investigation.
/// Deletion is per object, account-bound, and acknowledged before removing a row.
class NeoSyncCloudCleanup {
  static Future<NeoSyncCleanupResult> run({
    required List<NeoSyncFile> inventory,
    required Future<bool> Function() isCurrentAccount,
    required Future<bool> Function(NeoSyncFile) delete,
  }) async {
    final ids = <String>{};
    for (final file in inventory) {
      final rawId = file.id.startsWith('v1:') ? file.id.substring(3) : file.id;
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(rawId) || !ids.add(file.id)) {
        throw StateError('Invalid NeoSync inventory; no cleanup performed');
      }
    }
    final kept = <NeoSyncFile>[];
    final deleted = <String>[];
    final failed = <String>[];
    var unresolved = 0;
    for (final file in inventory) {
      if (!await isCurrentAccount()) {
        throw StateError('NeoSync account changed; cleanup stopped');
      }
      final kind = file.saveKind;
      if (kind == NeoSyncSaveKind.foreign) {
        var removed = false;
        try { removed = await delete(file); } catch (_) { /* retry next scan */ }
        if (removed) {
          deleted.add(file.id);
          continue;
        }
        failed.add(file.id);
      } else if (kind == NeoSyncSaveKind.unresolved) {
        unresolved++;
      }
      kept.add(file);
    }
    return NeoSyncCleanupResult(kept, deleted, failed, unresolved);
  }
}
