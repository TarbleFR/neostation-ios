import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/library_visibility_service.dart';
import 'package:neostation/widgets/console_library_picker.dart';
import 'package:neostation/services/retroarch_core_catalog.dart';
import 'package:neostation/services/retroarch_core_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/services/retroarch_migration_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  SystemModel model(String folder, String name) => SystemModel(
    id: folder,
    folderName: folder,
    realName: name,
    iconImage: '',
    color: '#000000',
  );

  Future<void> showPicker(
    WidgetTester tester, {
    required List<SystemModel> libraries,
    Set<String> enabled = const {},
    required Future<void> Function(Set<String>) save,
    required Future<void> Function() finish,
    Set<String>? packaged,
    Future<String?> Function(String)? loadPreferredCore,
    Future<void> Function(Map<String, String>)? savePreferredCores,
    Future<Set<String>> Function()? loadPackagedCores,
    RetroArchExecutionMode? executionMode,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ConsoleLibraryPicker(
          libraries: libraries,
          initiallyEnabled: enabled,
          onSave: save,
          onFinished: finish,
          firstLaunch: true,
          loadPackagedCores:
              loadPackagedCores ??
              () async =>
                  packaged ??
                  RetroArchCoreCatalog.cores
                      .map((core) => core.identifier)
                      .toSet(),
          loadPreferredCore:
              loadPreferredCore ??
              (folder) async =>
                  RetroArchCoreCatalog.defaultCore(folder).identifier,
          savePreferredCores: savePreferredCores,
          executionMode: executionMode,
        ),
      ),
    ),
  );

  testWidgets('first run starts unchecked and saves only chosen consoles', (
    tester,
  ) async {
    Set<String>? selected;
    var completed = false;
    await showPicker(
      tester,
      libraries: [model('nes', 'NES'), model('ps3', 'PlayStation 3')],
      save: (folders) async => selected = folders,
      finish: () async => completed = true,
    );
    await tester.pumpAndSettle();
    final rows = tester.widgetList<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(rows.map((row) => row.value), [false, false]);
    await tester.tap(find.text('NES'));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(selected, {'nes'});
    expect(completed, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'one regional checkbox preserves Genesis then controls both IDs',
    (tester) async {
      Set<String>? selected;
      await showPicker(
        tester,
        libraries: LibraryVisibilitySelection.groupConsoleChoices([
          model('md', 'Mega Drive'),
          model('genesis', 'Genesis'),
        ]),
        enabled: {'genesis'},
        save: (folders) async => selected = folders,
        finish: () async {},
      );
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      await tester.tap(find.text('Sega Mega Drive / Genesis'));
      await tester.pump();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      await tester.tap(find.text('Sega Mega Drive / Genesis'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(selected, {'md', 'genesis'});
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'empty choice is allowed and persistence failure stays reviewable',
    (tester) async {
      var writes = 0;
      var completed = false;
      await showPicker(
        tester,
        libraries: [model('nes', 'NES')],
        save: (folders) async {
          expect(folders, isEmpty);
          if (++writes == 1) throw StateError('disk write failed');
        },
        finish: () async => completed = true,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(completed, isFalse);
      expect(
        find.text('Could not save your library selection. Try again.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(writes, 2);
      expect(completed, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'enable console, choose emulator, persist and reopen the choice',
    (tester) async {
      Set<String> selected = {};
      Future<void> finish() async {}
      Future<void> save(Set<String> folders) async => selected = folders;
      final libraries = [model('nes', 'NES'), model('ps3', 'PlayStation 3')];
      await showPicker(
        tester,
        libraries: libraries,
        save: save,
        finish: finish,
      );
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      await tester.tap(find.text('NES'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('RetroArch — Nestopia UE').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(selected, {'nes'});
      expect(
        (await RetroArchCorePreferences.preferredCore('nes')).identifier,
        'nestopia',
      );
      await tester.pumpWidget(const SizedBox());
      await showPicker(
        tester,
        libraries: libraries,
        enabled: selected,
        save: save,
        finish: finish,
        loadPreferredCore: (folder) async =>
            (await RetroArchCorePreferences.preferredCore(folder)).identifier,
      );
      await tester.pumpAndSettle();
      final dropdown = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>),
      );
      expect(dropdown.initialValue, 'nestopia');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'core write failure keeps prior visibility and retries the draft',
    (tester) async {
      final service = await LibraryVisibilityService.create();
      await service.initialize(
        existingInstallation: false,
        previouslyVisibleFolders: {},
      );
      var coreWrites = 0;
      var finished = false;
      await showPicker(
        tester,
        libraries: [model('nes', 'NES')],
        save: (folders) async => service.save(
          LibraryVisibilitySelection(
            enabledFolders: folders,
            setupCompleted: true,
          ),
        ),
        finish: () async => finished = true,
        savePreferredCores: (choices) async {
          expect(choices['nes'], 'fceumm');
          if (++coreWrites == 1) {
            throw StateError('core preference write failed');
          }
          for (final choice in choices.entries) {
            await RetroArchCorePreferences.setPreferredCore(
              choice.key,
              choice.value,
            );
          }
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('NES'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(finished, isFalse);
      expect(service.read()!.setupCompleted, isFalse);
      expect(service.read()!.enabledFolders, isEmpty);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(coreWrites, 2);
      expect(finished, isTrue);
      expect(service.read()!.enabledFolders, {'nes'});
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'packaged choices exclude missing cores and keep fixed native labels',
    (tester) async {
      await showPicker(
        tester,
        libraries: [
          model('nes', 'NES'),
          model('snes', 'SNES'),
          model('ps3', 'PlayStation 3'),
        ],
        packaged: {'fceumm'},
        save: (_) async {},
        finish: () async {},
      );
      await tester.pumpAndSettle();
      expect(find.text('SNES'), findsNothing);
      expect(find.text('RPCS3'), findsOneWidget);
      await tester.tap(find.text('NES'));
      await tester.pumpAndSettle();
      final dropdown = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      expect(dropdown.items!.map((item) => item.value), ['fceumm']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'metadata failure blocks activation and retry preserves selection',
    (tester) async {
      var probes = 0;
      var saved = false;
      await showPicker(
        tester,
        libraries: [model('nes', 'NES')],
        enabled: {'nes'},
        save: (_) async => saved = true,
        finish: () async {},
        loadPackagedCores: () async {
          if (++probes == 1) throw StateError('metadata unavailable');
          return {'fceumm'};
        },
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Could not load emulator choices. Try again.'),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      expect(saved, isFalse);
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(probes, 2);
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(saved, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('grouped chooser reads the previously enabled Genesis core', (
    tester,
  ) async {
    final requested = <String>[];
    await showPicker(
      tester,
      libraries: LibraryVisibilitySelection.groupConsoleChoices([
        model('md', 'Mega Drive'),
        model('genesis', 'Genesis'),
      ]),
      enabled: {'genesis'},
      save: (_) async {},
      finish: () async {},
      loadPreferredCore: (folder) async {
        requested.add(folder);
        return 'picodrive';
      },
    );
    await tester.pumpAndSettle();
    expect(requested, ['genesis']);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .initialValue,
      'picodrive',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'external picker preserves the playlist core and needs no embedded metadata',
    (tester) async {
      var probedEmbedded = false;
      Map<String, String>? chosen;
      Set<String>? enabled;
      await showPicker(
        tester,
        libraries: [model('nes', 'NES')],
        enabled: {'nes'},
        executionMode: RetroArchExecutionMode.external,
        loadPackagedCores: () async {
          probedEmbedded = true;
          throw StateError('embedded bundle is absent');
        },
        save: (value) async => enabled = value,
        finish: () async {},
        savePreferredCores: (choices) async => chosen = choices,
      );
      await tester.pumpAndSettle();
      expect(probedEmbedded, isFalse);
      expect(find.text('RetroArch — external app'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.text('Choose the emulator in RetroArch'), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('retroarch_embedded_core_v1:nes'), isNull);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(chosen, isNull);
      expect(enabled, {'nes'});
      expect(preferences.getString('retroarch_embedded_core_v1:nes'), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
