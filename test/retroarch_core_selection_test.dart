import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/services/retroarch_core_preferences.dart';
import 'package:neostation/services/retroarch_internal_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'system default is live until the game has an explicit choice',
    () async {
      Future<String> selected() async =>
          (await RetroArchInternalService.resolveCore(
            systemFolderName: 'nes',
            romname: 'game.nes',
          )).identifier;
      expect(await selected(), 'fceumm');
      await RetroArchCorePreferences.setPreferredCore('nes', 'nestopia');
      expect(await selected(), 'nestopia');
      await RetroArchCorePreferences.setGameCoreOverride(
        'nes',
        'game.nes',
        'fceumm',
      );
      expect(await selected(), 'fceumm');
      await RetroArchCorePreferences.setPreferredCore('nes', 'nestopia');
      expect(await selected(), 'fceumm');
    },
  );

  test(
    'explicit default supersedes a valid legacy game choice without erasing it',
    () async {
      Future<String> selected() async =>
          (await RetroArchInternalService.resolveCore(
            systemFolderName: 'nes',
            romname: 'game.nes',
            legacyEmulatorId: 'ios_retroarch_internal:nestopia',
          )).identifier;
      expect(await selected(), 'nestopia');
      await RetroArchCorePreferences.setGameCoreOverride(
        'nes',
        'game.nes',
        null,
      );
      expect(await selected(), 'fceumm');
      await RetroArchCorePreferences.setPreferredCore('nes', 'nestopia');
      expect(await selected(), 'nestopia');
    },
  );

  test('legacy cores migrate only when compatible with the console', () async {
    final selected = await RetroArchInternalService.resolveCore(
      systemFolderName: 'snes',
      romname: 'game.sfc',
      legacyEmulatorId: 'fceumm',
      legacyCoreId: 'snes9x.libretro.framework',
    );
    expect(selected.identifier, 'snes9x');
    final ignoredLegacy = await RetroArchInternalService.resolveCore(
      systemFolderName: 'nes',
      romname: 'game.nes',
      legacyEmulatorId: 'dolphin',
      legacyCoreId: '/untrusted/dolphin.dylib',
    );
    expect(ignoredLegacy.identifier, 'fceumm');
  });

  test(
    'a stale explicit game choice fails instead of substituting a default',
    () async {
      await RetroArchCorePreferences.setGameCoreOverride(
        'nes',
        'game.nes',
        'nestopia',
      );
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getKeys().singleWhere(
        (key) => key.startsWith('retroarch_embedded_game_core_v1:'),
      );
      await prefs.setString(key, 'removed_or_experimental_core');
      await expectLater(
        RetroArchInternalService.resolveCore(
          systemFolderName: 'nes',
          romname: 'game.nes',
          legacyEmulatorId: 'fceumm',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'technical detail',
            contains('removed_or_experimental_core'),
          ),
        ),
      );
      expect(prefs.getString(key), 'removed_or_experimental_core');
    },
  );

  test('a stale explicit system choice is preserved and fails', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('retroarch_embedded_core_v1:nes', 'dolphin');
    await expectLater(
      RetroArchInternalService.resolveCore(
        systemFolderName: 'nes',
        romname: 'game.nes',
      ),
      throwsStateError,
    );
    expect(prefs.getString('retroarch_embedded_core_v1:nes'), 'dolphin');
  });

  test('same filenames remain independent across consoles', () async {
    await RetroArchCorePreferences.setGameCoreOverride(
      'nes',
      'same.zip',
      'nestopia',
    );
    final nes = await RetroArchInternalService.resolveCore(
      systemFolderName: 'nes',
      romname: 'same.zip',
    );
    final snes = await RetroArchInternalService.resolveCore(
      systemFolderName: 'snes',
      romname: 'same.zip',
    );
    expect(nes.identifier, 'nestopia');
    expect(snes.identifier, 'snes9x');
  });
}
