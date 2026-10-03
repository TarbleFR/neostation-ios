import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/neoplay_locale.dart';
import 'package:neostation/widgets/airplay_menu_button.dart';
import 'package:neostation/widgets/neoplay_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  var failDiscovery = false;
  setUp(() {
    calls.clear();
    failDiscovery = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('neostation/neoplay'),
      (call) async {
        calls.add(call.method);
        if (call.method == 'discover' && failDiscovery) {
          throw PlatformException(code: 'network');
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('neostation/neoplay/events'),
      (call) async => null,
    );
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('neostation/neoplay'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('neostation/neoplay/events'),
      null,
    );
  });
  testWidgets(
    'Main menu AirPlay icon opens receiver selection without discovery or capture',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(640, 480),
          builder: (context, child) =>
              const MaterialApp(home: Scaffold(body: AirPlayMenuButton())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.airplay_rounded), findsOneWidget);
      expect(
        find.byTooltip('AirPlay · Play on another screen'),
        findsOneWidget,
      );
      expect(calls, isEmpty);

      await tester.tap(find.byKey(const ValueKey('main-menu-airplay')));
      await tester.pumpAndSettle();
      expect(find.byType(NeoPlayDialog), findsOneWidget);
      expect(find.text('Find screens'), findsOneWidget);
      expect(find.textContaining('Windows requires'), findsOneWidget);
      expect(find.textContaining('Chromecast uses'), findsOneWidget);
      expect(
        find.byKey(const Key('neoplay-apple-tv-system-entry')),
        findsOneWidget,
      );
      expect(calls, isEmpty);

      await tester.ensureVisible(
        find.byKey(const Key('neoplay-apple-tv-system-entry')),
      );
      await tester.tap(find.byKey(const Key('neoplay-apple-tv-system-entry')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Connect the iPhone and Apple TV'),
        findsOneWidget,
      );
      expect(calls, isEmpty);
      await tester.tap(find.text('Close').last);
      await tester.pumpAndSettle();
      expect(find.byType(NeoPlayDialog), findsOneWidget);

      await tester.ensureVisible(find.text('Find screens'));
      await tester.tap(find.text('Find screens'));
      await tester.pumpAndSettle();
      expect(calls, ['discover']);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(calls, ['discover', 'stopDiscovery']);
      expect(find.byType(NeoPlayDialog), findsNothing);
      expect(find.byKey(const ValueKey('main-menu-airplay')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Main menu AirPlay label uses all twelve catalogues including Traditional Chinese',
    (tester) async {
      for (final entry in NeoPlayLocale.values.entries) {
        final locale = entry.key == 'zh_Hant'
            ? const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')
            : Locale(entry.key);
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: const Size(640, 480),
            builder: (context, child) => MaterialApp(
              home: Localizations(
                locale: locale,
                delegates: const [DefaultWidgetsLocalizations.delegate],
                child: const Scaffold(body: AirPlayMenuButton()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byTooltip('AirPlay · ${entry.value['subtitle']}'),
          findsOneWidget,
          reason: entry.key,
        );
        expect(calls, isEmpty);
        expect(tester.takeException(), isNull);
      }
    },
  );
  testWidgets(
    'No discovery or capture until requested; closing does not stop a game or stream',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showNeoPlayDialog(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Find screens'));
      await tester.tap(find.text('Find screens'));
      await tester.pumpAndSettle();
      expect(calls, ['discover']);
      expect(find.text('Search again'), findsOneWidget);
      await tester.ensureVisible(find.text('Search again'));
      await tester.tap(find.text('Search again'));
      await tester.pumpAndSettle();
      expect(calls, ['discover', 'discover']);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(calls, ['discover', 'discover', 'stopDiscovery']);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Settings round trip restarts only an explicitly requested search',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: NeoPlayDialog()));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.ensureVisible(find.text('Find screens'));
      await tester.tap(find.text('Find screens'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls, ['discover', 'discover']);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      expect(calls, ['discover', 'discover', 'stopDiscovery']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls, ['discover', 'discover', 'stopDiscovery']);
    },
  );
  testWidgets(
    'Failed search retains retry and clears the displayed error on a successful retry',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: NeoPlayDialog()));
      await tester.pumpAndSettle();
      failDiscovery = true;
      await tester.ensureVisible(find.text('Find screens'));
      await tester.tap(find.text('Find screens'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Check permissions'), findsOneWidget);
      expect(find.text('Search again'), findsOneWidget);
      failDiscovery = false;
      await tester.ensureVisible(find.text('Search again'));
      await tester.tap(find.text('Search again'));
      await tester.pumpAndSettle();
      expect(calls, ['discover', 'discover']);
      expect(find.textContaining('Check permissions'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
