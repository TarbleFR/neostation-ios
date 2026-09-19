import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/local_jit_tunnel_service.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neostation/stikjit');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    LocalJitTunnelService.debugOverrideIOS(null);
    messenger.setMockMethodCallHandler(channel, null);
  });

  Map<String, Object?> route({required bool managed}) => {
    'active': true,
    'status': managed ? 'connected' : 'externalRoute',
    'managedByNeoStation': managed,
    'configured': managed,
    'authorized': managed,
    'enabled': true,
    'interfaceAddress': managed ? '10.7.1.1' : null,
    'peerAddress': '10.7.0.1',
    'onDemand': false,
    'routeVerified': true,
  };

  test('connected status without route proof cannot pass an emulator preflight', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {
      'active': true, 'status': 'connected', 'managedByNeoStation': true,
    });
    await expectLater(
      StikjitBridge.ensureJitRoute(),
      throwsA(isA<PlatformException>().having(
        (error) => error.code, 'code', 'local_tunnel_jit_route_unavailable',
      )),
    );
    expect((await StikjitBridge.localTunnelStatus()).active, isTrue);
    expect((await StikjitBridge.localTunnelStatus()).routeVerified, isFalse);
  });

  test('verified external route remains a successful preflight', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {
      'active': true, 'status': 'externalRoute', 'managedByNeoStation': false,
      'routeVerified': true,
    });
    final result = await StikjitBridge.ensureJitRoute();
    expect(result.routeVerified, isTrue);
    expect(result.managedByNeoStation, isFalse);
  });

  test('route proof without a live route is not a success', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {
      'active': false, 'routeVerified': true,
    });
    await expectLater(StikjitBridge.ensureJitRoute(), throwsA(isA<PlatformException>()));
  });

  test('live LocalDevVPN route bypasses a pending internal activation', () async {
    LocalJitTunnelService.debugOverrideIOS(true);
    final activation = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'activateOwnedTunnel') return activation.future;
      if (call.method == 'ensureLocalTunnel') return route(managed: false);
      throw PlatformException(code: 'unexpected_method');
    });

    final enable = LocalJitTunnelService.authorizeAndEnable();
    await Future<void>.delayed(Duration.zero);
    final preflight = await LocalJitTunnelService.ensureRunningForJit()
        .timeout(const Duration(milliseconds: 200));

    expect(preflight.managedByNeoStation, isFalse);
    activation.complete(route(managed: true));
    await enable;
  });

  test('failed route waits for pending internal activation then probes again', () async {
    LocalJitTunnelService.debugOverrideIOS(true);
    final activation = Completer<Object?>();
    var probes = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'activateOwnedTunnel') return activation.future;
      if (call.method == 'ensureLocalTunnel') {
        probes++;
        if (probes == 1) {
          throw PlatformException(code: 'local_tunnel_jit_route_unavailable');
        }
        return route(managed: true);
      }
      throw PlatformException(code: 'unexpected_method');
    });

    final enable = LocalJitTunnelService.authorizeAndEnable();
    final preflight = LocalJitTunnelService.ensureRunningForJit();
    var completed = false;
    unawaited(preflight.whenComplete(() => completed = true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(completed, isFalse);
    expect(probes, 1);

    activation.complete(route(managed: true));
    await enable;
    expect((await preflight).managedByNeoStation, isTrue);
    expect(probes, 2);
  });
}
