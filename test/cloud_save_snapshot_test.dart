import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/cloud_saves/save_snapshot.dart';
import 'package:neostation/services/cloud_saves/save_source_registry.dart';
import 'package:neostation/services/cloud_saves/save_revision.dart';

void main() {
  late Directory temp;
  setUp(() async { temp = await Directory.systemTemp.createTemp('cloud-snapshot-'); });
  tearDown(() async { await temp.delete(recursive: true); });
  test('complete native directory survives roundtrip with bytes and mtime', () async {
    final source = await Directory('${temp.path}/source').create();
    await Directory('${source.path}/empty').create();
    await Directory('${source.path}/nested').create();
    final file = await File('${source.path}/nested/SYSDATA').writeAsBytes([1,2,3,4]);
    final date = DateTime.utc(2025,1,10);
    await file.setLastModified(date);
    final payload = File('${temp.path}/save.nssave');
    final snapshot = await SaveSnapshot.create(source.path, payload, 'profile/title');
    expect(snapshot.modified, date);
    final unpacked = await SaveSnapshot.unpack(payload, Directory('${temp.path}/unpack'),
      unitKey: 'profile/title', payloadHash: snapshot.payloadHash, contentHash: snapshot.contentHash);
    expect(unpacked.directory, isTrue);
    expect(await File('${unpacked.path}/nested/SYSDATA').readAsBytes(), [1,2,3,4]);
    expect((await File('${unpacked.path}/nested/SYSDATA').stat()).modified.toUtc(), date);
    expect(await Directory('${unpacked.path}/empty').exists(), isTrue);
  });
  test('touching unchanged bytes does not manufacture changed save content', () async {
    final file = await File('${temp.path}/card.ps2').writeAsString('native');
    await file.setLastModified(DateTime.utc(2025));
    final first = await SaveSnapshot.create(file.path, File('${temp.path}/a'), 'PS2/A');
    await file.setLastModified(DateTime.utc(2026));
    final next = await SaveSnapshot.create(file.path, File('${temp.path}/b'), 'PS2/A');
    expect(next.contentHash, first.contentHash);
    expect(next.payloadHash, isNot(first.payloadHash));
  });
  test('snapshot rejects symbolic links without exposing another directory', () async {
    final source = await Directory('${temp.path}/source').create();
    await File('${temp.path}/secret').writeAsString('private');
    await Link('${source.path}/link').create('${temp.path}/secret');
    await expectLater(SaveSnapshot.create(source.path, File('${temp.path}/out'), 'unit'), throwsFormatException);
  });
  test('restore rejects tampered bytes and mismatched native owner', () async {
    final file = await File('${temp.path}/native').writeAsString('native');
    final snapshot = await SaveSnapshot.create(file.path, File('${temp.path}/out'), 'owner-A');
    await expectLater(SaveSnapshot.unpack(snapshot.file, Directory('${temp.path}/wrong'), unitKey: 'owner-B',
      payloadHash: snapshot.payloadHash, contentHash: snapshot.contentHash), throwsFormatException);
    await snapshot.file.writeAsBytes([0], mode: FileMode.append);
    await expectLater(SaveSnapshot.unpack(snapshot.file, Directory('${temp.path}/corrupt'), unitKey: 'owner-A',
      payloadHash: snapshot.payloadHash, contentHash: snapshot.contentHash), throwsFormatException);
    expect(await Directory('${temp.path}/corrupt').exists(), isFalse);
  });
  test('untrusted relative names never escape the cloud or staging root', () {
    for (final path in ['', '/abs', '../save', 'a/../b', 'a//b', 'a\\b', 'a:b', 'a\u0000b']) {
      expect(() => SaveSnapshot.safeRelative(path), throwsFormatException, reason: path);
    }
  });
  test('two identical memory cards still have separate revision identities', () async {
    final file = await File('${temp.path}/native').writeAsString('native');
    final snapshot = await SaveSnapshot.create(file.path, File('${temp.path}/out'), 'A');
    SaveRevision revision(String key) => NativeSaveUnit(key: key, emulator: 'ARMSX2', system: 'PlayStation 2',
      owner: 'Shared', title: 'Card', kind: 'MemoryCards', source: file.path).revision(snapshot);
    final a = revision('A'), b = revision('B');
    expect(a.storageKey, isNot(b.storageKey));
    expect(a.relativeDirectory, isNot(b.relativeDirectory));
    expect(SaveRevision.fromJson(jsonDecode(jsonEncode(a.toJson()))).id, a.id);
    final bad = a.toJson()..['directory'] = '../Other';
    expect(() => SaveRevision.fromJson(bad), throwsFormatException);
  });
}
