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

  const RainbowSelectionBorder({
    super.key,
    required this.child,
    required this.borderRadius,
    this.borderWidth = 4,
    this.glowBlur = 5,
    this.glowWidth = 7,
    this.duration = const Duration(seconds: 3),
  });

  @override
  State<RainbowSelectionBorder> createState() =>
      _RainbowSelectionBorderState();
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
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      return CustomPaint(
        foregroundPainter: _RainbowBorderPainter(
          progress: 0,
          borderRadius: widget.borderRadius,
          borderWidth: widget.borderWidth,
          glowBlur: widget.glowBlur,
          glowWidth: widget.glowWidth,
        ),
        child: widget.child,
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        return CustomPaint(
          foregroundPainter: _RainbowBorderPainter(
            progress: _controller.value,
            borderRadius: widget.borderRadius,
            borderWidth: widget.borderWidth,
            glowBlur: widget.glowBlur,
            glowWidth: widget.glowWidth,
          ),
          child: child,
        );
      },
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
