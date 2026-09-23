import 'package:flutter/material.dart';

/// All carousel controls share the rail's gutter, including the alphabet and
/// footer. Keep the gutter while hidden so selection never jumps sideways.
class CarouselChromeLayout extends StatelessWidget {
  const CarouselChromeLayout({
    super.key,
    required this.unit,
    required this.safeLeft,
    required this.safeRight,
    required this.legendHidden,
    required this.artwork,
    required this.letters,
    required this.footer,
    required this.legend,
    required this.edgeReshowZone,
  });

  final double unit, safeLeft, safeRight;
  final bool legendHidden;
  final Widget artwork, letters, footer, legend, edgeReshowZone;

  @override
  Widget build(BuildContext context) {
    final gutter = 72 * unit;
    final bottomInsets = EdgeInsets.only(
      left: safeLeft + gutter,
      right: safeRight,
    );
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  left: safeLeft + gutter,
                  right: safeRight + gutter,
                ),
                child: artwork,
              ),
            ),
            Padding(padding: bottomInsets, child: letters),
            Padding(padding: bottomInsets, child: footer),
          ],
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          top: 12 * unit,
          bottom: 12 * unit,
          width: 50 * unit,
          left: legendHidden ? -(gutter + safeLeft) : safeLeft + 10 * unit,
          child: IgnorePointer(
            ignoring: legendHidden,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              opacity: legendHidden ? 0 : 1,
              child: Align(
                alignment: Alignment.topLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topLeft,
                  child: legend,
                ),
              ),
            ),
          ),
        ),
        edgeReshowZone,
      ],
    );
  }
}
