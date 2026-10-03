import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/retroarch_locale.dart';
import 'package:neostation/services/retroarch_migration_service.dart';
import 'package:neostation/widgets/retroarch_migration_dialog.dart';
import 'package:path/path.dart' as path;

import 'retroarch_migration_service_test.dart' show FailingMigrationPreferences;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FailingMigrationPreferences preferences;
  late RetroArchMigrationService service;
  late Directory sandbox;

  setUp(() async {
    preferences = FailingMigrationPreferences();
    service = RetroArchMigrationService(preferences: preferences);
    await service.initialize(existingInstallation: true);
    sandbox = await Directory.systemTemp.createTemp('retroarch-dialog-test-');
  });
  tearDown(() async {
    await sandbox.delete(recursive: true);
  });

  Future<void> open(
    WidgetTester tester, {
    Future<bool> Function()? probe,
    Future<String?> Function()? picker,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1400));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => RetroArchMigrationDialog.showIfNeeded(
                context,
                service: service,
                availabilityProbe: probe ?? () async => true,
                folderPicker: picker ?? () async => null,
                targetRoot: Directory(path.join(sandbox.path, 'target')),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('absent backend defers offer without changing choice', (
    tester,
  ) async {
    await open(tester, probe: () async => false);
    expect(find.byType(RetroArchMigrationDialog), findsNothing);
    expect(service.usesEmbedded, isFalse);
    expect(service.needsMigration, isTrue);
  });

  testWidgets('decline closes once and persists external choice', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(
      find.byKey(const ValueKey('retroarchMigrationKeepExternal')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RetroArchMigrationDialog), findsNothing);
    expect(service.usesEmbedded, isFalse);
    expect(service.needsMigration, isFalse);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(RetroArchMigrationDialog), findsNothing);
  });

  testWidgets('failed saving keeps visible offer for retry', (tester) async {
    await open(tester);
    preferences.failWrites = true;
    await tester.tap(
      find.byKey(const ValueKey('retroarchMigrationSwitchOnly')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RetroArchMigrationDialog), findsOneWidget);
    expect(
      find.text(RetroArchLocale.values['en']!['retroarchMigrationFailure']!),
      findsOneWidget,
    );
    expect(service.usesEmbedded, isFalse);
    preferences.failWrites = false;
    await tester.tap(
      find.byKey(const ValueKey('retroarchMigrationSwitchOnly')),
    );
    await tester.pumpAndSettle();
    expect(service.usesEmbedded, isTrue);
    expect(find.byType(RetroArchMigrationDialog), findsNothing);
  });

  testWidgets(
    'cancelled folder pick retains external and permits switch without copy',
    (tester) async {
      await open(tester);
      await tester.tap(
        find.byKey(const ValueKey('retroarchMigrationCopyAndSwitch')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('retroarchMigrationChooseFolder')),
      );
      await tester.pumpAndSettle();
      expect(service.usesEmbedded, isFalse);
      expect(service.needsMigration, isTrue);
      await tester.ensureVisible(
        find.byKey(const ValueKey('retroarchMigrationSwitchOnly')),
      );
      await tester.tap(
        find.byKey(const ValueKey('retroarchMigrationSwitchOnly')),
      );
      await tester.pumpAndSettle();
      expect(service.usesEmbedded, isTrue);
    },
  );

  testWidgets(
    'successful verified copy switches only after completion and preserves source',
    (tester) async {
      final source = Directory(path.join(sandbox.path, 'source'));
      final original = File(path.join(source.path, 'saves/game.srm'));
      await tester.runAsync(() async {
        await original.parent.create(recursive: true);
        await original.writeAsString('saved-progress');
      });
      await open(tester, picker: () async => source.path);
      await tester.tap(
        find.byKey(const ValueKey('retroarchMigrationCopyAndSwitch')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('retroarchMigrationChooseFolder')),
      );
      await tester.pumpAndSettle();
      expect(service.usesEmbedded, isFalse);
      await tester.ensureVisible(
        find.byKey(const ValueKey('retroarchMigrationCopyAndSwitch')),
      );
      // Filesystem I/O requires the real async zone rather than pumpAndSettle's
      // simulated frame clock while an indeterminate progress indicator runs.
      await tester.runAsync(() async {
        await tester.tap(
          find.byKey(const ValueKey('retroarchMigrationCopyAndSwitch')),
        );
        for (var i = 0; i < 100 && !service.usesEmbedded; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(service.usesEmbedded, isTrue);
      await tester.runAsync(() async {
        expect(await original.readAsString(), 'saved-progress');
        expect(
          await File(
            path.join(sandbox.path, 'target/saves/game.srm'),
          ).readAsString(),
          'saved-progress',
        );
      });
    },
  );
}
