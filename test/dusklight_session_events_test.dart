import 'dart:async';

import 'package:dusklight_internal_bridge/dusklight_internal_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neostation/dusklight_internal');
  const codec = StandardMethodCodec();
  var transaction = 0;
  var nativeLaunchCount = 0;

  Future<void> nativeEnd({
    int? oldTransaction,
    bool runtimeReleased = false,
    bool restartRequired = false,
  }) async {
    final delivered = Completer<void>();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall('sessionEnded', {
        'reason': runtimeReleased ? 'fatal-stop' : 'closed',
        'restartRequired': restartRequired,
        'runtimeReleased': runtimeReleased,
        'transaction': oldTransaction ?? transaction,
      })),
      (_) => delivered.complete(),
    );
    await delivered.future;
  }

  test('warm return can relaunch without losing transaction ownership', () async {
    final firstFrame = Completer<Map<String, dynamic>>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      if (call.method == 'launch') {
        nativeLaunchCount++;
        transaction = (call.arguments as Map)['transaction'] as int;
        return firstFrame.future;
      }
      return Future.value(true);
    });

    var resolved = false;
    final launch = DusklightInternalBridge.launch(
      gamePath: '/ports/twilight.rvz',
      supportPath: '/ports',
      cachePath: '/cache',
    ).then((value) {
      resolved = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(resolved, isFalse);

    final duplicate = await DusklightInternalBridge.launch(
      gamePath: '/ports/twilight.rvz',
      supportPath: '/ports',
      cachePath: '/cache',
    );
    expect(duplicate['errorCode'], 'DUSKLIGHT_SESSION_ACTIVE');
    expect(nativeLaunchCount, 1);

    firstFrame.complete({'success': true, 'stage': 'first_frame'});
    expect((await launch)['stage'], 'first_frame');

    final whilePlaying = await DusklightInternalBridge.launch(
      gamePath: '/ports/twilight.rvz',
      supportPath: '/ports',
      cachePath: '/cache',
    );
    expect(whilePlaying['errorCode'], 'DUSKLIGHT_SESSION_ACTIVE');
    expect(nativeLaunchCount, 1);

    // Normal return keeps the native runtime. NeoStation may immediately
    // reserve a new logical session for the same retained engine.
    final ended = DusklightInternalBridge.sessionEvents.first;
    await nativeEnd();
    expect((await ended)['runtimeReleased'], isFalse);
    expect(DusklightInternalBridge.didEndSession, isTrue);
    expect(DusklightInternalBridge.didReleaseRuntime, isFalse);
    final previousTransaction = transaction;

    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      transaction = (call.arguments as Map)['transaction'] as int;
      nativeLaunchCount++;
      return {'success': true, 'stage': 'first_frame'};
    });
    final retry = await DusklightInternalBridge.launch(
      gamePath: '/ports/twilight.rvz',
      supportPath: '/ports',
      cachePath: '/cache',
    );
    expect(retry['success'], isTrue);
    expect(nativeLaunchCount, 2);
    expect(DusklightInternalBridge.didEndSession, isFalse);
    expect(DusklightInternalBridge.didReleaseRuntime, isFalse);

    await nativeEnd(oldTransaction: previousTransaction);
    expect(
      DusklightInternalBridge.didEndSession,
      isFalse,
      reason: 'A late native closure must not terminate a newer launch.',
    );
    await nativeEnd();

    for (var repeat = 0; repeat < 10; repeat++) {
      final resumed = await DusklightInternalBridge.launch(
        gamePath: '/ports/twilight.rvz',
        supportPath: '/ports',
        cachePath: '/cache',
        uiText: const {'nativeMenu': 'Menu et réglages Dusklight'},
      );
      expect(resumed['success'], isTrue);
      expect(DusklightInternalBridge.didEndSession, isFalse);
      await nativeEnd();
      expect(DusklightInternalBridge.didEndSession, isTrue);
      expect(DusklightInternalBridge.didReleaseRuntime, isFalse);
    }

    // A timed-out presentation still owns the runtime until its frame-boundary
    // return arrives. It must not permit a concurrent resume.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      transaction = (call.arguments as Map)['transaction'] as int;
      return {'success': false, 'errorCode': 'DUSKLIGHT_FIRST_FRAME_TIMEOUT'};
    });
    final timeout = await DusklightInternalBridge.launch(
      gamePath: '/ports/twilight.rvz',
      supportPath: '/ports',
      cachePath: '/cache',
    );
    expect(timeout['errorCode'], 'DUSKLIGHT_FIRST_FRAME_TIMEOUT');
    final duringReturn = await DusklightInternalBridge.launch(
      gamePath: '/ports/twilight.rvz',
      supportPath: '/ports',
      cachePath: '/cache',
    );
    expect(duringReturn['errorCode'], 'DUSKLIGHT_SESSION_ACTIVE');
    await nativeEnd();

    // A fatal event is distinguishable from an ordinary warm return.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      transaction = (call.arguments as Map)['transaction'] as int;
      return {'success': true, 'stage': 'first_frame'};
    });
    expect((await DusklightInternalBridge.launch(
      gamePath: '/ports/twilight.rvz',
      supportPath: '/ports',
      cachePath: '/cache',
    ))['success'], isTrue);
    await nativeEnd(runtimeReleased: true, restartRequired: true);
    expect(DusklightInternalBridge.didEndSession, isTrue);
    expect(DusklightInternalBridge.didReleaseRuntime, isTrue);

    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });
}
