import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_swap/neo_swap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(NeoSwap.channel, (call) async {
      calls.add(call);
      return {'result': 0, 'capacityMiB': 8192, 'owners': <Object>[]};
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(NeoSwap.channel, null));
  test('diagnostics use the automatically initialized runtime without activation', () async {
    await NeoSwap.snapshot();
    await NeoSwap.probe();
    expect(calls.map((c) => c.method), ['snapshot', 'probe']);
  });
  test('capacity exercise is explicit and bounded independently from automatic budget', () async {
    await NeoSwap.capacityProbe(8192);
    expect(calls.single.method, 'capacityProbe');
    expect(calls.single.arguments, {'sizeMiB': 8192});
    expect(() => NeoSwap.capacityProbe(8193), throwsArgumentError);
    expect(calls.length, 1);
  });
  test('compatibility methods use implemented diagnostic channels', () async {
    await NeoSwap.getMemoryStats();
    await NeoSwap.allocateMaxMemory(8192);
    expect(calls.map((c) => c.method), ['snapshot', 'capacityProbe']);
    expect(calls.last.arguments, {'sizeMiB': 8192});
    expect(() => NeoSwap.allocateMaxMemory(8193), throwsArgumentError);
    expect(calls.length, 2);
  });
  test('a missing native response fails explicitly', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NeoSwap.channel, (call) async => null);
    await expectLater(NeoSwap.getMemoryStats(), throwsStateError);
  });
}
