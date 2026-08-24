import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/widgets/ios_emulator_choice_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Continue remains tappable on a short landscape screen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var finished = false;
    await tester.pumpWidget(
      MaterialApp(
        home: IosEmulatorChoiceScreen(
          onFinished: () => finished = true,
        ),
      ),
    );

    await tester.tap(find.text('RetroArch'));
    await tester.pump();

    final continueButton = find.byType(FilledButton);
    expect(continueButton.hitTestable(), findsOneWidget);
    await tester.tap(continueButton);
    await tester.pumpAndSettle();

    expect(finished, isTrue);
  });
}
