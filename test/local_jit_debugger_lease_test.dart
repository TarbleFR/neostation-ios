import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/local_jit_debugger_lease.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neostation/stikjit');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const token = '00000000-0000-4000-8000-000000000001';
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'beginDebuggerLease'
          ? {'leased': true, 'managedByNeoStation': true, 'token': token}
          : {'released': true};
    });
  });

  tearDown(() async {
    try {
      await LocalJitDebuggerLease.release();
    } catch (_) {
      // The failure test deliberately rejects cleanup.
    }
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('owns the acknowledged lease until release completes', () async {
    expect(LocalJitDebuggerLease.active, isFalse);
    await LocalJitDebuggerLease.acquire();
    expect(LocalJitDebuggerLease.active, isTrue);
    await LocalJitDebuggerLease.release();
    expect(LocalJitDebuggerLease.active, isFalse);
    expect(calls.map((call) => call.method), ['beginDebuggerLease', 'endDebuggerLease']);
    expect(calls.last.arguments, {'token': token});
  });

  test('external VPN requires no provider lease or release', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'leased': false, 'managedByNeoStation': false};
    });
    await LocalJitDebuggerLease.acquire();
    expect(LocalJitDebuggerLease.active, isFalse);
    await LocalJitDebuggerLease.release();
    expect(calls.map((call) => call.method), ['beginDebuggerLease']);
  });

  test('refuses an unconfirmed integrated provider before attaching', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {'leased': true});
    await expectLater(LocalJitDebuggerLease.acquire(), throwsA(isA<PlatformException>()));
    expect(LocalJitDebuggerLease.active, isFalse);
  });

  test('failed acquisition never leaves a lifecycle reservation', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'local_tunnel_cancelled');
    });
    await expectLater(LocalJitDebuggerLease.acquire(), throwsA(isA<PlatformException>()));
    expect(LocalJitDebuggerLease.active, isFalse);
  });

  test('overlapping and duplicate acquisitions are refused', () async {
    final reply = Completer<Map<String, dynamic>>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'beginDebuggerLease') return reply.future;
      return {'released': true};
    });
    final pending = LocalJitDebuggerLease.acquire();
    expect(LocalJitDebuggerLease.active, isTrue);
    await expectLater(LocalJitDebuggerLease.acquire(), throwsStateError);
    reply.complete({'leased': true, 'managedByNeoStation': true, 'token': token});
    await pending;
    await expectLater(LocalJitDebuggerLease.acquire(), throwsStateError);
    expect(calls.where((call) => call.method == 'beginDebuggerLease').length, 1);
  });

  test('release failure clears the Dart reservation', () async {
    await LocalJitDebuggerLease.acquire();
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'local_tunnel_cancelled');
    });
    await expectLater(LocalJitDebuggerLease.release(), throwsA(isA<PlatformException>()));
    expect(LocalJitDebuggerLease.active, isFalse);
  });

  test('release keeps the reservation until native acknowledgement', () async {
    await LocalJitDebuggerLease.acquire();
    final reply = Completer<Map<String, dynamic>>();
    messenger.setMockMethodCallHandler(channel, (_) => reply.future);
    final pending = LocalJitDebuggerLease.release();
    expect(LocalJitDebuggerLease.active, isTrue);
    reply.complete({'released': true});
    await pending;
    expect(LocalJitDebuggerLease.active, isFalse);
  });
}
