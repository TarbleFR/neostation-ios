import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/rpcs3_internal_service.dart';
import 'package:neostation/services/rpcs3_launch_service.dart';

Future<void> _noControl() async {}

void main() {
  test(
    'warm boot returns as soon as native launch succeeds with no stage',
    () async {
      final launch = Completer<bool>();
      final firstRead = Completer<void>();
      var reads = 0;
      var aborts = 0;
      var stops = 0;
      final watchdog = Rpcs3BootWatchdog(
        pollInterval: const Duration(minutes: 1),
      );

      final guarded = watchdog.guard<bool>(
        launchFuture: launch.future,
        readProgress: () async {
          reads++;
          if (!firstRead.isCompleted) firstRead.complete();
          return <String, dynamic>{
            'success': true,
            'stage': '',
            'current': 0,
            'total': 0,
          };
        },
        abortBoot: () async {
          aborts++;
        },
        stop: () async {
          stops++;
        },
        logProgress: (_, _, _) {},
      );

      await firstRead.future;
      final released = Stopwatch()..start();
      launch.complete(true);

      expect(await guarded.timeout(const Duration(seconds: 2)), isTrue);
      expect(released.elapsed, lessThan(const Duration(seconds: 2)));
      expect(reads, 1);
      expect(aborts, 0);
      expect(stops, 0);
    },
  );

  test('successful boot ignores a residual non-empty progress stage', () async {
    final launch = Completer<bool>();
    final firstRead = Completer<void>();
    final stages = <String>[];
    var aborts = 0;
    var stops = 0;
    final watchdog = Rpcs3BootWatchdog(
      pollInterval: const Duration(minutes: 1),
    );

    final guarded = watchdog.guard<bool>(
      launchFuture: launch.future,
      readProgress: () async {
        if (!firstRead.isCompleted) firstRead.complete();
        return <String, dynamic>{
          'success': true,
          'stage': 'Linking PPU Modules...',
          'current': 65,
          'total': 65,
        };
      },
      abortBoot: () async {
        aborts++;
      },
      stop: () async {
        stops++;
      },
      logProgress: (stage, _, _) => stages.add(stage),
    );

    await firstRead.future;
    launch.complete(true);

    expect(await guarded.timeout(const Duration(seconds: 2)), isTrue);
    expect(aborts, 0);
    expect(stops, 0);
    expect(stages.length, lessThanOrEqualTo(1));
  });

  test('native launch errors are released and rethrown unchanged', () async {
    final launch = Completer<bool>();
    final firstRead = Completer<void>();
    final expected = StateError('native boot failed');
    final watchdog = Rpcs3BootWatchdog(
      pollInterval: const Duration(minutes: 1),
    );

    final guarded = watchdog.guard<bool>(
      launchFuture: launch.future,
      readProgress: () async {
        if (!firstRead.isCompleted) firstRead.complete();
        return <String, dynamic>{'success': true, 'stage': ''};
      },
      abortBoot: _noControl,
      stop: _noControl,
      logProgress: (_, _, _) {},
    );

    await firstRead.future;
    launch.completeError(expected, StackTrace.current);

    await expectLater(
      guarded.timeout(const Duration(seconds: 2)),
      throwsA(same(expected)),
    );
  });

  test(
    'a real PPU stall still aborts and reports the existing error',
    () async {
      final launch = Completer<bool>();
      var instant = DateTime.utc(2026, 9, 19);
      var aborts = 0;
      var stops = 0;
      final watchdog = Rpcs3BootWatchdog(
        pollInterval: Duration.zero,
        ppuNoProgressLimit: const Duration(milliseconds: 1),
        ppuApplyNoProgressLimit: const Duration(milliseconds: 1),
        finishedStageLimit: const Duration(milliseconds: 1),
        recoveryStopTimeout: Duration.zero,
        clock: () {
          final value = instant;
          instant = instant.add(const Duration(seconds: 1));
          return value;
        },
      );

      final guarded = watchdog.guard<bool>(
        launchFuture: launch.future,
        readProgress: () async => <String, dynamic>{
          'success': true,
          'stage': 'Compiling PPU Modules',
          'current': 4,
          'total': 65,
        },
        abortBoot: () async {
          aborts++;
        },
        stop: () async {
          stops++;
        },
        logProgress: (_, _, _) {},
      );

      await expectLater(
        guarded,
        throwsA(
          isA<Rpcs3InternalException>().having(
            (error) => error.code,
            'code',
            'ppuBootPreparationStalled',
          ),
        ),
      );
      expect(aborts, 1);
      expect(stops, 1);
    },
  );
}
