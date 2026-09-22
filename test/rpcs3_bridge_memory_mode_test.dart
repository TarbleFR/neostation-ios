import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rpcs3_internal_bridge/rpcs3_internal_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neostation/rpcs3_internal');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return <String, dynamic>{'success': true};
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'standard default and explicit expanded mode reach the native Core',
    () async {
      await Rpcs3InternalBridge.initialize(
        supportPath: '/support',
        cachePath: '/cache',
      );
      await Rpcs3InternalBridge.initialize(
        supportPath: '/support',
        cachePath: '/cache',
        expandedJitRegion: true,
      );
      expect(calls.map((call) => call.method), ['initialize', 'initialize']);
      expect(calls[0].arguments['expandedJitRegion'], isFalse);
      expect(calls[1].arguments['expandedJitRegion'], isTrue);
    },
  );

  test('host bridge exposes no fixed VA reservation call', () {
    final source = File(
      'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('reserveAddressSpace')));
  });
}
