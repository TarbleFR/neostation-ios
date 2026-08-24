import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../../utils/image_utils.dart';

/// Renders animated background media from the local filesystem.
///
/// GIFs keep NeoStation's shader-backed frame renderer. Supported videos
/// (MP4/M4V/MOV) use video_player, autoplay silently, loop indefinitely and
/// honour the same [BoxFit] contract as GIF backgrounds.
class ShaderGifWidget extends StatefulWidget {
  final String imagePath;
  final BoxFit fit;

  const ShaderGifWidget({
    super.key,
    required this.imagePath,
    this.fit = BoxFit.cover,
  });

  @override
  State<ShaderGifWidget> createState() => _ShaderGifWidgetState();
}

class _ShaderGifWidgetState extends State<ShaderGifWidget>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  ui.FragmentProgram? _program;
  List<ui.Image> _frames = [];
  List<Duration> _frameDurations = [];

  double _currentFrameIndex = 0;
  Ticker? _ticker;
  Duration _elapsedSinceStart = Duration.zero;
  Duration _lastTick = Duration.zero;

  VideoPlayerController? _videoController;
  bool _videoReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMedia();
  }

  @override
  void didUpdateWidget(covariant ShaderGifWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _loadMedia();
    }
  }

  Future<void> _loadMedia() async {
    if (ImageUtils.isVideo(widget.imagePath)) {
      await _clearGif();
      await _loadVideo();
      return;
    }

    await _clearVideo();
    await _loadShader();
    await _loadGif();
  }

  Future<void> _loadShader() async {
    if (_program != null) return;
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'assets/shaders/gif_player.frag',
      );
      if (mounted) {
        setState(() {
          _program = program;
        });
      }
    } catch (e) {
      debugPrint('Error loading GIF shader: $e');
    }
  }

  Future<void> _loadVideo() async {
    final path = widget.imagePath;
    final file = File(path);
    if (!await file.exists()) return;

    await _clearVideo();
    final controller = VideoPlayerController.file(file);
    _videoController = controller;

    try {
      await controller.initialize();
      if (!mounted ||
          _videoController != controller ||
          widget.imagePath != path) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(true);
      await controller.setVolume(0.0);
      await controller.play();
      if (mounted && _videoController == controller) {
        setState(() => _videoReady = true);
      }
    } catch (e) {
      debugPrint('Error loading background video "$path": $e');
      if (_videoController == controller) {
        _videoController = null;
      }
      await controller.dispose();
      if (mounted) setState(() => _videoReady = false);
    }
  }

  Future<void> _clearVideo() async {
    final controller = _videoController;
    _videoController = null;
    _videoReady = false;
    if (controller != null) {
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }

  Future<void> _clearGif() async {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    for (final frame in _frames) {
      frame.dispose();
    }
    _frames = [];
    _frameDurations = [];
    _currentFrameIndex = 0;
  }

  Future<void> _loadGif() async {
    await _clearGif();

    final file = File(widget.imagePath);
    if (!await file.exists()) return;

    try {
      final bytes = await file.readAsBytes();

      // First pass: get the logical source size.
      final initialCodec = await ui.instantiateImageCodec(bytes);
      final firstFrame = await initialCodec.getNextFrame();
      final int logicalWidth = firstFrame.image.width;
      final int logicalHeight = firstFrame.image.height;
      firstFrame.image.dispose();
      initialCodec.dispose();

      if (logicalWidth == 0) return;

      // Decode composed frames at a modest width. Supplying both dimensions
      // avoids delta-frame offset artefacts while keeping card memory bounded.
      const double targetWidthBase = 250.0;
      final double scale = targetWidthBase / logicalWidth;
      final int cellWidth = targetWidthBase.toInt();
      final int cellHeight = (logicalHeight * scale).toInt();

      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: cellWidth,
        targetHeight: cellHeight,
      );

      final int frameCount = codec.frameCount;
      final List<ui.Image> decodedFrames = [];
      final List<Duration> durations = [];

      for (int i = 0; i < frameCount; i++) {
        final frameInfo = await codec.getNextFrame();
        decodedFrames.add(frameInfo.image);
        durations.add(frameInfo.duration);
      }
      codec.dispose();

      if (mounted && !ImageUtils.isVideo(widget.imagePath)) {
        setState(() {
          _frames = decodedFrames;
          _frameDurations = durations;
          _currentFrameIndex = 0;
        });
        _startAnimation();
      } else {
        for (final frame in decodedFrames) {
          frame.dispose();
        }
      }
    } catch (e) {
      debugPrint('Error loading GIF: $e');
    }
  }

  void _startAnimation() {
    _ticker?.dispose();
    _ticker = createTicker(_onTick);
    _elapsedSinceStart = Duration.zero;
    _lastTick = Duration.zero;
    _ticker!.start();
  }

  void _onTick(Duration elapsed) {
    if (_frameDurations.isEmpty) return;

    final delta = elapsed - _lastTick;
    _lastTick = elapsed;
    _elapsedSinceStart += delta;

    Duration totalCycleDuration = _frameDurations.fold(
      Duration.zero,
      (prev, curr) => prev + curr,
    );

    final minCycle = Duration(milliseconds: 33 * _frames.length);
    if (totalCycleDuration < minCycle) {
      totalCycleDuration = minCycle;
    }

    final Duration currentCycleTime = Duration(
      microseconds:
          _elapsedSinceStart.inMicroseconds % totalCycleDuration.inMicroseconds,
    );

    Duration accumulated = Duration.zero;
    for (int i = 0; i < _frames.length; i++) {
      Duration frameDur = _frameDurations[i];
      if (frameDur < const Duration(milliseconds: 33)) {
        frameDur = const Duration(milliseconds: 33);
      }

      accumulated += frameDur;
      if (currentCycleTime < accumulated) {
        if (mounted && _currentFrameIndex != i.toDouble()) {
          setState(() {
            _currentFrameIndex = i.toDouble();
          });
        }
        break;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _videoController;
    if (controller == null || !_videoReady) return;

    if (state == AppLifecycleState.resumed) {
      unawaited(controller.play());
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(controller.pause());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final controller = _videoController;
    _videoController = null;
    if (controller != null) unawaited(controller.dispose());
    _ticker?.dispose();
    for (final frame in _frames) {
      frame.dispose();
    }
    super.dispose();
  }

  Widget _buildVideo() {
    final controller = _videoController;
    if (!_videoReady || controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    final size = controller.value.size;
    if (size.width <= 0 || size.height <= 0) {
      return const SizedBox.shrink();
    }

    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: widget.fit,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (ImageUtils.isVideo(widget.imagePath)) {
      return _buildVideo();
    }

    if (_program == null || _frames.isEmpty) {
      return const SizedBox.shrink();
    }

    final int index = _currentFrameIndex.toInt().clamp(0, _frames.length - 1);
    final ui.Image currentFrame = _frames[index];

    return CustomPaint(
      painter: _ShaderGifPainter(
        shader: _program!.fragmentShader(),
        currentFrame: currentFrame,
        fit: widget.fit,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _ShaderGifPainter extends CustomPainter {
  final ui.FragmentShader shader;
  final ui.Image currentFrame;
  final BoxFit fit;

  _ShaderGifPainter({
    required this.shader,
    required this.currentFrame,
    required this.fit,
  });

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, currentFrame.width.toDouble());
    shader.setFloat(3, currentFrame.height.toDouble());

    double fitValue = 0.0; // fill
    if (fit == BoxFit.contain) {
      fitValue = 1.0;
    } else if (fit == BoxFit.cover) {
      fitValue = 2.0;
    }

    shader.setFloat(4, fitValue);
    shader.setImageSampler(0, currentFrame);

    final paint = Paint()..shader = shader;
    canvas.drawRect(ui.Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _ShaderGifPainter oldDelegate) {
    return oldDelegate.currentFrame != currentFrame;
  }
}
