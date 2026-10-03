import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_swap/neo_swap.dart';
import 'package:neostation/l10n/neoswap_locale.dart';
import 'package:neostation/screens/settings_screen/neoswap_dialog.dart';

void main() {
  test(
    'all twelve descriptions distinguish cache and owned-source budgets',
    () {
      expect(NeoSwapLocale.values.length, 12);
      for (final locale in NeoSwapLocale.values.entries) {
        final text = locale.value['storageDescription']!;
        for (final token in ['8', '12', '128', 'GLSL']) {
          expect(text, contains(token), reason: locale.key);
        }
      }
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('neostation/neo_swap');
  Map<String, dynamic> sample(bool enabled) => {
    'result': 0,
    'configResult': 0,
    'capacityBytes': 8192 * 1024 * 1024,
    'owners': <dynamic>[],
    'shaderStorage': {
      'requestedEnabled': enabled,
      'active': false,
      'appliesOnNextLaunch': true,
      'cache': {
        'rawRamBytes': 1048576,
        'compressedCacheRamBytes': 524288,
        'storedPayloadBytes': 4194304,
        'diskOnlyLogicalBytes': 3145728,
        'readP95Us': 2500,
      },
      'sourceArchive': {
        'videoPixelLiveArchivedBytes': 33554432,
        'videoPixelReturnedArchiveBytesCumulative': 16777216,
      },
    },
  };
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'storage preference sends a real boolean and preserves the native result',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return sample((call.arguments as Map)['enabled'] == true);
      });
      expect((await NeoSwap.setShaderStorage(true))['result'], 0);
      expect(
        (await NeoSwap.setShaderStorage(
          false,
        ))['shaderStorage']['requestedEnabled'],
        false,
      );
      expect(calls.map((c) => c.method), [
        'setShaderStorage',
        'setShaderStorage',
      ]);
      expect(calls.map((c) => c.arguments), [
        {'enabled': true},
        {'enabled': false},
      ]);
    },
  );
  testWidgets(
    'opt-in is visible, persisted, and explicitly applies to the next launch',
    (tester) async {
      bool enabled = false;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'setShaderStorage')
          enabled = (call.arguments as Map)['enabled'] == true;
        return sample(enabled);
      });
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: NeoSwapDialog())),
      );
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('neoSwapShaderStorage'));
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(enabled, true);
      expect(tester.widget<SwitchListTile>(toggle).value, true);
      expect(calls.where((c) => c.method == 'setShaderStorage').length, 1);
      expect(
        find.text(NeoSwapLocale.values['en']!['storageApplied']!),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('neoSwapShaderStorageMetrics')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('neoSwapVideoStorageMetrics')),
        findsOneWidget,
      );
      expect(find.textContaining('2.50'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'a pending preference response can finish after the dialog closes',
    (tester) async {
      final done = Completer<Map<String, dynamic>>();
      messenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'setShaderStorage' ? done.future : sample(false),
      );
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: NeoSwapDialog())),
      );
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('neoSwapShaderStorage'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      done.complete(sample(true));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    },
  );
}
