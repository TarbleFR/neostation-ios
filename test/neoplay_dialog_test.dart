import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/widgets/neoplay_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  setUp(() {
    calls.clear();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('neostation/neoplay'), (call) async { calls.add(call.method); return null; });
    messenger.setMockMethodCallHandler(const MethodChannel('neostation/neoplay/events'), (call) async => null);
  });
  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('neostation/neoplay'), null);
    messenger.setMockMethodCallHandler(const MethodChannel('neostation/neoplay/events'), null);
  });
  testWidgets('No discovery or capture until requested; closing does not stop a game or stream', (tester) async {
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(onPressed: () => showNeoPlayDialog(context), child: const Text('Open'))))));
    await tester.tap(find.text('Open')); await tester.pumpAndSettle();
    expect(calls, isEmpty); expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Find screens'));
    await tester.tap(find.text('Find screens')); await tester.pumpAndSettle();
    expect(calls, ['discover']);
    await tester.tap(find.text('Close')); await tester.pumpAndSettle();
    expect(calls, ['discover', 'stopDiscovery']);
    expect(tester.takeException(), isNull);
  });
}
