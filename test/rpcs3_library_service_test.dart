import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/rpcs3_library_service.dart';
import 'package:neostation/services/rpcs3_title_catalog_service.dart';
import 'package:path/path.dart' as path;

void main() {
  group('Rpcs3LibraryService', () {
    test('parses PARAM.SFO string and integer entries', () {
      final bytes = _buildSfo(<String, Object>{
        'TITLE_ID': 'BLUS12345',
        'TITLE': 'NeoStation Test Game',
        'CATEGORY': 'DG',
        'APP_VER': '01.02',
        'RESOLUTION': 12,
      });

      final parsed = Rpcs3LibraryService.parseParamSfoBytes(bytes);
      expect(parsed['TITLE_ID'], 'BLUS12345');
      expect(parsed['TITLE'], 'NeoStation Test Game');
      expect(parsed['CATEGORY'], 'DG');
      expect(parsed['APP_VER'], '01.02');
      expect(parsed['RESOLUTION'], 12);
    });

    test('parses RPCS3 games.yml scalar mapping', () {
      final parsed = Rpcs3LibraryService.parseGamesYmlTextForTesting(r'''
---
"BLUS12345": "/private/var/mobile/Game One.iso"
NPUB00001: '$(EmulatorDir)games/DiscImages/Game Two.iso'
# ignored
...
''');

      expect(parsed['BLUS12345'], '/private/var/mobile/Game One.iso');
      expect(
        parsed['NPUB00001'],
        r'$(EmulatorDir)games/DiscImages/Game Two.iso',
      );
    });

    test('normalizes either RPCS3 root or Data folder', () async {
      final temp = await Directory.systemTemp.createTemp('rpcs3-root-test');
      addTearDown(() => temp.delete(recursive: true));
      final data = Directory(path.join(temp.path, 'Data'));
      await data.create();

      expect(
        await Rpcs3LibraryService.normalizeDataRootForTesting(temp.path),
        path.normalize(data.path),
      );
      expect(
        await Rpcs3LibraryService.normalizeDataRootForTesting(data.path),
        path.normalize(data.path),
      );
    });

    test('uses physical folders and ignores cross-linked games.yml history', () async {
      final temp = await Directory.systemTemp.createTemp('rpcs3-library-test');
      addTearDown(() => temp.delete(recursive: true));
      final dataRoot = Directory(path.join(temp.path, 'Data'));
      await dataRoot.create(recursive: true);

      final hddGame = Directory(
        path.join(dataRoot.path, 'dev_hdd0', 'game', 'NPUB12345'),
      );
      await hddGame.create(recursive: true);
      await File(path.join(hddGame.path, 'PARAM.SFO')).writeAsBytes(
        _buildSfo(<String, Object>{
          'TITLE_ID': 'NPUB12345',
          'TITLE': 'Installed HDD Game',
          'CATEGORY': 'HG',
          'APP_VER': '01.00',
        }),
      );

      final extractedMetadata = Directory(
        path.join(
          dataRoot.path,
          'games',
          'ExtractedGames',
          'Disc Folder',
          'PS3_GAME',
        ),
      );
      await extractedMetadata.create(recursive: true);
      await File(path.join(extractedMetadata.path, 'PARAM.SFO')).writeAsBytes(
        _buildSfo(<String, Object>{
          'TITLE_ID': 'BLES54321',
          'TITLE': 'Extracted Disc Game',
          'CATEGORY': 'DG',
          'APP_VER': '01.01',
        }),
      );

      final realDiscMetadata = Directory(
        path.join(dataRoot.path, 'games', 'discImgs', 'BLES00540', 'PS3_GAME'),
      );
      await realDiscMetadata.create(recursive: true);
      await File(path.join(realDiscMetadata.path, 'PARAM.SFO')).writeAsBytes(
        _buildSfo(<String, Object>{
          'TITLE_ID': 'BLES00540',
          'TITLE': 'Dynasty Warriors 6 Empires',
          'CATEGORY': 'DG',
          'APP_VER': '01.00',
        }),
      );
      await File(path.join(realDiscMetadata.parent.path, 'disc.iso'))
          .writeAsBytes(const <int>[]);

      final fallbackFolder = Directory(
        path.join(dataRoot.path, 'games', 'discImgs', 'BLES77777'),
      );
      await fallbackFolder.create(recursive: true);

      // Historical corruption observed on-device: deleted BLES01484 points to
      // the still-existing BLES00540 ISO. The physical folder must win and the
      // stale ID must never be recreated.
      await File(path.join(dataRoot.path, 'games.yml')).writeAsString(
        'BLES01484: "${path.join(realDiscMetadata.parent.path, 'disc.iso')}"\n',
      );

      final games = await Rpcs3LibraryService.discoverLibrary(dataRoot.path);
      final byId = <String, Rpcs3LibraryGame>{
        for (final game in games) game.titleId: game,
      };

      expect(
        byId.keys,
        containsAll(<String>[
          'NPUB12345',
          'BLES54321',
          'BLES00540',
          'BLES77777',
        ]),
      );
      expect(byId.containsKey('BLES01484'), isFalse);
      expect(byId['BLES00540']!.title, 'Dynasty Warriors 6 Empires');
      expect(byId['BLES77777']!.sourceKind, 'disc-image-folder');
    });

    test('ignores stale games.yml registrations whose target is gone', () async {
      final temp = await Directory.systemTemp.createTemp('rpcs3-stale-yml');
      addTearDown(() => temp.delete(recursive: true));
      final dataRoot = Directory(path.join(temp.path, 'Data'));
      await dataRoot.create(recursive: true);
      await File(path.join(dataRoot.path, 'games.yml')).writeAsString(
        'BLES01484: "${path.join(dataRoot.path, 'games', 'DiscImages', 'deleted.iso')}"\n',
      );

      final games = await Rpcs3LibraryService.discoverLibrary(dataRoot.path);
      expect(games.where((game) => game.titleId == 'BLES01484'), isEmpty);
    });

    test('normalizes GameDB serial keys and applies fallback titles', () async {
      final catalog = Rpcs3TitleCatalogService.parseCatalogForTesting(
        '{"BLES-00412":"The Lord of the Rings: Conquest"}',
      );
      expect(catalog['BLES00412'], 'The Lord of the Rings: Conquest');

      final enriched = await Rpcs3LibraryService.applyTitleCatalogForTesting(
        const <Rpcs3LibraryGame>[
          Rpcs3LibraryGame(
            titleId: 'BLES00412',
            title: 'BLES00412',
            version: '',
            category: '',
            sourcePath: '/tmp/game.iso',
            sourceKind: 'games.yml',
          ),
        ],
        catalog,
      );
      expect(enriched.single.title, 'The Lord of the Rings: Conquest');
    });
  });
}

Uint8List _buildSfo(Map<String, Object> values) {
  final keys = BytesBuilder(copy: false);
  final data = BytesBuilder(copy: false);
  final entries = <_SfoEntry>[];

  for (final item in values.entries) {
    final keyOffset = keys.length;
    keys.add(utf8.encode(item.key));
    keys.addByte(0);

    while (data.length % 4 != 0) {
      data.addByte(0);
    }
    final dataOffset = data.length;

    if (item.value is int) {
      final valueBytes = Uint8List(4);
      ByteData.sublistView(valueBytes)
          .setUint32(0, item.value as int, Endian.little);
      data.add(valueBytes);
      entries.add(
        _SfoEntry(
          keyOffset: keyOffset,
          format: 0x0404,
          length: 4,
          maxLength: 4,
          dataOffset: dataOffset,
        ),
      );
    } else {
      final valueBytes = <int>[...utf8.encode(item.value.toString()), 0];
      data.add(valueBytes);
      entries.add(
        _SfoEntry(
          keyOffset: keyOffset,
          format: 0x0204,
          length: valueBytes.length,
          maxLength: valueBytes.length,
          dataOffset: dataOffset,
        ),
      );
    }
  }

  final keyBytes = keys.takeBytes();
  final dataBytes = data.takeBytes();
  final keyTableOffset = 20 + entries.length * 16;
  final dataTableOffset = _align4(keyTableOffset + keyBytes.length);
  final output = Uint8List(dataTableOffset + dataBytes.length);
  final view = ByteData.sublistView(output);

  output.setAll(0, const <int>[0x00, 0x50, 0x53, 0x46]);
  view.setUint32(4, 0x00000101, Endian.little);
  view.setUint32(8, keyTableOffset, Endian.little);
  view.setUint32(12, dataTableOffset, Endian.little);
  view.setUint32(16, entries.length, Endian.little);

  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    final offset = 20 + index * 16;
    view.setUint16(offset, entry.keyOffset, Endian.little);
    view.setUint16(offset + 2, entry.format, Endian.little);
    view.setUint32(offset + 4, entry.length, Endian.little);
    view.setUint32(offset + 8, entry.maxLength, Endian.little);
    view.setUint32(offset + 12, entry.dataOffset, Endian.little);
  }

  output.setAll(keyTableOffset, keyBytes);
  output.setAll(dataTableOffset, dataBytes);
  return output;
}

int _align4(int value) => (value + 3) & ~3;

class _SfoEntry {
  const _SfoEntry({
    required this.keyOffset,
    required this.format,
    required this.length,
    required this.maxLength,
    required this.dataOffset,
  });

  final int keyOffset;
  final int format;
  final int length;
  final int maxLength;
  final int dataOffset;
}
