import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Silent, one-shot NeoStation iOS launch movie.
///
/// The asset is intentionally local so launch never depends on networking or
/// user storage. [onFinished] fires when the 2.8 s movie reaches its end, or
/// when the decoder cannot initialize, so presentation can never deadlock boot.
class StartupIntroVideo extends StatefulWidget {
  const StartupIntroVideo({
    super.key,
    required this.assetPath,
    required this.onFinished,
  });

  final String assetPath;
  final VoidCallback onFinished;

  @override
  State<StartupIntroVideo> createState() => _StartupIntroVideoState();
}

class _StartupIntroVideoState extends State<StartupIntroVideo> {
  late final VideoPlayerController _controller;
  Timer? _safetyTimer;
  bool _ready = false;
  bool _reportedFinished = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.asset(widget.assetPath)
      ..addListener(_onVideoTick);

    // The file is 2.8 s. One extra second covers an unusually slow first
    // decoder setup without ever allowing a presentation problem to block boot.
    _safetyTimer = Timer(const Duration(milliseconds: 3800), _finish);
    unawaited(_prepareAndPlay());
  }

  Future<void> _prepareAndPlay() async {
    try {
      await _controller.initialize();
      await _controller.setLooping(false);
      await _controller.setVolume(0.0);
      if (!mounted) return;
      setState(() => _ready = true);
      await _controller.play();
    } catch (_) {
      _finish();
    }
  }

  void _onVideoTick() {
    final value = _controller.value;
    if (!value.isInitialized || value.duration <= Duration.zero) return;

    const endTolerance = Duration(milliseconds: 40);
    if (value.position + endTolerance >= value.duration) {
      _finish();
    }
  }

  void _finish() {
    if (_reportedFinished) return;
    _reportedFinished = true;
    _safetyTimer?.cancel();
    widget.onFinished();
  }

  @override
  void dispose() {
    // If another startup surface replaces this widget unexpectedly, release the
    // launch gate rather than leaving main() waiting for a disposed player.
    _finish();
    _controller.removeListener(_onVideoTick);
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF01050D),
      child: Center(
        child: AnimatedOpacity(
          opacity: _ready ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: _ready
              ? FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: _controller.value.size.width,
                    height: _controller.value.size.height,
                    child: VideoPlayer(_controller),
                  ),
                )
              : const SizedBox.expand(),
        ),
      ),
    );
  }
}
