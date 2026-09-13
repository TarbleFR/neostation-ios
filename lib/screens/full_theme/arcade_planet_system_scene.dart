import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/full_theme_definition.dart';

/// Native Flutter reconstruction of Arcade Planet's system scene.
///
/// The source theme ships dedicated background families for 16:9, 16:10, 4:3,
/// 5:4 and 1:1. NeoStation selects the closest family from the actual viewport
/// instead of stretching the 16:9 artwork across every iPhone/iPad display.
class ArcadePlanetSystemScene extends StatefulWidget {
  const ArcadePlanetSystemScene({
    super.key,
    required this.theme,
    required this.systemFolder,
    required this.accent,
  });

  final FullThemeDefinition theme;
  final String systemFolder;
  final Color accent;

  @override
  State<ArcadePlanetSystemScene> createState() =>
      _ArcadePlanetSystemSceneState();
}

class _ArcadePlanetSystemSceneState extends State<ArcadePlanetSystemScene>
    with TickerProviderStateMixin {
  late final AnimationController _ambientController;
  late final AnimationController _entryController;
  late final Animation<double> _logoSlide;
  late final Animation<double> _controllerBounce;

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat(reverse: true);
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1450),
    )..forward();
    _logoSlide = CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.0, 0.58, curve: Curves.easeOutCubic),
    );
    _controllerBounce = CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.40, 1.0, curve: Curves.elasticOut),
    );
  }

  @override
  void didUpdateWidget(covariant ArcadePlanetSystemScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.systemFolder != widget.systemFolder ||
        oldWidget.theme.id != widget.theme.id) {
      _entryController
        ..reset()
        ..forward();
    }
  }

  @override
  void dispose() {
    _ambientController.dispose();
    _entryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.theme.isArcadePlanet) {
      return _GenericThemeBackdrop(
        path: widget.theme.systemBackdrop(widget.systemFolder),
        accent: widget.accent,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final safeHeight = constraints.maxHeight <= 0
            ? 1.0
            : constraints.maxHeight;
        final aspectRatio = constraints.maxWidth / safeHeight;
        final base = widget.theme.arcadePlanetBackgroundForAspect(
          aspectRatio,
          'bghlandscape.png',
        );
        final glow = widget.theme.arcadePlanetBackgroundForAspect(
          aspectRatio,
          'bgh2.png',
        );
        final foreground = widget.theme.arcadePlanetBackgroundForAspect(
          aspectRatio,
          'bgh3.png',
        );
        final sprite1 = widget.theme.systemSprite(widget.systemFolder);
        final sprite2 = widget.theme.systemSprite(
          widget.systemFolder,
          layer: 2,
        );
        final sprite3 = widget.theme.systemSprite(
          widget.systemFolder,
          layer: 3,
        );
        final controller = widget.theme.systemController(widget.systemFolder);
        final logo = widget.theme.rasterSystemLogo(widget.systemFolder);

        return RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _assetOrGradient(base),
              if (glow != null)
                AnimatedBuilder(
                  animation: _ambientController,
                  builder: (context, child) {
                    final opacity = 0.22 + (_ambientController.value * 0.58);
                    return Opacity(
                      opacity: opacity,
                      child: ColorFiltered(
                        colorFilter: ColorFilter.mode(
                          widget.accent.withValues(alpha: 0.38),
                          BlendMode.screen,
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: _fileImage(glow, BoxFit.cover),
                ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: Stack(
                  key: ValueKey('${widget.theme.id}:${widget.systemFolder}'),
                  fit: StackFit.expand,
                  children: [
                    if (sprite3 != null)
                      _spriteLayer(sprite3, 0.97, 0.54, 0.50),
                    if (sprite2 != null)
                      _spriteLayer(sprite2, 0.90, 0.51, 0.50),
                    if (sprite1 != null)
                      _spriteLayer(sprite1, 0.78, 0.47, 0.50),
                    if (logo != null) _logoLayer(logo),
                    if (controller != null) _controllerLayer(controller),
                  ],
                ),
              ),
              if (foreground != null)
                IgnorePointer(
                  child: Opacity(
                    opacity: 0.82,
                    child: _fileImage(foreground, BoxFit.cover),
                  ),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.42, 0.72, 1.0],
                    colors: [
                      Colors.black.withValues(alpha: 0.03),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.04),
                      Colors.black.withValues(alpha: 0.38),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _assetOrGradient(String? path) {
    if (path != null) return _fileImage(path, BoxFit.cover);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF18151D),
            widget.accent.withValues(alpha: 0.68),
            const Color(0xFF08070B),
          ],
        ),
      ),
    );
  }

  Widget _spriteLayer(
    String path,
    double intervalEnd,
    double verticalCenter,
    double widthFactor,
  ) {
    return AnimatedBuilder(
      animation: _entryController,
      builder: (context, child) {
        final local = CurvedAnimation(
          parent: _entryController,
          curve: Interval(
            0.30,
            intervalEnd,
            curve: Curves.easeOutBack,
          ),
        ).value;
        return Align(
          alignment: Alignment(0, (verticalCenter * 2) - 1),
          child: FractionallySizedBox(
            widthFactor: widthFactor,
            child: Transform.scale(
              scale: local,
              child: Opacity(
                opacity: local.clamp(0.0, 1.0).toDouble(),
                child: child,
              ),
            ),
          ),
        );
      },
      child: _fileImage(path, BoxFit.contain),
    );
  }

  Widget _logoLayer(String path) {
    return AnimatedBuilder(
      animation: _logoSlide,
      builder: (context, child) {
        final value = _logoSlide.value;
        final y = -0.26 + ((-0.78 + 0.26) * value);
        final scale = 1.5 - (0.5 * value);
        return Align(
          alignment: Alignment(0, y),
          child: FractionallySizedBox(
            widthFactor: 0.28,
            heightFactor: 0.17,
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: _fileImage(path, BoxFit.contain),
    );
  }

  Widget _controllerLayer(String path) {
    return AnimatedBuilder(
      animation: _controllerBounce,
      builder: (context, child) {
        final value = _controllerBounce.value;
        final bounce = (1 - value) * 0.12;
        return Align(
          alignment: Alignment(0, 0.47 - bounce),
          child: FractionallySizedBox(
            widthFactor: 0.14,
            heightFactor: 0.20,
            child: Opacity(
              opacity: value.clamp(0.0, 1.0).toDouble(),
              child: child,
            ),
          ),
        );
      },
      child: _fileImage(path, BoxFit.contain),
    );
  }

  Widget _fileImage(String path, BoxFit fit) {
    return Image.file(
      File(path),
      fit: fit,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
    );
  }
}

class _GenericThemeBackdrop extends StatelessWidget {
  const _GenericThemeBackdrop({required this.path, required this.accent});

  final String? path;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (path != null)
          Image.file(
            File(path!),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                const SizedBox.shrink(),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF17141D).withValues(alpha: 0.80),
                accent.withValues(alpha: 0.20),
                const Color(0xFF09080C).withValues(alpha: 0.90),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
