import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';

class _DownloadedSave implements NeoSyncService {
  final List<int> bytes;
  _DownloadedSave(this.bytes);

  @override
  Future<Map<String, dynamic>> downloadFile(String fileId) async =>
      {'success': true, 'data': bytes};

  @override
  String calculateFileHash(List<int> bytes) => md5.convert(bytes).toString();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected transfer operation');
}

void main() {
  const key = 'v2/saves/ps2/armsx2/shared/memcards/card.ps2.neosync.gz';
  final original = List<int>.generate(8192, (index) => index % 251);
  final compressed = gzip.encode(original);

  NeoSyncFile metadata({String name = '', int? size, String? hash}) =>
      NeoSyncFile.fromJson({
        'id': 'card-1', 'file_name': name, 'file_path': '/account/$key',
        'file_size': size ?? compressed.length,
        'file_hash': hash ?? md5.convert(compressed).toString(),
      });

  test('recovered compressed card exports its original emulator bytes', () async {
    final provider = NeoSyncProvider(_DownloadedSave(compressed));
    addTearDown(provider.dispose);
    for (final name in ['', 'card.ps2.neosync.gz', key]) {
      expect(await provider.downloadOnlineFileBytes(metadata(name: name)), original);
    }
  });

  test('corrupt or incomplete cloud bytes never reach native restore/export', () async {
    final provider = NeoSyncProvider(_DownloadedSave(compressed));
    addTearDown(provider.dispose);
    await expectLater(provider.downloadOnlineFileBytes(metadata(hash: '0' * 32)),
        throwsStateError);
    await expectLater(provider.downloadOnlineFileBytes(metadata(size: compressed.length + 1)),
        throwsStateError);
  });
}
