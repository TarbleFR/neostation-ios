import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/neo_assets_service.dart';

void main() {
  group('NeoAssetsService external System Art routing', () {
    test('routes RiiSU backgrounds to the original RiiSU repository', () {
      expect(
        NeoAssetsService.getBackgroundUrl('RiiSU', 'ps3'),
        'https://raw.githubusercontent.com/mult1v4c/RiiSU/main/themes/RiiSU/backgrounds/ps3.webp',
      );
      expect(
        NeoAssetsService.getBackgroundUrl('RiiSU', 'switch', ext: 'gif'),
        'https://raw.githubusercontent.com/mult1v4c/RiiSU/main/themes/RiiSU/backgrounds/switch.gif',
      );
    });

    test('routes RiiSU metadata to the original RiiSU repository', () {
      expect(
        NeoAssetsService.getThemeMetadataUrl('RiiSU'),
        'https://raw.githubusercontent.com/mult1v4c/RiiSU/main/themes/RiiSU/theme.json',
      );
    });

    test('keeps existing packs on the default NeoStation assets host', () {
      expect(
        NeoAssetsService.getBackgroundUrl('NeoStation', 'ps3'),
        'https://raw.githubusercontent.com/misobadev/neostation-assets/main/themes/NeoStation/backgrounds/ps3.webp',
      );
      expect(
        NeoAssetsService.getThemeMetadataUrl('NeoStation'),
        'https://raw.githubusercontent.com/misobadev/neostation-assets/main/themes/NeoStation/theme.json',
      );
    });
  });
}
