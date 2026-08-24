import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/image_utils.dart';

void main() {
  group('ImageUtils background media', () {
    test('recognizes static, GIF and video background formats', () {
      expect(ImageUtils.isSupportedBackground('/tmp/background.webp'), isTrue);
      expect(ImageUtils.isSupportedBackground('/tmp/background.PNG'), isTrue);
      expect(ImageUtils.isActualGif('/tmp/background.GIF'), isTrue);
      expect(ImageUtils.isVideo('/tmp/background.mp4'), isTrue);
      expect(ImageUtils.isVideo('/tmp/background.M4V'), isTrue);
      expect(ImageUtils.isVideo('/tmp/background.mov'), isTrue);
      expect(ImageUtils.isSupportedBackground('/tmp/background.txt'), isFalse);
    });

    test('animated background routing includes GIF and video', () {
      expect(ImageUtils.isAnimatedBackground('/tmp/background.gif'), isTrue);
      expect(ImageUtils.isAnimatedBackground('/tmp/background.mp4'), isTrue);
      expect(ImageUtils.isAnimatedBackground('/tmp/background.webp'), isFalse);
    });
  });
}
