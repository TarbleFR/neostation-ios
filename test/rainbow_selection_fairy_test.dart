import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all playlist views keep the rainbow halo without the fairy', () {
    final border = File(
      'lib/widgets/rainbow_selection_border.dart',
    ).readAsStringSync();
    final grid = File(
      'lib/screens/game_screen/my_games_grid.dart',
    ).readAsStringSync();
    final list = File(
      'lib/screens/game_screen/game_list_view.dart',
    ).readAsStringSync();
    final carousel = File(
      'lib/screens/game_screen/my_games_carousel.dart',
    ).readAsStringSync();

    expect(border, contains('class RainbowSelectionBorder'));
    expect(border, contains('_RainbowBorderPainter'));
    for (final source in <String>[border, grid, list, carousel]) {
      expect(source, isNot(contains('showOrbitingFairy')));
      expect(source, isNot(contains('fairySize')));
      expect(source, isNot(contains('orbiting-selection-fairy')));
      expect(source, isNot(contains('🧚')));
    }
  });
}
