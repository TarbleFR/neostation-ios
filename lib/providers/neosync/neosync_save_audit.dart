part of '../neo_sync_provider.dart';

extension NeoSyncSaveAudit on NeoSyncProvider {
  /// The caller owns the normal Dolphin save lock. Keep this separate from
  /// the public audit wrapper so game sync can resolve the same old inventory
  /// without recursively acquiring the launch/save exclusion.
  Future<List<NeoSyncFile>> _recoverDolphinOrigins(List<NeoSyncFile> files,
      DolphinNeoSyncStore store, {required String account}) async {
    final pending = files.where(NeoSyncOriginIndex.isDolphinCandidate).toList();
    if (pending.isEmpty) return files;
    final matches = NeoSyncOriginIndex();
    final inspected = <String>{};
    void checkAccount() {
      if (!isNeoSyncAuthenticated || account != _dolphinAccount) {
        throw StateError('NeoSync account changed during Dolphin source investigation');
      }
    }
    checkAccount();
    for (final system in ['gc', 'wii']) {
      final requested = pending.where((file) =>
          NeoSyncOriginIndex.isDolphinCandidate(file, system: system)).toList();
      if (requested.isEmpty) continue;
      final leaves = requested.map(NeoSyncOriginIndex.leafFor).toSet();
      try {
        final rows = await GameRepository.loadGamesForSystem(system);
        checkAccount();
        for (final row in rows) {
          checkAccount();
          final game = GameModel.fromDatabaseModel(row);
          if (game.romPath?.isNotEmpty != true) continue;
          try {
            // DiscIO reads native identity without booting the core.
            final identity = await DolphinInternalV2Service.readSaveIdentity(
                system, game.romPath!);
            checkAccount();
            final targets = await store.targetsForGame(identity);
            checkAccount();
            for (final target in targets) {
              if (!leaves.contains(target.objectName) ||
                  !inspected.add(target.cloudPath)) continue;
              try {
                final snapshot = await store.snapshot(target);
                checkAccount();
                if (snapshot == null || !requested.any((file) =>
                    NeoSyncOriginIndex.leafFor(file) == target.objectName &&
                    file.fileSize == snapshot.size &&
                    file.checksum!.toLowerCase() == snapshot.checksum)) continue;
                matches.add(path: target.cloudPath, leaf: target.objectName,
                    size: snapshot.size, checksum: snapshot.checksum);
              } catch (error) {
                checkAccount();
                NeoSyncProvider._log.w('NeoSync Dolphin snapshot unavailable: $error');
              }
            }
          } catch (error) {
            // Missing ROMs and invalid saves cannot erase the inventory or
            // authorize a guessed association with a different local title.
            checkAccount();
            NeoSyncProvider._log.w('NeoSync Dolphin source unavailable: $error');
          }
        }
      } catch (error) {
        checkAccount();
        NeoSyncProvider._log.w('NeoSync Dolphin catalog unavailable: $error');
      }
    }
    checkAccount();
    return files.map(matches.resolve).toList();
  }

  /// Recover unresolved rows from native savedata and exact bytes.
  /// Common icons/configs can occur in several games or profiles, so every
  /// candidate is inspected and ambiguous matches remain untouched.
  Future<List<NeoSyncFile>> _resolveNeoSyncOrigins(List<NeoSyncFile> files) async {
    final account = _dolphinAccount;
    final pending = files.where((f) => f.saveKind == NeoSyncSaveKind.unresolved &&
      RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(f.checksum ?? '')).toList();
    if (pending.isEmpty) return files;
    final wanted = <String>{for (final f in pending)
      '${NeoSyncOriginIndex.leafFor(f)}/${f.fileSize}'};
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

    if (Platform.isIOS && pending.any(NeoSyncOriginIndex.isDolphinCandidate)) {
      try {
        files = await _dolphinExclusive((store) =>
            _recoverDolphinOrigins(files, store, account: account));
      } catch (error) {
        checkAccount();
        // A running game owns the native save tree. Defer investigation until
        // it releases the existing save lock; keep every unresolved object.
        NeoSyncProvider._log.w('NeoSync Dolphin source investigation deferred: $error');
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
