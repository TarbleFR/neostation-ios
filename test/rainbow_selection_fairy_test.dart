import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/widgets/rainbow_selection_border.dart';

void main() {
  testWidgets('orbiting fairy is rendered only when requested', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 220,
            height: 140,
            child: RainbowSelectionBorder(
              borderRadius: BorderRadius.circular(12),
              showOrbitingFairy: true,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('orbiting-selection-fairy')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 750));
    expect(
      find.byKey(const ValueKey('orbiting-selection-fairy')),
      findsOneWidget,
    );
  });

  test('grid, list and carousel explicitly opt in to the fairy', () {
    final grid = File(
      'lib/screens/game_screen/my_games_grid.dart',
    ).readAsStringSync();
    final list = File(
      'lib/screens/game_screen/game_list_view.dart',
    ).readAsStringSync();
    final carousel = File(
      'lib/screens/game_screen/my_games_carousel.dart',
    ).readAsStringSync();

    expect(grid, contains('showOrbitingFairy: true'));
    expect(list, contains('showOrbitingFairy: true'));
    expect(carousel, contains('showOrbitingFairy: true'));
  });
}
