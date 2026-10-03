import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_core_preferences.dart';
import 'package:neostation/services/retroarch_import_service.dart';
import 'package:neostation/widgets/retroarch_library_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> showActions(
    WidgetTester tester, {
    required Future<Set<String>> Function() packaged,
    RetroArchLibraryImporter? files,
    RetroArchLibraryImporter? folders,
    Future<void> Function()? refreshed,
  }) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(800, 600),
        builder: (context, child) => MaterialApp(
          home: Scaffold(
            body: RetroArchLibraryActions(
              systemFolder: 'nes',
              packagedCoreProbe: packaged,
              fileImporter: files,
              folderImporter: folders,
              onLibraryChanged: refreshed ?? () async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'console choice lists packaged cores and persists explicit change',
    (tester) async {
      await showActions(
        tester,
        packaged: () async => {'fceumm', 'nestopia', 'dolphin'},
      );
      expect(find.text('FCEUmm'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('retroarch-core-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Nestopia UE'), findsOneWidget);
      expect(find.text('Dolphin'), findsNothing);
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, 'Nestopia UE'),
      );
      await tester.pumpAndSettle();
      expect(
        (await RetroArchCorePreferences.preferredCore('nes')).identifier,
        'nestopia',
      );
      expect(find.text('Nestopia UE'), findsOneWidget);
    },
  );

  testWidgets(
    'unavailable saved core is retained and recoverable, never silently replaced',
    (tester) async {
      await RetroArchCorePreferences.setPreferredCore('nes', 'nestopia');
      await showActions(tester, packaged: () async => {'fceumm'});
      expect(find.text('Nestopia UE'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(
        (await RetroArchCorePreferences.preferredCore('nes')).identifier,
        'nestopia',
      );
      await tester.tap(find.byKey(const ValueKey('retroarch-core-menu')));
      await tester.pumpAndSettle();
      final options = find.byType(CheckedPopupMenuItem<String>);
      expect(options, findsOneWidget);
      expect(
        tester.widget<CheckedPopupMenuItem<String>>(options).value,
        'fceumm',
      );
    },
  );

  testWidgets(
    'menu dispatches file or folder imports and refreshes imported games',
    (tester) async {
      final calls = <String>[];
      var refreshed = 0;
      await showActions(
        tester,
        packaged: () async => {'fceumm'},
        files: ({required systemFolder, bios = false, replace = false}) async {
          calls.add('files:$systemFolder:$bios:$replace');
          return const RetroArchImportResult(imported: 2, skipped: 1);
        },
        folders:
            ({required systemFolder, bios = false, replace = false}) async {
              calls.add('folders:$systemFolder:$bios:$replace');
              return const RetroArchImportResult(imported: 1);
            },
        refreshed: () async {
          refreshed++;
        },
      );
      await tester.tap(find.byKey(const ValueKey('retroarch-import-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import games'));
      await tester.pumpAndSettle();
      expect(calls, ['files:nes:false:false']);
      expect(refreshed, 1);
      expect(find.text('Copied: 2 · skipped: 1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('retroarch-import-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import a BIOS folder'));
      await tester.pumpAndSettle();
      expect(calls.last, 'folders:nes:true:false');
      expect(
        refreshed,
        1,
        reason: 'BIOS import must not add BIOS as game rows.',
      );
    },
  );

  testWidgets(
    'core removed after menu opens is not committed and has separate diagnostics',
    (tester) async {
      var packaged = {'fceumm', 'nestopia'};
      await showActions(tester, packaged: () async => packaged);
      await tester.tap(find.byKey(const ValueKey('retroarch-core-menu')));
      await tester.pumpAndSettle();
      packaged = {'fceumm'};
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, 'Nestopia UE'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        (await RetroArchCorePreferences.preferredCore('nes')).identifier,
        'fceumm',
      );
      expect(
        find.text(
          'The selected RetroArch core is not available in this build.',
        ),
        findsOneWidget,
      );
      expect(find.text('Technical details'), findsOneWidget);
      await tester.tap(find.text('Technical details'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('RETROARCH_CORE_UNAVAILABLE'), findsOneWidget);
    },
  );
}
