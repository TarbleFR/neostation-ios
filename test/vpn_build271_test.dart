import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stikjit_bridge/stikjit_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neostation/stikjit');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  testWidgets('a missing status callback cannot keep the UI future pending', (tester) async {
    final blocked = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (_) => blocked.future);
    final result = StikjitBridge.localTunnelStatus();
    final assertion = expectLater(result, throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'local_tunnel_connection_timeout')));
    await tester.pump(const Duration(seconds: 7));
    await assertion;
    blocked.complete({'active': true});
    await tester.pump();
  });
  testWidgets('OFF remains independent of an unresolved ON channel reply', (tester) async {
    final blocked = Completer<Object?>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'activateOwnedTunnel') return blocked.future;
      return {'active': false, 'status': 'disconnected', 'managedByNeoStation': true};
    });
    final on = StikjitBridge.activateOwnedTunnel();
    final timeout = expectLater(on, throwsA(isA<PlatformException>()));
    final off = StikjitBridge.disableLocalTunnel();
    await tester.pump();
    expect((await off).active, isFalse);
    expect(calls, ['activateOwnedTunnel', 'disableLocalTunnel']);
    await tester.pump(const Duration(seconds: 36));
    await timeout;
    blocked.complete({'active': false});
    await tester.pump();
  });
}
