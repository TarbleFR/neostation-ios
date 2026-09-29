import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/neoswap_locale.dart';
import 'package:neostation/screens/settings_screen/neoswap_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neostation/neo_swap');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Map<String, dynamic> sample({int capacity = 8192, int result = 0}) => {
    'capacityMiB': capacity,
    'capacityBytes': capacity * 1024 * 1024,
    'configResult': 0,
    'result': result,
    'allocatedDiskBytes': 0,
    'processFootprintBytes': 65536,
    'diagnosticPath': '/Documents/Diagnostics/NeoSwap-v1.jsonl',
    'owners': [
      {
        'owner': 'rpcs3',
        'registered': true,
        'liveBytes': 0,
        'peakBytes': 0,
        'allocationCount': 0,
      },
    ],
  };
  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: NeoSwapDialog())),
    );
    await tester.pumpAndSettle();
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });
  testWidgets('capacity exercise blocks dismissal, preserves its result on polling and clears a rejected retry', (tester) async {
    final pending = Completer<Map<String, dynamic>>();
    var attempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'capacityProbe') return sample(capacity: 8192);
      return ++attempts == 1 ? pending.future : sample(capacity: 8192, result: -7);
    });
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => showDialog<void>(context: context, builder: (_) => const NeoSwapDialog()), child: const Text('open')),
    ))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final button = find.widgetWithText(OutlinedButton, NeoSwapLocale.values['en']!['capacityRun']!);
    tester.widget<OutlinedButton>(button).onPressed!();
    await tester.pump();
    await Navigator.of(tester.element(find.byType(NeoSwapDialog))).maybePop();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NeoSwapDialog), findsOneWidget);
    pending.complete({...sample(capacity: 8192), 'capacityProbe': {
      'requestedBytes': 64 * 1024 * 1024, 'dataVerified': true, 'result': 0,
      'samples': [{'processFootprintBytes': 65536}, {'processFootprintBytes': 131072}],
    }});
    await tester.pumpAndSettle();
    final result = NeoSwapLocale.get(tester.element(find.byType(NeoSwapDialog)), 'capacityResult', {'size': '64.0 MiB', 'delta': '0.1 MiB'});
    expect(find.text(result), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text(result), findsOneWidget);
    tester.widget<OutlinedButton>(button).onPressed!();
    await tester.pumpAndSettle();
    expect(find.text(result), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, NeoSwapLocale.values['en']!['close']!));
    await tester.pumpAndSettle();
    expect(find.byType(NeoSwapDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('automatic runtime budget is read-only and opening diagnostics sends no activation command', (tester) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return sample();
    });
    await open(tester);
    expect(calls, ['snapshot']);
    expect(find.text(NeoSwapLocale.values['en']!['scope']!), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('neoSwapBudget'))).data, '8192 MiB');
    expect(find.byType(DropdownButton<int>), findsOneWidget);
    expect(find.byKey(const ValueKey('neoSwapProbeSize')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('late snapshot after close never updates disposed state', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    messenger.setMockMethodCallHandler(channel, (_) => pending.future);
    await tester.pumpWidget(const MaterialApp(home: NeoSwapDialog()));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete(sample());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets('probe is explicit and distinct from game allocation counters', (
    tester,
  ) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return sample(capacity: 512);
    });
    await open(tester);
    await tester.tap(
      find.widgetWithText(
        OutlinedButton,
        NeoSwapLocale.values['en']!['probe']!,
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, ['snapshot', 'probe']);
    expect(find.text(NeoSwapLocale.values['en']!['pass']!), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('failed automatic startup is visible and never shows an active budget', (tester) async {
    messenger.setMockMethodCallHandler(channel, (_) async => {...sample(), 'capacityBytes': 0, 'configResult': -4});
    await open(tester);
    expect(tester.widget<Text>(find.byKey(const ValueKey('neoSwapBudget'))).data, '0 MiB');
    expect(find.text(NeoSwapLocale.values['en']!['failed']!), findsOneWidget);
    expect(find.text('NeoSwap result: -4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('late periodic snapshot cannot overwrite the newer diagnostic result', (tester) async {
    final pending = Completer<Map<String, dynamic>>();
    var snapshots = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'probe') return sample();
      return ++snapshots == 1 ? sample() : pending.future;
    });
    await open(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(snapshots, 2);
    tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, NeoSwapLocale.values['en']!['probe']!)).onPressed!();
    await tester.pumpAndSettle();
    pending.complete(sample(capacity: 0));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('neoSwapBudget'))).data, '8192 MiB');
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
