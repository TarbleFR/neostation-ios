import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../../../providers/sqlite_config_provider.dart';
import '../../../../services/sfx_service.dart';
import '../../../../themes/corner_radii.dart';

class GameDetailsScreenshotVideoTab extends StatefulWidget {
  final String screenshotPath;
  final bool isVideoDelayActive;
  final VideoPlayerController? videoController;
  final int imageVersion;
  final VoidCallback onToggleVideoMute;

  const GameDetailsScreenshotVideoTab({
    super.key,
    required this.screenshotPath,
    required this.isVideoDelayActive,
    this.videoController,
    required this.imageVersion,
    required this.onToggleVideoMute,
  });

  @override
  State<GameDetailsScreenshotVideoTab> createState() =>
      _GameDetailsScreenshotVideoTabState();
}

class _GameDetailsScreenshotVideoTabState
    extends State<GameDetailsScreenshotVideoTab> {
  final Map<String, double> _imageAspectRatios = {};

  ImageStream? _currentImageStream;
  ImageStreamListener? _currentImageListener;

  void _loadImageAspectRatio(String path) {
    if (_imageAspectRatios.containsKey(path) || path.isEmpty) return;

    final File file = File(path);
    if (!file.existsSync()) return;

    _removeImageListener();

    final Image image = Image.file(file);
    final ImageStream stream = image.image.resolve(const ImageConfiguration());

    final listener = ImageStreamListener((
      ImageInfo info,
      bool synchronousCall,
    ) {
      if (!mounted) return;
      final double aspectRatio = info.image.width / info.image.height;
      if (aspectRatio <= 0 || (_imageAspectRatios[path] == aspectRatio)) {
        return;
      }

      void update() {
        setState(() {
          _imageAspectRatios[path] = aspectRatio;
        });
      }

      if (synchronousCall) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) update();
        });
      } else {
        update();
      }
    });

    stream.addListener(listener);
    _currentImageStream = stream;
    _currentImageListener = listener;
  }

  void _removeImageListener() {
    if (_currentImageStream != null && _currentImageListener != null) {
      _currentImageStream!.removeListener(_currentImageListener!);
      _currentImageStream = null;
      _currentImageListener = null;
    }
  }

  @override
  void dispose() {
    _removeImageListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenshotPath = widget.screenshotPath;

    final bool hasVideo =
        widget.videoController != null &&
        widget.videoController!.value.isInitialized;

    if (screenshotPath.isNotEmpty) {
      _loadImageAspectRatio(screenshotPath);
    }

    double mediaAspectRatio = 16 / 9;

    if (!widget.isVideoDelayActive && hasVideo) {
      mediaAspectRatio = widget.videoController!.value.aspectRatio;
    } else if (_imageAspectRatios.containsKey(screenshotPath)) {
      mediaAspectRatio = _imageAspectRatios[screenshotPath]!;
    }

    if (mediaAspectRatio <= 0 ||
        mediaAspectRatio.isNaN ||
        mediaAspectRatio.isInfinite) {
      mediaAspectRatio = 16 / 9;
    }

    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();

    // Reserve the real top and bottom chrome before fitting media. The header
    // is 46.r and the footer is 61.r, so tall 4:3/vertical previews can never
    // touch the tabs while wide Switch previews still get a little more room.
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalClearance = 8.r;
        final headerClearance = 58.r;
        final footerClearance = 72.r;

        final availableWidth =
            constraints.maxWidth - (horizontalClearance * 2);
        final availableHeight =
            constraints.maxHeight - headerClearance - footerClearance;

        if (availableWidth <= 0 || availableHeight <= 0) {
          return const SizedBox.shrink();
        }

        final maxMediaWidth = availableWidth < 230.r
            ? availableWidth
            : 230.r;
        final maxMediaHeight = availableHeight < 175.r
            ? availableHeight
            : 175.r;

        return Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalClearance,
            headerClearance,
            horizontalClearance,
            footerClearance,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxMediaWidth,
                maxHeight: maxMediaHeight,
              ),
              child: AspectRatio(
                aspectRatio: mediaAspectRatio,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: radii.radiusInternal,
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(
                          context,
                        ).colorScheme.shadow.withValues(alpha: 0.3),
                        blurRadius: 3.r,
                        offset: Offset(3.0.r, 3.0.r),
                      ),
                    ],
                    color: Colors.black,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!widget.isVideoDelayActive &&
                          hasVideo &&
                          widget.videoController!.value.isInitialized &&
                          widget.videoController!.value.size.width > 0 &&
                          widget.videoController!.value.size.height > 0) ...[
                        Consumer<SqliteConfigProvider>(
                          builder: (context, config, child) {
                            return VideoPlayer(widget.videoController!);
                          },
                        ),
                      ] else if (File(screenshotPath).existsSync()) ...[
                        Image.file(
                          File(screenshotPath),
                          height: double.infinity,
                          cacheHeight: 640,
                          key: ValueKey(
                            '${screenshotPath}_fg_${widget.imageVersion}',
                          ),
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ] else
                        Center(
                          child: Icon(
                            Symbols.videogame_asset_rounded,
                            size: 48.r,
                            color: Colors.white24,
                          ),
                        ),

                      if (!widget.isVideoDelayActive && hasVideo)
                        Positioned(
                          bottom: 8.r,
                          right: 8.r,
                          child: ExcludeFocus(
                            child: Material(
                              color: Colors.black54,
                              borderRadius: radii.radiusExternal,
                              child: InkWell(
                                onTap: () {
                                  SfxService().playNavSound();
                                  widget.onToggleVideoMute();
                                },
                                canRequestFocus: false,
                                focusColor: Colors.transparent,
                                hoverColor: Colors.transparent,
                                highlightColor: Colors.transparent,
                                splashColor: Colors.transparent,
                                borderRadius: radii.radiusInternal,
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 8.r,
                                    vertical: 4.r,
                                  ),
                                  child: Consumer<SqliteConfigProvider>(
                                    builder: (context, configProvider, child) {
                                      final isMuted =
                                          !configProvider.config.videoSound;
                                      return Icon(
                                        isMuted
                                            ? Symbols.volume_off_rounded
                                            : Symbols.volume_up_rounded,
                                        size: 16.r,
                                        color: Colors.white,
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
