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
        expect(other.settings, isEmpty);
      },
    );

    test(
      'targets only the registered God of War III serials',
      () {
        for (final serial in <String>['BCUS98111', 'BCES00510', 'BCAS25003']) {
          final profile = Rpcs3GameProfileService.profileForSerial(serial)!;
          expect(profile.settings['cpu.spu_block_size'], 'Mega');
          expect(profile.settings['cpu.preferred_spu_threads'], '0');
          expect(profile.settings['gpu.resolution_scale'], '75');
          expect(profile.settings['gpu.multithreaded_rsx'], 'true');
          expect(
            profile.settings['experimental.fps_optimization_batch'],
            'Enabled',
          );
          expect(profile.settings['cpu.ppu_decoder'], 'Recompiler (LLVM)');
          expect(profile.settings['cpu.spu_decoder'], 'Recompiler (LLVM)');
          expect(profile.settings['cpu.ppu_profiler'], 'false');
        }
        for (final serial in <String>['BCUS98114', 'BLES00412', 'NPUB12345']) {
          expect(
            Rpcs3GameProfileService.profileForSerial(serial)!.settings,
            isEmpty,
          );
        }
      },
    );

    test('returns independent profile maps between games and launches', () {
      final first = Rpcs3GameProfileService.profileForSerial('BCES00510')!;
      first.settings['cpu.preferred_spu_threads'] = '6';
      expect(
        Rpcs3GameProfileService.profileForSerial('BCES00510')!
            .settings['cpu.preferred_spu_threads'],
        '0',
      );
      expect(
        Rpcs3GameProfileService.profileForSerial('BCUS98111')!
            .settings['cpu.preferred_spu_threads'],
        '0',
      );
    });

    test('emits partial RPCS3 YAML keyed only by serial', () {
      final payload = Rpcs3GameProfileService.databasePayloadForSerials(
        <String>['BLES00215', 'Dynasty Warriors 6', 'BLES00412'],
      );
      final root = jsonDecode(payload) as Map<String, dynamic>;
      final games = root['games'] as Map<String, dynamic>;

      expect(root['return_code'], 0);
      expect(games.keys, contains('BLES00215'));
      expect(games, isNot(contains('BLES00412')));
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

    test('never publishes empty inherited-global entries', () {
      final mixedPayload = Rpcs3GameProfileService.databasePayloadForSerials(
        <String>['BLES00215', 'BLES00412', 'BCUS98114'],
      );
      final mixedGames =
          (jsonDecode(mixedPayload) as Map<String, dynamic>)['games']
              as Map<String, dynamic>;

      expect(mixedGames.keys, orderedEquals(<String>['BLES00215']));
      for (final entry in mixedGames.values) {
        final config = (entry as Map<String, dynamic>)['config'];
        expect(config, isA<String>());
        expect(config, isNotEmpty);
      }

      final inheritedPayload =
          Rpcs3GameProfileService.databasePayloadForSerials(
            <String>['BLES00412', 'BCUS98114'],
          );
      final inheritedGames =
          (jsonDecode(inheritedPayload) as Map<String, dynamic>)['games']
              as Map<String, dynamic>;
      expect(inheritedGames, isEmpty);
    });

    test('emits the God of War III performance keys as partial YAML', () {
      final payload = Rpcs3GameProfileService.databasePayloadForSerials(
        <String>['BCES00510'],
      );
      final games =
          (jsonDecode(payload) as Map<String, dynamic>)['games']
              as Map<String, dynamic>;
      final yaml =
          (games['BCES00510'] as Map<String, dynamic>)['config'] as String;

      expect(yaml, contains('Core:'));
      expect(yaml, contains('SPU Block Size: Mega'));
      expect(yaml, contains('Preferred SPU Threads: 0'));
      expect(yaml, contains('PPU Decoder: Recompiler (LLVM)'));
      expect(yaml, contains('SPU Decoder: Recompiler (LLVM)'));
      expect(yaml, contains('PPU Profiler: false'));
      expect(yaml, contains('Video:'));
      expect(yaml, contains('Resolution Scale: 75'));
      expect(yaml, contains('Multithreaded RSX: true'));
      expect(
        yaml,
        contains('  Vulkan:\n    Asynchronous Texture Streaming: true'),
      );
      expect(yaml, contains('FPS Optimization Batch: Enabled'));
      expect(yaml, isNot(contains('Audio:')));
    });

    test(
      'launch path no longer mutates global or complete custom settings',
      () {
        final launcher = File(
          'lib/services/rpcs3_launch_service.dart',
        ).readAsStringSync();
        expect(launcher, contains('Rpcs3GameProfileService.applyForLaunch'));
        expect(launcher, isNot(contains('Rpcs3InternalBridge.setSetting(')));
        expect(
          launcher,
          isNot(contains('Rpcs3InternalBridge.setGameSetting(')),
        );
      },
    );

    test('launch bypasses the native database for inherited-global serials', () {
      final source = File(
        'lib/services/rpcs3_game_profile_service.dart',
      ).readAsStringSync();
      final launchBody = source.substring(
        source.indexOf('static Future<Map<String, dynamic>> applyForLaunch'),
      );

      expect(launchBody, contains('if (profile.settings.isEmpty)'));
      expect(launchBody, contains("'success': true"));
      expect(
        launchBody.indexOf('if (profile.settings.isEmpty)'),
        lessThan(
          launchBody.indexOf('_detectedProfiles[profile.serial] = profile'),
        ),
      );
    });
  });
}
