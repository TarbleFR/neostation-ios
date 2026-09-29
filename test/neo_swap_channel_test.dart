import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_swap/neo_swap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NeoSwap.channel, (call) async {
          calls.add(call);
          return {'result': 0, 'capacityMiB': 512, 'owners': <Object>[]};
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NeoSwap.channel, null),
  );
  test('bounded configuration reaches the native broker', () async {
    await NeoSwap.configure(512);
    expect(calls.single.method, 'configure');
    expect(calls.single.arguments, {'capacityMiB': 512});
    expect(() => NeoSwap.configure(999999), throwsArgumentError);
    expect(calls.length, 1);
  });
  test('probe and snapshot are separate from game allocations', () async {
    await NeoSwap.probe();
    await NeoSwap.snapshot();
    expect(calls.map((c) => c.method), ['probe', 'snapshot']);
  });
  test('8 GiB budget and capacity exercise use separate explicit commands', () async {
    await NeoSwap.configure(8192);
    await NeoSwap.capacityProbe(8192);
    expect(calls[0].arguments, {'capacityMiB': 8192});
    expect(calls[1].method, 'capacityProbe');
    expect(calls[1].arguments, {'sizeMiB': 8192});
    expect(() => NeoSwap.configure(8193), throwsArgumentError);
    expect(() => NeoSwap.capacityProbe(8193), throwsArgumentError);
    expect(calls.length, 2);
  });
}
