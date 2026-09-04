import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/dolphin_embedded_service.dart';

void main() {
  group('DolphinEmbeddedService', () {
    test('recognizes only the native GameCube and Wii playlist folders', () {
      expect(DolphinEmbeddedService.isDolphinSystemFolder('gc'), isTrue);
      expect(DolphinEmbeddedService.isDolphinSystemFolder('WII'), isTrue);
      expect(DolphinEmbeddedService.isDolphinSystemFolder('ps2'), isFalse);
      expect(DolphinEmbeddedService.isDolphinSystemFolder('dolphinios'), isFalse);
    });

    test('rejects an IPL with the wrong size', () {
      final result = DolphinEmbeddedService.validateIpl(
        Uint8List(1024),
        DolphinIplRegion.usa,
      );
      expect(result.accepted, isFalse);
      expect(result.message, contains('2 MiB'));
    });

    test('does not trust an IPL filename/header without a known retail CRC', () {
      final bytes = Uint8List(2 * 1024 * 1024);
      final header = '(C) 1999-2001 Nintendo.  All rights reserved.'
          '(C) 1999 ArtX Inc.  All rights reserved.'
          .codeUnits;
      bytes.setRange(0, header.length, header);
      for (var index = 0x100; index < bytes.length; index += 4096) {
        bytes[index] = (index ~/ 4096) & 0xff;
      }

      final result = DolphinEmbeddedService.validateIpl(
        bytes,
        DolphinIplRegion.usa,
      );
      expect(result.accepted, isFalse);
      expect(result.message, contains('Unknown or damaged'));
    });
  });
}
