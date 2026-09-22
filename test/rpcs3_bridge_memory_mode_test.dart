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
  test('native bridge has no Build 302 host reservation layer', () {
    final bridge = File(
      'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
    ).readAsStringSync();
    final abi = File(
      'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h',
    ).readAsStringSync();

    for (final retired in [
      'Rpcs3ArenaReservation',
      'reserveAddressSpace',
      'adopt_jit_layout',
      'reset_failed_startup',
      'RPCS3_VA_NOT_RESERVED',
      'RPCS3_VA_OWNERSHIP_CHANGED',
    ]) {
      expect(bridge, isNot(contains(retired)));
      expect(abi, isNot(contains(retired)));
    }
  });

}
