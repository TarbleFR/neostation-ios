import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/services/dolphin_system_files.dart';

void main() {
  late Directory temp;
  late Directory source;
  late Directory target;
  Future<File> write(String relative, String data, {Directory? root}) async {
    final file = File(p.join((root ?? source).path, relative));
    await file.parent.create(recursive: true);
    return file.writeAsString(data);
  }
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dolphin-import-test');
    source = await Directory(p.join(temp.path, 'export', 'User', 'Wii')).create(recursive: true);
    target = await Directory(p.join(temp.path, 'private', 'User', 'Wii')).create(recursive: true);
    await write('title/00010000/game/data/save.bin', 'imported save');
    await write('shared2/sys/SYSCONF', 'system config');
  });
  tearDown(() async => temp.delete(recursive: true));

  test('imports the complete extracted Wii tree from a parent and backs up old saves', () async {
    for (final name in DolphinSystemFiles.wiiFiles) {
      await write(name, 'fixture $name');
    }
    for (final name in DolphinSystemFiles.wiiDirectories) {
      await Directory(p.join(source.path, name)).create(recursive: true);
    }
    await write('title/old/data/save.bin', 'old save', root: target);
    final count = await DolphinSystemFiles.importWiiFolder(source.parent.parent, target);
    expect(count, 7);
    expect(await File(p.join(target.path, 'keys.bin')).readAsString(), 'fixture keys.bin');
    expect(await File(p.join(target.path, 'title/00010000/game/data/save.bin')).readAsString(), 'imported save');
    expect(await File('${target.path}.previous/title/old/data/save.bin').readAsString(), 'old save');
    expect(await File(p.join(source.path, 'shared2/sys/SYSCONF')).exists(), isTrue);
    expect(await Directory(p.join(target.path, 'wfs')).exists(), isTrue);
  });

  test('rejects raw NAND or unrelated folder without changing the live NAND', () async {
    await write('title/save', 'keep', root: target);
    final wrong = await Directory(p.join(temp.path, 'raw')).create();
    await File(p.join(wrong.path, 'nand.bin')).writeAsString('raw fixture');
    await expectLater(DolphinSystemFiles.importWiiFolder(wrong, target), throwsA(isA<DolphinSystemFilesException>()));
    expect(await File(p.join(target.path, 'title/save')).readAsString(), 'keep');
  });

  test('symlinks in a NAND are rejected and rollback leaves saves intact', () async {
    await write('title/save', 'keep', root: target);
    await Link(p.join(source.path, 'title', 'escape')).create(temp.path);
    await expectLater(DolphinSystemFiles.importWiiFolder(source, target), throwsA(isA<DolphinSystemFilesException>()));
    expect(await File(p.join(target.path, 'title/save')).readAsString(), 'keep');
    expect(await Directory('${target.path}.incoming').exists(), isFalse);
  });

  test('copy failure keeps the old tree and removes the unfinished snapshot', () async {
    await write('title/save', 'keep', root: target);
    await expectLater(DolphinSystemFiles.replaceSnapshot(target, (stage) async {
      await File(p.join(stage.path, 'partial')).writeAsString('partial');
      throw const FileSystemException('disk full');
    }), throwsA(isA<FileSystemException>()));
    expect(await File(p.join(target.path, 'title/save')).readAsString(), 'keep');
    expect(await Directory('${target.path}.incoming').exists(), isFalse);
  });

  test('startup restores backup after interruption between directory renames', () async {
    await write('title/save', 'keep', root: target);
    await target.rename('${target.path}.previous');
    await Directory('${target.path}.incoming').create();
    await DolphinSystemFiles.recover(target);
    expect(await File(p.join(target.path, 'title/save')).readAsString(), 'keep');
    expect(await Directory('${target.path}.incoming').exists(), isFalse);
  });

  test('individual system files preserve saves and reject arbitrary binaries', () async {
    await write('title/save', 'keep', root: target);
    final keys = await write('keys.bin', 'keys fixture');
    expect(await DolphinSystemFiles.importWiiFiles([keys], target), 1);
    expect(await File(p.join(target.path, 'title/save')).readAsString(), 'keep');
    final wrong = await write('IPL.bin', 'not Wii');
    await expectLater(DolphinSystemFiles.importWiiFiles([wrong], target), throwsA(isA<DolphinSystemFilesException>()));
    expect(await File(p.join(target.path, 'keys.bin')).readAsString(), 'keys fixture');
  });

  test('cannot import the live NAND into itself', () async {
    await expectLater(DolphinSystemFiles.importWiiFolder(source, source), throwsA(isA<DolphinSystemFilesException>()));
    expect(await File(p.join(source.path, 'shared2/sys/SYSCONF')).exists(), isTrue);
  });

  Future<File> writeTmd(int titleId, {int iosId = 0}) async {
    final bytes = Uint8List(0x1e4 + 36);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, 0x10001, Endian.big);
    data.setUint64(0x184, iosId, Endian.big);
    data.setUint64(0x18c, titleId, Endian.big);
    data.setUint16(0x1de, 1, Endian.big);
    data.setUint32(0x1e4, 1, Endian.big);
    final id = titleId.toRadixString(16).padLeft(16, '0');
    final file = File(p.join(target.path, 'title', id.substring(0, 8),
        id.substring(8), 'content', 'title.tmd'));
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes);
  }

  test('Wii Menu preflight requires menu metadata but accepts HLE IOS', () async {
    await write('keys.bin', 'keys only', root: target);
    await expectLater(DolphinSystemFiles.requireWiiMenuMetadata(target),
        throwsA(isA<DolphinSystemFilesException>().having((e) => e.code, 'code', 'wiiMenuMissing')));
    await writeTmd(0x0000000100000002, iosId: 0x0000000100000050);
    await DolphinSystemFiles.requireWiiMenuMetadata(target);
  });

  test('Wii Menu metadata rejects a wrong title, truncated records and missing boot entry', () async {
    await writeTmd(0x0000000100000050);
    for (final change in <void Function(ByteData)>[
      (data) => data.setUint64(0x18c, 0x0001000141424344, Endian.big),
      (data) => data.setUint16(0x1de, 512, Endian.big),
      (data) => data.setUint16(0x1e0, 99, Endian.big),
      (data) => data.setUint64(0x184, 0x0000000100000002, Endian.big),
    ]) {
      final menu = await writeTmd(0x0000000100000002, iosId: 0x0000000100000050);
      final bytes = await menu.readAsBytes();
      change(ByteData.sublistView(bytes));
      await menu.writeAsBytes(bytes);
      await expectLater(DolphinSystemFiles.requireWiiMenuMetadata(target),
          throwsA(isA<DolphinSystemFilesException>()));
    }
  });

  test('Wii Menu metadata rejects symlinked title content', () async {
    await writeTmd(0x0000000100000050);
    final menu = await writeTmd(0x0000000100000002, iosId: 0x0000000100000050);
    final original = menu.parent.path;
    await menu.parent.rename('$original-outside');
    await Link(original).create('$original-outside');
    await expectLater(DolphinSystemFiles.requireWiiMenuMetadata(target),
        throwsA(isA<DolphinSystemFilesException>()));
  });
}
