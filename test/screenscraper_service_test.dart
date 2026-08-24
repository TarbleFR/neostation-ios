import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScreenScraperService build-time config', () {
    test('should have developer id from environment or empty', () {
      // In test environment, SCREENSCRAPER_DEV_ID is not set,
      // so it should default to empty string.
      const devId = String.fromEnvironment('SCREENSCRAPER_DEV_ID');
      expect(devId, '');
    });

    test('should have developer password from environment or empty', () {
      const devPassword = String.fromEnvironment('SCREENSCRAPER_DEV_PASSWORD');
      expect(devPassword, '');
    });
  });
}
