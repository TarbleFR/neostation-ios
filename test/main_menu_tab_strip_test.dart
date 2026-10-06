import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/nav_tabs.dart';
import 'package:neostation/widgets/main_menu_tab_strip.dart';

void main() {
  for (final hidden in [
    <NavTab>{},
    {NavTab.search},
    {NavTab.achievements},
    {NavTab.search, NavTab.achievements},
  ]) {
    testWidgets(
      'AirPlay shares equal cells and selection remains aligned: $hidden',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(844, 390));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final tabs = NavTab.values
            .where((tab) => !hidden.contains(tab))
            .toList();
        for (final selected in tabs) {
          await tester.pumpWidget(
            ScreenUtilInit(
              designSize: const Size(640, 480),
              builder: (context, child) => MaterialApp(
                home: Scaffold(
                  body: Center(
                    child: MainMenuTabStrip(
                      tabs: tabs,
                      selected: selected,
                      showAirPlay: true,
                      tabBuilder: (tab) =>
                          TextButton(onPressed: () {}, child: Text(tab.name)),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final strip = find.byKey(const ValueKey('main-menu-tab-strip'));
          final airPlay = find.byKey(const ValueKey('main-menu-airplay-cell'));
          expect(find.descendant(of: strip, matching: airPlay), findsOneWidget);
          final airRect = tester.getRect(airPlay);
          final systemRect = tester.getRect(
            find.byKey(const ValueKey('main-menu-cell-systems')),
          );
          expect(airRect.size, systemRect.size);
          expect(airRect.top, systemRect.top);
          if (!hidden.contains(NavTab.search)) {
            expect(
              tester
                  .getRect(find.byKey(const ValueKey('main-menu-cell-search')))
                  .right,
              airRect.left,
            );
          }
          if (!hidden.contains(NavTab.achievements)) {
            expect(
              airRect.right,
              tester
                  .getRect(
                    find.byKey(const ValueKey('main-menu-cell-achievements')),
                  )
                  .left,
            );
          }
          final selectedRect = tester.getRect(
            find.byKey(ValueKey('main-menu-cell-${selected.name}')),
          );
          final indicatorRect = tester.getRect(
            find.byKey(const ValueKey('main-menu-tab-indicator')),
          );
          expect(indicatorRect.left, selectedRect.left);
          expect(indicatorRect.width, selectedRect.width);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
  testWidgets('AirPlay is optional without shifting canonical tab identities', (
    tester,
  ) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(640, 480),
        builder: (context, child) => MaterialApp(
          home: MainMenuTabStrip(
            tabs: NavTab.values,
            selected: NavTab.settings,
            showAirPlay: false,
            tabBuilder: (tab) => Text(tab.name),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('main-menu-airplay-cell')), findsNothing);
    expect(NavTab.achievements.index, 2);
    expect(NavTab.settings.index, 4);
  });
}
