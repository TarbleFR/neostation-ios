import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/ios_emulator_preference_service.dart';

void main() {
  const manicRoot = '/On My iPhone/ManicEMU/Documents';
  const retroArchRoot = '/On My iPhone/RetroArch/Documents';

  Set<IosLibraryEmulator> resolve({
    required List<String> romPaths,
    Map<String, IosLibraryEmulator> gameChoices = const {},
    IosLibraryEmulator primary = IosLibraryEmulator.retroArch,
  }) => IosEmulatorPreferenceService.resolveSystemAssociations(
    romPaths: romPaths,
    gameChoices: gameChoices,
    manicEmuFolder: manicRoot,
    retroArchFolder: retroArchRoot,
    primary: primary,
  );

  test('a 3DS library linked only to Manic EMU resolves only Manic EMU', () {
    expect(
      resolve(
        romPaths: const [
          '$manicRoot/Datas/Bravely Default.3ds',
          '$manicRoot/Datas/Mario Kart 7.cia',
        ],
      ),
      const {IosLibraryEmulator.manicEmu},
    );
  });

  test('an explicit per-game choice takes precedence over folder ownership', () {
    const romPath = '$manicRoot/Datas/Bravely Default.3ds';
    expect(
      resolve(
        romPaths: const [romPath],
        gameChoices: const {
          romPath: IosLibraryEmulator.retroArch,
        },
      ),
      const {IosLibraryEmulator.retroArch},
    );
  });

  test('a mixed system library exposes both iOS emulator applications', () {
    expect(
      resolve(
        romPaths: const [
          '$manicRoot/Datas/Bravely Default.3ds',
          '$retroArchRoot/roms/3ds/Mario Kart 7.3ds',
        ],
      ),
      const {
        IosLibraryEmulator.manicEmu,
        IosLibraryEmulator.retroArch,
      },
    );
  });

  test('Manic-only association hides the seeded RetroArch application row', () {
    const associations = {IosLibraryEmulator.manicEmu};

    expect(
      IosEmulatorPreferenceService.shouldShowIosApplication(
        urlScheme: 'retroarch',
        associations: associations,
      ),
      isFalse,
    );
    expect(
      IosEmulatorPreferenceService.shouldShowIosApplication(
        urlScheme: 'manicemu',
        associations: associations,
      ),
      isTrue,
    );
    expect(
      IosEmulatorPreferenceService.shouldShowIosApplication(
        urlScheme: 'armsx2',
        associations: associations,
      ),
      isTrue,
    );
  });

  test('an unattributed or empty library falls back to the primary choice', () {
    expect(
      resolve(
        romPaths: const ['/NeoStation/roms/3ds/Unknown.3ds'],
        primary: IosLibraryEmulator.manicEmu,
      ),
      const {IosLibraryEmulator.manicEmu},
    );
    expect(
      resolve(
        romPaths: const [],
        primary: IosLibraryEmulator.manicEmu,
      ),
      const {IosLibraryEmulator.manicEmu},
    );
  });

  test('the informational iOS emulator row cannot mutate database defaults', () {
    final source = File(
      'lib/widgets/system_emulator_settings_dialog.dart',
    ).readAsStringSync();
    final methodStart = source.indexOf('void _setSelectedAsDefault() {');
    expect(methodStart, greaterThanOrEqualTo(0));

    final firstSelectionCheck = source.indexOf(
      'if (_totalEmulators == 0',
      methodStart,
    );

    expect(firstSelectionCheck, greaterThan(methodStart));
    expect(
      source.substring(methodStart, firstSelectionCheck),
      contains('if (Platform.isIOS) return;'),
    );
  });
}
