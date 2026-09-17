import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/local_jit_session_coordinator.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neostation/stikjit');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  LocalJitTunnelState state(String status, {bool active = false, bool owned = true, bool enabled = true}) =>
      LocalJitTunnelState.fromMap({
        'status': status, 'active': active, 'enabled': enabled,
        'managedByNeoStation': owned, 'configured': true, 'authorized': true,
      });

  test('enabled configuration is not a running VPN; retry must be ON', () {
    expect(state('disconnected').canStopOwnedTunnel, isFalse);
    expect(state('notConfigured').canStopOwnedTunnel, isFalse);
    expect(state('disconnecting').canStopOwnedTunnel, isFalse);
  });

  test('only a connected or starting OWN provider permits OFF', () {
    expect(state('connected', active: true).canStopOwnedTunnel, isTrue);
    expect(state('connecting').canStopOwnedTunnel, isTrue);
    expect(state('reasserting').canStopOwnedTunnel, isTrue);
    expect(state('externalRoute', active: true, owned: false).canStopOwnedTunnel, isFalse);
  });

  test('manual ON uses its own native command and requires owned route proof', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return {'active': true, 'managedByNeoStation': true, 'routeVerified': true};
    });
    expect((await StikjitBridge.activateOwnedTunnel()).active, isTrue);
    expect(calls, ['activateOwnedTunnel']);
  });

  test('manual ON rejects an external success that automatic launch can use', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {
      'active': true, 'managedByNeoStation': false, 'routeVerified': true,
    });
    await expectLater(StikjitBridge.activateOwnedTunnel(), throwsA(isA<PlatformException>()));
    expect((await StikjitBridge.ensureJitRoute()).active, isTrue);
  });

  test('connected without route proof does not complete manual ON', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {
      'active': true, 'managedByNeoStation': true, 'routeVerified': false,
    });
    await expectLater(StikjitBridge.activateOwnedTunnel(), throwsA(isA<PlatformException>()));
  });

  test('native error details survive a subsequent status read', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {
      'active': false, 'enabled': false, 'managedByNeoStation': true,
      'lastErrorCode': 'local_tunnel_start_failed',
      'lastErrorDetail': 'ProviderLaunch(77); observed=disconnected',
    });
    final status = await StikjitBridge.localTunnelStatus();
    expect(status.lastErrorCode, 'local_tunnel_start_failed');
    expect(status.lastErrorDetail, contains('ProviderLaunch(77)'));
    expect(status.canStopOwnedTunnel, isFalse);
  });

  test('manual override waits for the same cold reset, never becoming automatic', () async {
    final reset = Completer<String>();
    final calls = <String>[];
    final coordinator = LocalJitSessionCoordinator<String>(
      ensureRoute: () async { calls.add('automatic'); return 'external'; },
      stopTunnel: () { calls.add('cold-reset'); return reset.future; },
      onResetError: (_) {},
    );
    final automatic = coordinator.ensure();
    final manual = coordinator.ensure(routeOverride: () async { calls.add('owned'); return 'owned'; });
    expect(calls, ['cold-reset']);
    reset.complete('off');
    expect(await automatic, 'external');
    expect(await manual, 'owned');
    expect(calls, ['cold-reset', 'automatic', 'owned']);
  });

  test('OFF also cancels a manual override waiting behind cold reset', () async {
    final reset = Completer<String>();
    var resets = 0;
    var ownedStarts = 0;
    final coordinator = LocalJitSessionCoordinator<String>(
      ensureRoute: () async => 'automatic',
      stopTunnel: () => ++resets == 1 ? reset.future : Future.value('off'),
      onResetError: (_) {},
    );
    final pending = coordinator.ensure(routeOverride: () async { ownedStarts++; return 'owned'; });
    final rejected = expectLater(pending, throwsA(isA<LocalJitSessionCancelled>()));
    await coordinator.stop();
    reset.complete('off');
    await rejected;
    expect(ownedStarts, 0);
  });
}
