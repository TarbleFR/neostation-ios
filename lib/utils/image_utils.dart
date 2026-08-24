import 'package:path/path.dart' as path;

/// Utility functions for image and background-media file processing.
class ImageUtils {
  /// Static image formats supported by custom system backgrounds.
  static const List<String> imageExtensions = [
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
  ];

  /// Local video formats supported by custom system backgrounds.
  ///
  /// MP4/M4V/MOV map cleanly to the native Apple/Android media stacks used by
  /// video_player and cover the MPEG-4 use case without accepting arbitrary
  /// containers that may not decode consistently across NeoStation targets.
  static const List<String> videoExtensions = ['mp4', 'm4v', 'mov'];

  /// All formats exposed by the background picker.
  static const List<String> backgroundExtensions = [
    ...imageExtensions,
    ...videoExtensions,
  ];

  /// True only for a real GIF file.
  static bool isActualGif(String? filePath) {
    if (filePath == null || filePath.isEmpty) return false;
    return path.extension(filePath).toLowerCase() == '.gif';
  }

  /// Checks whether [filePath] points to one of the supported video containers.
  static bool isVideo(String? filePath) {
    if (filePath == null || filePath.isEmpty) return false;
    final extension = path.extension(filePath).toLowerCase().replaceFirst('.', '');
    return videoExtensions.contains(extension);
  }

  /// Legacy animated-background routing predicate.
  ///
  /// Existing background call sites historically route `isGif == true` through
  /// `ShaderGifWidget`. That widget now supports video as well, so keeping this
  /// predicate animation-aware adds video support everywhere without duplicating
  /// media-type routing across cards, previews and the secondary display.
  static bool isGif(String? filePath) =>
      isActualGif(filePath) || isVideo(filePath);

  /// True for animated background media that needs a dedicated renderer.
  static bool isAnimatedBackground(String? filePath) => isGif(filePath);

  /// True when [filePath] can be selected as a system background.
  static bool isSupportedBackground(String? filePath) {
    if (filePath == null || filePath.isEmpty) return false;
    final extension = path.extension(filePath).toLowerCase().replaceFirst('.', '');
    return backgroundExtensions.contains(extension);
  }
}
