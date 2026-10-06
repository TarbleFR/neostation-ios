import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/utils/nav_tabs.dart';
import 'package:neostation/widgets/airplay_menu_button.dart';

/// AirPlay occupies a cell in the existing pill without becoming a navigation
/// tab. Canonical tab indices and controller bumper navigation stay intact.
class MainMenuTabStrip extends StatelessWidget {
  final List<NavTab> tabs;
  final NavTab selected;
  final bool showAirPlay;
  final Widget Function(NavTab) tabBuilder;

  const MainMenuTabStrip({
    super.key,
    required this.tabs,
    required this.selected,
    required this.showAirPlay,
    required this.tabBuilder,
  });

  @override
  Widget build(BuildContext context) {
    // Insert after search, including when search is hidden in preferences.
    final airPlaySlot = tabs
        .where((tab) => tab.index <= NavTab.search.index)
        .length;
    final cells = <NavTab?>[...tabs];
    if (showAirPlay) cells.insert(airPlaySlot, null);
    final selectedSlot = cells.indexOf(selected);
    return Stack(
      key: const ValueKey('main-menu-tab-strip'),
      children: [
        if (selectedSlot >= 0)
          AnimatedPositioned(
            key: const ValueKey('main-menu-tab-indicator'),
            left: selectedSlot * 32.r,
            top: 4.r,
            bottom: 4.r,
            width: 32.r,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeInOut,
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius:
                    Theme.of(
                      context,
                    ).extension<CornerRadii>()?.radiusInternal ??
                    BorderRadius.circular(4.r),
              ),
            ),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final tab in cells)
              SizedBox(
                key: ValueKey(
                  tab == null
                      ? 'main-menu-airplay-cell'
                      : 'main-menu-cell-${tab.name}',
                ),
                width: 32.r,
                height: 32.r,
                child: tab == null
                    ? const AirPlayMenuButton()
                    : tabBuilder(tab),
              ),
          ],
        ),
      ],
    );
  }
}
