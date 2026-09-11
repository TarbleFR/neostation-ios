import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Lightweight animated rainbow outline used for the currently selected game.
///
/// The child is retained by [AnimatedBuilder], so only the custom painter is
/// repainted while the gradient rotates. This keeps artwork/video widgets from
/// rebuilding every animation tick.
class RainbowSelectionBorder extends StatefulWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final double borderWidth;
  final double glowBlur;
  final double glowWidth;
  final Duration duration;
  final bool showOrbitingFairy;
  final double fairySize;

  const RainbowSelectionBorder({
    super.key,
    required this.child,
    required this.borderRadius,
    this.borderWidth = 4,
    this.glowBlur = 5,
    this.glowWidth = 7,
    this.duration = const Duration(seconds: 3),
    this.showOrbitingFairy = false,
    this.fairySize = 18,
  });

  @override
  State<RainbowSelectionBorder> createState() => _RainbowSelectionBorderState();
}

class _RainbowSelectionBorderState extends State<RainbowSelectionBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..repeat();
  }

  @override
  void didUpdateWidget(covariant RainbowSelectionBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
      if (!_controller.isAnimating) _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      return _buildFrame(progress: 0, child: widget.child);
    }

    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        return _buildFrame(progress: _controller.value, child: child!);
      },
    );
  }

  Widget _buildFrame({required double progress, required Widget child}) {
    final border = CustomPaint(
      foregroundPainter: _RainbowBorderPainter(
        progress: progress,
        borderRadius: widget.borderRadius,
        borderWidth: widget.borderWidth,
        glowBlur: widget.glowBlur,
        glowWidth: widget.glowWidth,
      ),
      child: child,
    );
    if (!widget.showOrbitingFairy) return border;

    // Keep the fairy inside the card cell: the grid rows are memoized and
    // clipped, so an outside overlay would either disappear at the row edge or
    // force every row to repaint. Only the selected cell owns this lightweight
    // orbit and its artwork remains the static [AnimatedBuilder.child].
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        border,
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final horizontalRadius = math.max(
                  0.0,
                  constraints.maxWidth / 2 - widget.fairySize * 0.8,
                );
                final verticalRadius = math.max(
                  0.0,
                  constraints.maxHeight / 2 - widget.fairySize * 0.8,
                );
                final angle = progress * math.pi * 2 - math.pi / 2;
                final offset = Offset(
                  math.cos(angle) * horizontalRadius,
                  math.sin(angle) * verticalRadius,
                );
                final pulse = 0.96 + math.sin(progress * math.pi * 4) * 0.04;

                return Align(
                  alignment: Alignment.center,
                  child: Transform.translate(
                    offset: offset,
                    child: Transform.scale(
                      scale: pulse,
                      child: ExcludeSemantics(
                        child: Text(
                          '🧚',
                          key: const ValueKey('orbiting-selection-fairy'),
                          style: TextStyle(
                            fontSize: widget.fairySize,
                            height: 1,
                            shadows: const [
                              Shadow(color: Colors.white, blurRadius: 5),
                              Shadow(color: Color(0xFFBF5AF2), blurRadius: 9),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _RainbowBorderPainter extends CustomPainter {
  static const List<Color> _colors = [
    Color(0xFFFF3B30),
    Color(0xFFFF9500),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF00C7BE),
    Color(0xFF0A84FF),
    Color(0xFF5E5CE6),
    Color(0xFFBF5AF2),
    Color(0xFFFF2D55),
    Color(0xFFFF3B30),
  ];

  final double progress;
  final BorderRadius borderRadius;
  final double borderWidth;
  final double glowBlur;
  final double glowWidth;

  const _RainbowBorderPainter({
    required this.progress,
    required this.borderRadius,
    required this.borderWidth,
    required this.glowBlur,
    required this.glowWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || borderWidth <= 0) return;

    final rect = Offset.zero & size;
    final inset = math.max(borderWidth, glowWidth) / 2;
    final rrect = borderRadius.toRRect(rect).deflate(inset);
    final shader = SweepGradient(
      colors: _colors,
      transform: GradientRotation(progress * math.pi * 2),
    ).createShader(rect);

    if (glowBlur > 0 && glowWidth > 0) {
      final glowPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = glowWidth
        ..shader = shader
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, glowBlur);
      canvas.drawRRect(rrect, glowPaint);
    }

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..shader = shader;
    canvas.drawRRect(rrect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _RainbowBorderPainter oldDelegate) {
    return progress != oldDelegate.progress ||
        borderRadius != oldDelegate.borderRadius ||
        borderWidth != oldDelegate.borderWidth ||
        glowBlur != oldDelegate.glowBlur ||
        glowWidth != oldDelegate.glowWidth;
  }
}
