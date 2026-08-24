import 'dart:io';

import 'package:flutter/material.dart';
import 'package:neostation/utils/image_utils.dart';
import 'package:neostation/widgets/shaders/shader_gif_widget.dart';

/// Renders the user-selected custom background for the Systems main menu only.
///
/// This widget is intentionally owned by SystemContent rather than the app root,
/// so pushed game playlists and every other top-level screen keep their normal
/// theme background.
class CustomMainMenuBackground extends StatelessWidget {
  const CustomMainMenuBackground({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    if (!file.existsSync()) return const SizedBox.shrink();

    if (ImageUtils.isAnimatedBackground(path)) {
      return ShaderGifWidget(
        key: ValueKey('main_menu_custom_background_$path'),
        imagePath: path,
        fit: BoxFit.cover,
      );
    }

    return Image.file(
      file,
      key: ValueKey('main_menu_custom_background_$path'),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
}
