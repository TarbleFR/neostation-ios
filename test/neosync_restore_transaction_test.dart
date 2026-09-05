import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/neosync/neo_sync_restore_transaction.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('neosync-restore-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  File local(String relative) => File(p.join(root.path, relative));

  Future<File> write(String relative, List<int> bytes) async {
    final file = local(relative);
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes, flush: true);
  }

  NeoSyncRestoreEntry entry(String relative, List<int> bytes,
      {DateTime? modified}) => NeoSyncRestoreEntry(
    destination: local(relative),
    root: root,
    modified: modified,
    loadVerifiedBytes: () async => bytes,
  );

  Future<void> expectNoStaging() async {
    expect(await root.list(recursive: true).where((entity) =>
        p.basename(entity.path).startsWith('.neosync-restore-')).toList(),
      isEmpty);
  }

  test('PS3 save restores all native members together without renaming formats', () async {
    const base = 'dev_hdd0/home/00000001/savedata/BLES00050-SAVE';
    await write('$base/PARAM.SFO', [1, 2]);
    await write('$base/PLAYDATA', [3, 4]);
    final modified = DateTime.utc(2026, 9, 4, 12);
    await NeoSyncRestoreTransaction.restore([
      entry('$base/PARAM.SFO', [9, 8], modified: modified),
      entry('$base/PLAYDATA', [7, 6]),
      entry('$base/sub/ICON0.PNG', [5, 4, 3]),
    ], isCurrentAccount: () async => true);
    expect(await local('$base/PARAM.SFO').readAsBytes(), [9, 8]);
    expect(await local('$base/PLAYDATA').readAsBytes(), [7, 6]);
    expect(await local('$base/sub/ICON0.PNG').readAsBytes(), [5, 4, 3]);
    expect((await local('$base/PARAM.SFO').lastModified()).toUtc(), modified);
    await expectNoStaging();
  });

  test('failed member download leaves every existing member untouched', () async {
    await write('title/main', [1]);
    await write('title/profile', [2]);
    await expectLater(NeoSyncRestoreTransaction.restore([
      entry('title/main', [9]),
      NeoSyncRestoreEntry(destination: local('title/profile'), root: root,
        loadVerifiedBytes: () async => throw StateError('checksum mismatch')),
    ], isCurrentAccount: () => true), throwsStateError);
    expect(await local('title/main').readAsBytes(), [1]);
    expect(await local('title/profile').readAsBytes(), [2]);
    await expectNoStaging();
  });

  test('failed later commit rolls back original members and removes new members', () async {
    await write('title/main', [1]);
    await write('title/profile', [2]);
    await expectLater(NeoSyncRestoreTransaction.restore([
      entry('title/main', [9]),
      entry('title/new_member', [8]),
      entry('title/profile', [7]),
    ], isCurrentAccount: () => true, beforeCommit: (index, _) async {
      if (index == 2) throw const FileSystemException('simulated write failure');
    }), throwsA(isA<FileSystemException>()));
    expect(await local('title/main').readAsBytes(), [1]);
    expect(await local('title/profile').readAsBytes(), [2]);
    expect(await local('title/new_member').exists(), isFalse);
    await expectNoStaging();
  });

  test('account change during download aborts before any local replacement', () async {
    await write('game.state', [1]);
    var sameAccount = true;
    await expectLater(NeoSyncRestoreTransaction.restore([
      NeoSyncRestoreEntry(destination: local('game.state'), root: root,
        loadVerifiedBytes: () async {
          sameAccount = false;
          return [9];
        }),
    ], isCurrentAccount: () async => sameAccount), throwsStateError);
    expect(await local('game.state').readAsBytes(), [1]);
    await expectNoStaging();
  });

  test('account change between commits rolls back the entire native save', () async {
    await write('main', [1]);
    await write('profile', [2]);
    var sameAccount = true;
    await expectLater(NeoSyncRestoreTransaction.restore([
      entry('main', [9]), entry('profile', [8]),
    ], isCurrentAccount: () async => sameAccount,
      beforeCommit: (index, _) async {
        if (index == 1) sameAccount = false;
      }), throwsStateError);
    expect(await local('main').readAsBytes(), [1]);
    expect(await local('profile').readAsBytes(), [2]);
    await expectNoStaging();
  });

  test('local save changed during fetch is preserved even with same length and mtime', () async {
    final file = await write('main', [1, 2, 3]);
    final modified = await file.lastModified();
    await expectLater(NeoSyncRestoreTransaction.restore([
      NeoSyncRestoreEntry(destination: file, root: root,
        loadVerifiedBytes: () async {
          await file.writeAsBytes([4, 5, 6], flush: true);
          await file.setLastModified(modified);
          return [7, 8, 9];
        }),
    ], isCurrentAccount: () => true), throwsStateError);
    expect(await file.readAsBytes(), [4, 5, 6]);
    await expectNoStaging();
  });

  test('new save created during fetch is preserved', () async {
    await expectLater(NeoSyncRestoreTransaction.restore([
      NeoSyncRestoreEntry(destination: local('new/main'), root: root,
        loadVerifiedBytes: () async {
          await write('new/main', [2]);
          return [9];
        }),
    ], isCurrentAccount: () => true), throwsStateError);
    expect(await local('new/main').readAsBytes(), [2]);
    await expectNoStaging();
  });

  test('staged corruption is caught and earlier replacements are rolled back', () async {
    await write('main', [1]);
    await write('profile', [2]);
    await expectLater(NeoSyncRestoreTransaction.restore([
      entry('main', [9]), entry('profile', [8]),
    ], isCurrentAccount: () => true, beforeCommit: (index, _) async {
      if (index != 1) return;
      final incoming = await root.list(recursive: true)
          .where((entity) => entity is File && p.basename(entity.path) == 'incoming')
          .cast<File>().toList();
      expect(incoming, hasLength(1));
      await incoming.single.writeAsBytes([6], flush: true);
    }), throwsStateError);
    expect(await local('main').readAsBytes(), [1]);
    expect(await local('profile').readAsBytes(), [2]);
    await expectNoStaging();
  });

  test('duplicate destinations are rejected before loading payloads', () async {
    var loaded = false;
    final duplicate = NeoSyncRestoreEntry(destination: local('main'), root: root,
      loadVerifiedBytes: () async { loaded = true; return [9]; });
    await expectLater(NeoSyncRestoreTransaction.restore([
      duplicate, duplicate,
    ], isCurrentAccount: () => true), throwsStateError);
    expect(loaded, isFalse);
    expect(await local('main').exists(), isFalse);
  });

  test('destination outside trusted root and parent traversal are rejected', () async {
    for (final path in [p.join(root.parent.path, 'outside'),
        p.join(root.path, 'nested', '..', 'main')]) {
      await expectLater(NeoSyncRestoreTransaction.restore([
        NeoSyncRestoreEntry(destination: File(path), root: root,
          loadVerifiedBytes: () async => [9]),
      ], isCurrentAccount: () => true), throwsStateError);
    }
    await expectNoStaging();
  });

  test('linked directory and linked member cannot redirect save writes', () async {
    final outside = await Directory.systemTemp.createTemp('neosync-outside-');
    try {
      final original = await File(p.join(outside.path, 'main')).writeAsBytes([1]);
      await Link(p.join(root.path, 'alias')).create(outside.path);
      await Link(p.join(root.path, 'linked-save')).create(original.path);
      for (final path in ['alias/main', 'linked-save']) {
        await expectLater(NeoSyncRestoreTransaction.restore([
          entry(path, [9]),
        ], isCurrentAccount: () => true), throwsStateError);
      }
      expect(await original.readAsBytes(), [1]);
      await expectNoStaging();
    } finally {
      await outside.delete(recursive: true);
    }
  }, skip: Platform.isWindows);

  test('trusted selected root alias works, preserving platform /var aliases', () async {
    final actual = await Directory(p.join(root.path, 'actual')).create();
    final alias = Link(p.join(root.path, 'selected'));
    await alias.create(actual.path);
    await NeoSyncRestoreTransaction.restore([
      NeoSyncRestoreEntry(destination: File(p.join(alias.path, 'main')),
        root: Directory(alias.path), loadVerifiedBytes: () async => [9]),
    ], isCurrentAccount: () => true);
    expect(await File(p.join(actual.path, 'main')).readAsBytes(), [9]);
    await expectNoStaging();
  }, skip: Platform.isWindows);

  test('failed rollback retains original backup and concurrent local edit', () async {
    await write('main', [1]);
    await write('profile', [2]);
    NeoSyncRestoreRecoveryRequired? failure;
    try {
      await NeoSyncRestoreTransaction.restore([
        entry('main', [9]), entry('profile', [8]),
      ], isCurrentAccount: () => true, beforeCommit: (index, _) async {
        if (index == 1) {
          await local('main').writeAsBytes([7], flush: true);
          throw StateError('second member failed after a concurrent save');
        }
      });
    } on NeoSyncRestoreRecoveryRequired catch (error) {
      failure = error;
    }
    expect(failure, isNotNull);
    expect(failure!.backupPaths, hasLength(1));
    expect(await File(failure.backupPaths.single).readAsBytes(), [1]);
    expect(await local('main').readAsBytes(), [7]);
    expect(await local('profile').readAsBytes(), [2]);
  });
}
