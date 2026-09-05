import 'dart:io';

import 'package:dolphin_internal_bridge/dolphin_system_emulator_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Dolphin identity in System Settings', () {
    for (final folder in ['gc', 'wii', ' GC ', 'WII']) {
      test('shows the built-in engine for $folder on iOS', () {
        expect(DolphinSystemEmulatorCard.appliesTo(
          systemFolderName: folder, isIOS: true), isTrue);
      });
      test('keeps the pre-existing emulator choices for $folder off iOS', () {
        expect(DolphinSystemEmulatorCard.appliesTo(
          systemFolderName: folder, isIOS: false), isFalse);
      });
    }
    test('does not relabel other systems or infer a route from file extensions', () {
      for (final folder in ['', 'all', 'favorites', 'nes', 'snes', 'ps1', 'ps2',
        'ps3', 'switch', '3ds', 'wiiu', 'iso', 'game.iso', 'gc/game.iso']) {
        expect(DolphinSystemEmulatorCard.appliesTo(
          systemFolderName: folder, isIOS: true), isFalse, reason: folder);
      }
    });
    testWidgets('displays Dolphin iOS, not RetroArch or a simulated ready state', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: DolphinSystemEmulatorCard())));
      expect(find.text('Dolphin iOS'), findsOneWidget);
      expect(find.text('NeoStation'), findsOneWidget);
      expect(find.text('RetroArch'), findsNothing);
      expect(find.textContaining('Ready'), findsNothing);
      final tile = tester.widget<ListTile>(find.byKey(
        const ValueKey('dolphin-system-emulator')));
      expect(tile.onTap, isNull);
      expect(tile.trailing, isNull);
    });
    test('the system dialog uses the native identity before external discovery', () {
      final source = File('lib/widgets/system_emulator_settings_dialog.dart').readAsStringSync();
      expect(source, contains('DolphinSystemEmulatorCard.appliesTo'));
      expect(source, contains('isIOS: Platform.isIOS'));
      expect(source, contains('DolphinSystemEmulatorCard()'));
      final loaderStart = source.indexOf('Future<void> _loadCores()');
      final loaderEnd = source.indexOf('void _updateFocusNodes()', loaderStart);
      final loader = source.substring(loaderStart, loaderEnd);
      expect(loader.indexOf('if (_usesInternalDolphin)'), greaterThanOrEqualTo(0));
      expect(loader.indexOf('if (_usesInternalDolphin)'),
        lessThan(loader.indexOf('EmulatorRepository.getCoresBySystemId')));
    });
  });
}
