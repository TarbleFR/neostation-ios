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
  Map<String, dynamic> sample({int capacity = 0, int result = 0}) => {
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
  testWidgets(
    'shows off, does not allocate on open, and retains capacity on busy refusal',
    (tester) async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return sample(result: call.method == 'configure' ? -7 : 0);
      });
      await open(tester);
      expect(calls, ['snapshot']);
      expect(find.text(NeoSwapLocale.values['en']!['scope']!), findsOneWidget);
      final dropdown = tester.widget<DropdownButton<int>>(
        find.byType(DropdownButton<int>),
      );
      expect(dropdown.value, 0);
      dropdown.onChanged!(512);
      await tester.pumpAndSettle();
      expect(calls, ['snapshot', 'configure']);
      expect(find.text(NeoSwapLocale.values['en']!['busy']!), findsOneWidget);
      expect(
        tester
            .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
            .value,
        0,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
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
  testWidgets(
    'failed restored configuration is visible and never shown as an active budget',
    (tester) async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          ...sample(capacity: 512),
          'capacityBytes': 0,
          'configResult': -4,
        },
      );
      await open(tester);
      expect(
        tester
            .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
            .value,
        0,
      );
      expect(find.text(NeoSwapLocale.values['en']!['failed']!), findsOneWidget);
      expect(find.text('NeoSwap result: -4'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'old periodic snapshot cannot revert a successfully changed budget',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      var snapshots = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'configure') return sample(capacity: 1024);
        snapshots++;
        return snapshots == 1 ? sample(capacity: 512) : pending.future;
      });
      await open(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(snapshots, 2);
      tester
          .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
          .onChanged!(1024);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
            .value,
        1024,
      );
      pending.complete(sample(capacity: 512));
      await tester.pump();
      expect(
        tester
            .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
            .value,
        1024,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
}
