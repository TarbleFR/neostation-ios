import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';

void main() {
  test('moves NeoStation association from App Store to IPA source', () {
    expect(
      replacedRomFolderPaths(
        const ['/roms', '/manic-app-store'],
        '/manic-app-store',
        '/manic-ipa',
      ),
      const ['/roms', '/manic-ipa'],
    );
  });

  test('moves RetroArch association between App Store and TestFlight', () {
    expect(
      replacedRomFolderPaths(
        const ['/roms', '/retroarch-app-store'],
        '/retroarch-app-store',
        '/retroarch-testflight',
      ),
      const ['/roms', '/retroarch-testflight'],
    );
  });

  test('selecting the same linked folder keeps one source', () {
    expect(
      replacedRomFolderPaths(
        const ['/roms', '/manic-ipa'],
        '/manic-ipa',
        '/manic-ipa',
      ),
      const ['/roms', '/manic-ipa'],
    );
  });

  test('a replacement can proceed when all source slots are occupied', () {
    expect(
      replacedRomFolderPaths(
        const ['/one', '/two', '/three', '/four', '/manic-app-store'],
        '/manic-app-store',
        '/manic-ipa',
      ),
      const ['/one', '/two', '/three', '/four', '/manic-ipa'],
    );
  });
}
