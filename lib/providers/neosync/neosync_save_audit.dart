part of '../neo_sync_provider.dart';

extension NeoSyncSaveAudit on NeoSyncProvider {
  /// Recover unresolved rows from native PS3/MeloNX savedata and exact bytes.
  /// Common icons/configs can occur in several games or profiles, so every
  /// candidate is inspected and ambiguous matches remain untouched.
  Future<List<NeoSyncFile>> _resolveNeoSyncOrigins(List<NeoSyncFile> files) async {
    final account = _dolphinAccount;
    final pending = files.where((f) => f.saveKind == NeoSyncSaveKind.unresolved &&
      RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(f.checksum ?? '')).toList();
    if (pending.isEmpty) return files;
    final wanted = <String>{for (final f in pending)
      '${NeoSyncSavePolicy.unwrap(f.fileName).split('/').last}/${f.fileSize}'};
    final matches = NeoSyncOriginIndex();

    void checkAccount() {
      if (!isNeoSyncAuthenticated || account != _dolphinAccount) {
        throw StateError('NeoSync account changed during source investigation');
      }
    }

    Future<void> inspect(File file, Future<String?> Function() resolve) async {
      checkAccount();
      try {
        final before = await file.stat();
        final identity = '${path.basename(file.path)}/${before.size}';
        if (!wanted.contains(identity)) return;
        final hash = (await file.openRead().transform(saveCrypto.md5).first).toString();
        final after = await file.stat();
        if (before.size != after.size || before.modified != after.modified) return;
        if (!pending.any((f) => f.checksum!.toLowerCase() == hash)) return;
        final origin = await resolve();
        checkAccount();
        if (origin != null) {
          matches.add(path: origin, leaf: path.basename(file.path),
            size: before.size, checksum: hash);
        }
      } on FileSystemException catch (error) {
        NeoSyncProvider._log.w('NeoSync source unavailable: $error');
      }
    }

    final ps3Root = Rpcs3LibraryService.linkedDataPath;
    if (ps3Root != null && ps3Root.isNotEmpty) {
      final home = Directory(path.join(ps3Root, 'dev_hdd0', 'home'));
      if (await home.exists()) {
        await for (final profile in home.list(followLinks: false)) {
          checkAccount();
          if (profile is! Directory ||
              !RegExp(r'^[0-9]{8}$').hasMatch(path.basename(profile.path))) continue;
          final savedata = Directory(path.join(profile.path, 'savedata'));
          if (!await savedata.exists()) continue;
          await for (final file in savedata.list(recursive: true, followLinks: false)) {
            if (file is! File) continue;
            await inspect(file, () async =>
              (await _resolveRpcs3FileForCloud(file, ps3Root))?.cloudPath);
          }
        }
      }
    }

    final melonxRoot = ConfigService.linkedMelonxSaveFolderPath;
    if (melonxRoot != null && melonxRoot.isNotEmpty) {
      final root = Directory(melonxRoot);
      if (await root.exists()) {
        // The folder link may point to bis, user/save, an account, or one title.
        // The strict native parser runs before hashing, so installed games and
        // DLC are never read as candidates even when the link is the app root.
        await for (final file in root.list(recursive: true, followLinks: false)) {
          checkAccount();
          if (file is! File ||
              NeoSyncSavePolicy.melonxLocation(file.path, melonxRoot) == null) continue;
          await inspect(file, () async =>
            (await _resolveMeloNXFileForCloud(file, melonxRoot))?.cloudPath);
        }
      }
    }

    checkAccount();
    return files.map((file) {
      if (!pending.contains(file)) return file;
      final resolved = matches.resolve(file);
      if (resolved.verifiedSourcePath != null) {
        NeoSyncProvider._log.i('NeoSync source recovered: ${file.id} -> ${resolved.verifiedSourcePath}');
      }
      return resolved;
    }).toList();
  }
}
