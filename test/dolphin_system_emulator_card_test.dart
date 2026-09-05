import 'package:dolphin_internal_bridge/dolphin_system_emulator_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('System emulator card shows Dolphin iOS, never RetroArch', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DolphinSystemEmulatorCard()),
      ),
    );
    expect(find.byKey(const ValueKey('dolphin-system-emulator')), findsOneWidget);
    expect(find.text('Dolphin iOS'), findsOneWidget);
    expect(find.textContaining('RetroArch'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('Card applies to both native console routes on iOS', () {
    for (final system in ['gc', 'wii', ' GC ', 'WII']) {
      expect(
        DolphinSystemEmulatorCard.appliesTo(
          systemFolderName: system,
          isIOS: true,
        ),
        isTrue,
      );
    }
  });

  test('Other systems and non-iOS platforms retain their emulator settings', () {
    for (final system in ['ps1', 'ps2', 'ps3', 'switch', '3ds', 'all', '']) {
      expect(
        DolphinSystemEmulatorCard.appliesTo(
          systemFolderName: system,
          isIOS: true,
        ),
        isFalse,
      );
    }
    for (final system in ['gc', 'wii']) {
      expect(
        DolphinSystemEmulatorCard.appliesTo(
          systemFolderName: system,
          isIOS: false,
        ),
        isFalse,
      );
    }
  });
}
