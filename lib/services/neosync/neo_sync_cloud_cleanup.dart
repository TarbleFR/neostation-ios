import '../../models/neo_sync_models.dart';
import '../dolphin_neosync_store.dart';
import 'neo_sync_save_policy.dart';

class NeoSyncOriginIndex {
  final Map<String, Set<String>> _paths = {};
  String _key(String leaf, int size, String hash) => '$leaf/$size/${hash.toLowerCase()}';

  /// Older typed inventories retain the object basename but sometimes lost
  /// the native title ID. This is only a request to investigate local saves;
  /// neither the display label nor the .nsav extension proves their origin.
  static String leafFor(NeoSyncFile file) => NeoSyncSavePolicy.unwrap(
      file.fileName.trim().isEmpty ? file.filePath : file.fileName).split('/').last;

  static String? _dolphinSystem(NeoSyncFile file) {
    final known = NeoSyncSavePolicy.canonical(file.sourceSavePath);
    final emulator = file.emulator?.trim().toLowerCase() ?? '';
    if (emulator.isNotEmpty && emulator != DolphinSaveTarget.emulator) return null;
    final metadataSystem = file.systemName?.trim().toLowerCase() ?? '';
    final system = known?.system ?? metadataSystem;
    if (known != null && known.emulatorSlug != DolphinSaveTarget.emulator) return null;
    if (known != null && metadataSystem.isNotEmpty && metadataSystem != known.system) return null;
    if (system == 'gc' || system == 'wii') {
      return emulator == DolphinSaveTarget.emulator || known != null ? system : null;
    }
    // Pre-typed uploads used these fixed internal-save labels. An explicit
    // different console is binding even when a user reused the same label.
    if (system.isNotEmpty || emulator.isNotEmpty) return null;
    return switch (file.gameName.trim().toLowerCase()) {
      'gc memory cards' => 'gc',
      'wii saves' => 'wii',
      _ => null,
    };
  }

  static bool isDolphinCandidate(NeoSyncFile file, {String? system}) {
    if (file.saveKind != NeoSyncSaveKind.unresolved ||
        !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(file.checksum ?? '')) return false;
    final hint = _dolphinSystem(file);
    if (hint == null || (system != null && hint != system)) return false;
    final leaf = leafFor(file);
    return hint == 'gc'
        ? RegExp(r'^(?:gci-(?:USA|EUR|JAP)-[AB]|MemoryCard[AB]\.(?:USA|EUR|JAP)(?:\.[0-9]+)?\.raw|[A-Z0-9]{6}\.s(?:0[1-9]|10))\.nsav$').hasMatch(leaf)
        : leaf == 'wii-data.nsav' ||
            RegExp(r'^[A-Z0-9]{4}(?:[A-Z0-9]{2})?\.s(?:0[1-9]|10)\.nsav$').hasMatch(leaf);
  }

  void add({required String path, required String leaf, required int size,
      required String checksum}) {
    final origin = NeoSyncSavePolicy.canonical(path);
    final switchSave = origin != null && origin.system == 'switch' &&
        origin.scope == 'game' && !origin.isState &&
        NeoSyncSavePolicy.classify(path) != NeoSyncSaveKind.foreign;
    if (!NeoSyncSavePolicy.isRpcs3Payload(path) && !switchSave &&
        DolphinSaveTarget.parse(path) == null) return;
    _paths.putIfAbsent(_key(leaf, size, checksum), () => <String>{}).add(path);
  }

  NeoSyncFile resolve(NeoSyncFile file) {
    if (file.saveKind != NeoSyncSaveKind.unresolved ||
        file.checksum == null) return file;
    final leaf = leafFor(file);
    final candidates = _paths[_key(leaf, file.fileSize, file.checksum!)];
    if (candidates == null) return file;
    final known = NeoSyncSavePolicy.canonical(file.sourceSavePath);
    final matches = candidates.where((candidate) {
      final target = DolphinSaveTarget.parse(candidate);
      if (target != null) {
        if (!isDolphinCandidate(file, system: target.system)) return false;
        if (file.scope?.isNotEmpty == true &&
            file.scope != (target.shared ? 'shared' : 'game')) return false;
        final type = file.type.trim().toLowerCase();
        if (type.isNotEmpty && type != (target.isState ? 'state' : 'save') &&
            !(target.shared && type == 'shared')) return false;
        if (known == null) return true;
        if (known.system != target.system || known.emulatorSlug != DolphinSaveTarget.emulator ||
            known.scope != (target.shared ? 'shared' : 'game') ||
            known.isState != target.isState || known.filePath != target.objectName) return false;
        // A title ID is binding. Only the two historical fixed UI labels may
        // be replaced by the identity embedded in an exactly matching snapshot.
        final label = known.gameName?.trim().toLowerCase();
        return known.gameName == target.identity ||
            (!target.isState && label == (target.system == 'gc' ? 'gc memory cards' : 'wii saves'));
      }
      if (isDolphinCandidate(file)) return false;
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
