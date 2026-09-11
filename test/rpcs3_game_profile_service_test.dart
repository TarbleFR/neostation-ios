import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/rpcs3_game_profile_service.dart';

void main() {
  group('RPCS3 serial configuration profiles', () {
    test(
      'normalizes recognized RPCS3 serial families without using titles',
      () {
        for (final serial in <String>[
          'BLUS30110',
          'BLES00215',
          'BCUS98114',
          'BCES00001',
          'NPUB12345',
          'NPEB12345',
          'ABCD12345678',
        ]) {
          expect(Rpcs3GameProfileService.normalizeSerial(serial), serial);
        }
        expect(
          Rpcs3GameProfileService.normalizeSerial('bles00215'),
          'BLES00215',
        );
        expect(
          Rpcs3GameProfileService.normalizeSerial('Dynasty Warriors 6'),
          isNull,
        );
        expect(Rpcs3GameProfileService.normalizeSerial('../BLES00215'), isNull);
        expect(Rpcs3GameProfileService.normalizeSerial('BLES-00215'), isNull);
      },
    );

    test(
      'isolates the PPU interpreter fallback to Dynasty Warriors 6 serials',
      () {
        final eu = Rpcs3GameProfileService.profileForSerial('BLES00215')!;
        final us = Rpcs3GameProfileService.profileForSerial('BLUS30110')!;
        final other = Rpcs3GameProfileService.profileForSerial('BLES00412')!;

        expect(eu.settings['cpu.ppu_decoder'], 'Interpreter (static)');
        expect(us.settings['cpu.ppu_decoder'], 'Interpreter (static)');
        expect(other.settings, isNot(contains('cpu.ppu_decoder')));
        expect(other.settings['cpu.spu_block_size'], 'Safe');
      },
    );

    test('emits partial RPCS3 YAML keyed only by serial', () {
      final payload = Rpcs3GameProfileService.databasePayloadForSerials(
        <String>['BLES00215', 'Dynasty Warriors 6', 'BLES00412'],
      );
      final root = jsonDecode(payload) as Map<String, dynamic>;
      final games = root['games'] as Map<String, dynamic>;

      expect(root['return_code'], 0);
      expect(games.keys, containsAll(<String>['BLES00215', 'BLES00412']));
      expect(games, isNot(contains('Dynasty Warriors 6')));
      final bles = games['BLES00215'] as Map<String, dynamic>;
      final yaml = bles['config'] as String;
      expect(yaml, contains('Core:'));
      expect(yaml, contains('PPU Decoder: Interpreter (static)'));
      expect(yaml, contains('SPU Block Size: Safe'));
      expect(yaml, contains('iOS Experimental:'));
      expect(yaml, isNot(contains('Video:')));
      expect(yaml, isNot(contains('Audio:')));
    });

    test(
      'launch path no longer mutates global or complete custom settings',
      () {
        final launcher = File('lib/services/rpcs3_launch_service.dart')
            .readAsStringSync();
        expect(launcher, contains('Rpcs3GameProfileService.applyForLaunch'));
        expect(launcher, isNot(contains('Rpcs3InternalBridge.setSetting(')));
        expect(
          launcher,
          isNot(contains('Rpcs3InternalBridge.setGameSetting(')),
        );
      },
    );
  });
}
