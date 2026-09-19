import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/local_dev_vpn_route_service.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neostation/stikjit');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<String, Object?> route({
    bool reachable = true,
    String host = LocalDevVpnRouteState.expectedHost,
    int port = LocalDevVpnRouteState.expectedPort,
    String state = 'ready',
    String networkState = 'ready',
    int elapsedMs = 14,
    String? errorCode,
    String? errorDescription,
  }) => <String, Object?>{
    'reachable': reachable,
    'host': host,
    'port': port,
    'elapsedMs': elapsedMs,
    'state': state,
    'networkState': networkState,
    'errorCode': ?errorCode,
    'errorDescription': ?errorDescription,
  };

  tearDown(() {
    LocalDevVpnRouteService.debugOverrideIOS(null);
    LocalDevVpnRouteService.debugOverrideTimeout(null);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('probe accepts only the fixed reachable LocalDevVPN endpoint', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return route(elapsedMs: 23);
    });

    final result = await StikjitBridge.probeLocalDevVpnRoute();

    expect(calls, ['probeLocalDevVpnRoute']);
    expect(result.reachable, isTrue);
    expect(result.host, '10.7.0.1');
    expect(result.port, 49152);
    expect(result.elapsedMs, 23);
    expect(result.state, 'ready');
  });

  test('failed TCP proof preserves native diagnostics', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => route(
        reachable: false,
        state: 'timeout',
        networkState: 'waiting',
        elapsedMs: 1250,
        errorCode: 'timeout',
        errorDescription: 'Timed out waiting for LocalDevVPN.',
      ),
    );

    await expectLater(
      StikjitBridge.probeLocalDevVpnRoute(),
      throwsA(
        isA<PlatformException>()
            .having(
              (error) => error.code,
              'code',
              'localdevvpn_route_unavailable',
            )
            .having(
              (error) => (error.details as Map<Object?, Object?>)['elapsedMs'],
              'elapsedMs',
              1250,
            )
            .having(
              (error) =>
                  (error.details as Map<Object?, Object?>)['networkState'],
              'networkState',
              'waiting',
            ),
      ),
    );
  });

  test('reachable response for a different endpoint is rejected', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => route(host: '127.0.0.1'),
    );

    await expectLater(
      StikjitBridge.probeLocalDevVpnRoute(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'localdevvpn_route_unavailable',
        ),
      ),
    );
  });

  test('service coalesces concurrent route probes', () async {
    LocalDevVpnRouteService.debugOverrideIOS(true);
    final nativeResult = Completer<Object?>();
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) {
      calls++;
      return nativeResult.future;
    });

    final first = LocalDevVpnRouteService.ensureReachable();
    final second = LocalDevVpnRouteService.ensureReachable();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);

    nativeResult.complete(route());
    final results = await Future.wait([first, second]);
    expect(results, everyElement(isA<LocalDevVpnRouteState>()));
    expect(calls, 1);
  });

  test('service clears a failed in-flight probe before retrying', () async {
    LocalDevVpnRouteService.debugOverrideIOS(true);
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      if (calls == 1) {
        return route(
          reachable: false,
          state: 'failed',
          networkState: 'failed',
          errorCode: '61',
          errorDescription: 'Connection refused.',
        );
      }
      return route();
    });

    await expectLater(
      LocalDevVpnRouteService.ensureReachable(),
      throwsA(
        isA<LocalDevVpnRouteException>().having(
          (error) => error.code,
          'code',
          'localdevvpn_route_unavailable',
        ),
      ),
    );
    expect((await LocalDevVpnRouteService.ensureReachable()).reachable, isTrue);
    expect(calls, 2);
  });

  test('service wraps an invalid native response with diagnostics', () async {
    LocalDevVpnRouteService.debugOverrideIOS(true);
    messenger.setMockMethodCallHandler(channel, (_) async => 'invalid');

    await expectLater(
      LocalDevVpnRouteService.ensureReachable(),
      throwsA(
        isA<LocalDevVpnRouteException>()
            .having(
              (error) => error.code,
              'code',
              'localdevvpn_route_invalid_response',
            )
            .having((error) => error.details, 'details', isA<StateError>()),
      ),
    );
  });

  test('timeout releases coalescing before a late native result', () async {
    LocalDevVpnRouteService.debugOverrideIOS(true);
    LocalDevVpnRouteService.debugOverrideTimeout(
      const Duration(milliseconds: 20),
    );
    final lateNativeResult = Completer<Object?>();
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) {
      calls++;
      if (calls == 1) return lateNativeResult.future;
      return Future<Object?>.value(route());
    });

    await expectLater(
      LocalDevVpnRouteService.ensureReachable(),
      throwsA(
        isA<LocalDevVpnRouteException>().having(
          (error) => error.code,
          'code',
          'localdevvpn_route_probe_timeout',
        ),
      ),
    );

    expect((await LocalDevVpnRouteService.ensureReachable()).reachable, isTrue);
    expect(calls, 2);

    lateNativeResult.complete(route(reachable: false, state: 'timeout'));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
  });
}
