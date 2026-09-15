import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neostation/stikjit');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

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
}
