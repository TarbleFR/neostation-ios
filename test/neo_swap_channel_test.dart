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
}
