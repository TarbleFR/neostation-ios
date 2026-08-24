import 'dart:async';
import 'package:flutter/material.dart';

/// A performance-optimized auto-scrolling container for long text descriptions.
///
/// Implements a tick-based scrolling engine that operates independently of the
/// framework's build cycle using [Timer.periodic] and direct [ScrollController]
/// manipulation. This ensures that frequent [setState] calls in parent widgets
/// do not disrupt the smooth scrolling animation.
class ScrollingDescriptionText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const ScrollingDescriptionText({
    super.key,
    required this.text,
    required this.style,
  });

  @override
  State<ScrollingDescriptionText> createState() {
    return _ScrollingDescriptionTextState();
  }
}

class _ScrollingDescriptionTextState extends State<ScrollingDescriptionText> {
  final ScrollController _scrollController = ScrollController();
  Timer? _timer;

  /// Configuration for readable scrolling speed (~20 logical pixels per second).
  static const double _pixelsPerSecond = 20.0;
  static const Duration _tick = Duration(milliseconds: 50);
  static final double _pixelsPerTick =
      _pixelsPerSecond * _tick.inMilliseconds / 1000.0;

  @override
  void initState() {
    super.initState();
    // Defer the start of scrolling until the layout is fully resolved.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleStart(2000));
  }

  @override
  void didUpdateWidget(ScrollingDescriptionText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the content changes, reset the scroll position and restart the timer.
    if (oldWidget.text != widget.text) {
      _cancelTimer();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
        _scheduleStart(2000);
      });
    }
  }

  /// Schedules the start of the scrolling sequence after an optional initial delay.
  void _scheduleStart(int delayMs) {
    _cancelTimer();
    _timer = Timer(Duration(milliseconds: delayMs), _startTicking);
  }

  /// Initiates the periodic tick-based movement.
  void _startTicking() {
    _cancelTimer();
    _timer = Timer.periodic(_tick, _onTick);
  }

  /// Execution logic for each scroll tick.
  void _onTick(Timer timer) {
    if (!mounted || !_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) {
      // If the text fits the viewport, no scrolling is required.
      timer.cancel();
      return;
    }

    final current = _scrollController.offset;
    if (current >= maxScroll - 0.5) {
      // Boundary Condition: Reached the end.
      // Pause, reset to top, and schedule a restart.
      timer.cancel();
      _timer = Timer(const Duration(milliseconds: 2500), () {
        if (!mounted) return;
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
        _scheduleStart(1000);
      });
    } else {
      // Incremental movement toward the boundary.
      _scrollController.jumpTo(
        (current + _pixelsPerTick).clamp(0.0, maxScroll),
      );
    }
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _cancelTimer();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      child: Text(widget.text, style: widget.style),
    );
  }
}
