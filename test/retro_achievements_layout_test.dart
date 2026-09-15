import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/screens/retro_achievements_screen/ra_content.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Localization reads the saved locale before the widget tree is mounted.
    // Widget tests have no native SharedPreferences implementation.
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );

    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/gamepads'), null);
  });

  Future<void> pumpDisconnectedRA(
    WidgetTester tester,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1920, 1080),
        builder: (context, child) => ChangeNotifierProvider(
          create: (_) => RetroAchievementsProvider(),
          child: MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: const Scaffold(body: RAContent()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final cases = <String, ({Size size, bool stacked})>{
    'compact iPhone landscape': (
      size: const Size(667, 375),
      stacked: true,
    ),
    'iPhone Pro Max landscape': (
      size: const Size(932, 430),
      stacked: false,
    ),
    'iPad landscape': (
      size: const Size(1194, 834),
      stacked: false,
    ),
  };

  for (final entry in cases.entries) {
    testWidgets(
      'RetroAchievements login is contained on ${entry.key}',
      (tester) async {
        final size = entry.value.size;
        await pumpDisconnectedRA(tester, size);

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('ra-login-scroll')), findsOneWidget);
        expect(find.byKey(const ValueKey('ra-connection-card')), findsOneWidget);
        expect(find.byKey(const ValueKey('ra-info-card')), findsOneWidget);
        expect(find.byType(Scrollbar), findsNothing);

        final scrollViews = tester.widgetList<SingleChildScrollView>(
          find.byType(SingleChildScrollView),
        );
        expect(scrollViews, isNotEmpty);
        for (final scrollView in scrollViews) {
          expect(scrollView.scrollDirection, Axis.vertical);
        }

        if (entry.value.stacked) {
          expect(find.byKey(const ValueKey('ra-stacked-layout')), findsOneWidget);
          expect(find.byKey(const ValueKey('ra-two-column-layout')), findsNothing);
        } else {
          expect(find.byKey(const ValueKey('ra-two-column-layout')), findsOneWidget);
          expect(find.byKey(const ValueKey('ra-stacked-layout')), findsNothing);
        }

        final infoRect = tester.getRect(
          find.byKey(const ValueKey('ra-info-card')),
        );
        final connectionRect = tester.getRect(
          find.byKey(const ValueKey('ra-connection-card')),
        );
        expect(infoRect.left, greaterThanOrEqualTo(-0.5));
        expect(infoRect.right, lessThanOrEqualTo(size.width + 0.5));
        expect(connectionRect.left, greaterThanOrEqualTo(-0.5));
        expect(connectionRect.right, lessThanOrEqualTo(size.width + 0.5));

        final infoTexts = tester.widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('ra-info-card')),
            matching: find.byType(Text),
          ),
        );
        expect(infoTexts, isNotEmpty);
        for (final text in infoTexts) {
          expect(text.maxLines, isNull);
          expect(text.softWrap, isNot(false));
        }

        expect(tester.takeException(), isNull);
        // Dispose focus nodes, gamepad subscriptions and scroll controllers
        // while the iOS test environment is still active.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
      // TestVariant restores the platform before Flutter verifies its global
      // invariants; an outer tearDown callback runs too late for that check.
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
