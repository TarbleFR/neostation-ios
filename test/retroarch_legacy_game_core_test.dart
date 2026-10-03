import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/core_emulator_model.dart';
import 'package:neostation/services/retroarch_core_preferences.dart';
import 'package:neostation/services/retroarch_game_core_selection.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  CoreEmulatorModel oldCore({
    String systemId = 'nes-id',
    String filename = 'nestopia_libretro.dylib',
    bool standalone = false,
  }) => CoreEmulatorModel(
    uniqueId: 'legacy-sql-uuid',
    osId: 1,
    systemId: systemId,
    name: 'RetroArch',
    isStandalone: standalone,
    coreFilename: filename,
    isDefault: false,
    isretroAchievementsCompatible: false,
  );

  test(
    'SQL UUID resolves its reviewed compatible filename read only',
    () async {
      String? requestedSystem;
      final chosen = await RetroArchGameCoreSelection.resolve(
        systemFolderName: 'nes',
        systemId: 'nes-id',
        romname: 'game.nes',
        legacyEmulatorId: 'legacy-sql-uuid',
        legacyCoreId: 'RetroArch playlist title',
        readLegacyEmulators: (id) async {
          requestedSystem = id;
          return [oldCore()];
        },
      );
      expect(requestedSystem, 'nes-id');
      expect(chosen.identifier, 'nestopia');
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test('foreign console UUID cannot inject a compatible filename', () async {
    final chosen = await RetroArchGameCoreSelection.resolve(
      systemFolderName: 'nes',
      systemId: 'nes-id',
      romname: 'game.nes',
      legacyEmulatorId: 'legacy-sql-uuid',
      readLegacyEmulators: (_) async => [oldCore(systemId: 'foreign-id')],
    );
    expect(chosen.identifier, 'fceumm');
  });

  test(
    'standalone and noncurated legacy rows never become embedded cores',
    () async {
      for (final row in [
        oldCore(standalone: true),
        oldCore(filename: 'dolphin_libretro.dylib'),
        oldCore(filename: 'snes9x_libretro.dylib'),
      ]) {
        final chosen = await RetroArchGameCoreSelection.resolve(
          systemFolderName: 'nes',
          systemId: 'nes-id',
          romname: 'game.nes',
          legacyEmulatorId: 'legacy-sql-uuid',
          readLegacyEmulators: (_) async => [row],
        );
        expect(chosen.identifier, 'fceumm');
      }
    },
  );

  test(
    'explicit game choice and default sentinel avoid the SQL lookup',
    () async {
      var reads = 0;
      await RetroArchCorePreferences.setPreferredCore('nes', 'nestopia');
      for (final choice in <String?>['fceumm', null]) {
        await RetroArchCorePreferences.setGameCoreOverride(
          'nes',
          'game.nes',
          choice,
        );
        final chosen = await RetroArchGameCoreSelection.resolve(
          systemFolderName: 'nes',
          systemId: 'nes-id',
          romname: 'game.nes',
          legacyEmulatorId: 'legacy-sql-uuid',
          readLegacyEmulators: (_) async {
            reads++;
            return [oldCore()];
          },
        );
        expect(chosen.identifier, choice ?? 'nestopia');
      }
      expect(reads, 0);
    },
  );

  test(
    'invalid explicit choice fails without substituting the old SQL row',
    () async {
      await RetroArchCorePreferences.setGameCoreOverride(
        'nes',
        'game.nes',
        'fceumm',
      );
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getKeys().single;
      await prefs.setString(key, 'dolphin');
      var reads = 0;
      await expectLater(
        RetroArchGameCoreSelection.resolve(
          systemFolderName: 'nes',
          systemId: 'nes-id',
          romname: 'game.nes',
          legacyEmulatorId: 'legacy-sql-uuid',
          readLegacyEmulators: (_) async {
            reads++;
            return [oldCore()];
          },
        ),
        throwsStateError,
      );
      expect(reads, 0);
      expect(prefs.getString(key), 'dolphin');
    },
  );

  test('recognized core identifiers need no SQL lookup', () async {
    final chosen = await RetroArchGameCoreSelection.resolve(
      systemFolderName: 'nes',
      systemId: 'nes-id',
      romname: 'game.nes',
      legacyEmulatorId: 'ios_retroarch_internal:nestopia',
      readLegacyEmulators: (_) async => throw StateError('must not read SQL'),
    );
    expect(chosen.identifier, 'nestopia');
  });

  test(
    'settings legacy lookup distinguishes no override from system default',
    () async {
      final absent =
          await RetroArchGameCoreSelection.resolveLegacyCoreIdentifier(
            systemFolderName: 'nes',
          );
      expect(absent, isNull);
      final mapped =
          await RetroArchGameCoreSelection.resolveLegacyCoreIdentifier(
            systemFolderName: 'nes',
            systemId: 'nes-id',
            legacyEmulatorId: 'legacy-sql-uuid',
            readLegacyEmulators: (_) async => [oldCore()],
          );
      expect(mapped, 'nestopia');
      final foreign =
          await RetroArchGameCoreSelection.resolveLegacyCoreIdentifier(
            systemFolderName: 'nes',
            systemId: 'nes-id',
            legacyEmulatorId: 'legacy-sql-uuid',
            readLegacyEmulators: (_) async => [oldCore(systemId: 'foreign-id')],
          );
      expect(foreign, isNull);
    },
  );

  test(
    'real SQL game and emulator rows stay unchanged after legacy resolution',
    () async {
      final helper = DatabaseTestHelper();
      final db = await helper.setUp();
      try {
        await db.execute('INSERT INTO app_os (id, name) VALUES (?, ?)', [
          1,
          SqliteService.getCurrentOs(),
        ]);
        await db.execute(
          'INSERT INTO app_emulators '
          '(system_id, os_id, name, unique_identifier, is_standalone, core_filename) '
          'VALUES (?, ?, ?, ?, ?, ?)',
          [
            'nes-id',
            1,
            'RetroArch',
            'legacy-sql-uuid',
            0,
            'nestopia_libretro.dylib',
          ],
        );
        await db.execute(
          'INSERT INTO user_roms '
          '(filename, rom_path, app_system_id, app_emulator_unique_id, app_emulator_os_id) '
          'VALUES (?, ?, ?, ?, ?)',
          ['game.nes', '/roms/game.nes', 'nes-id', 'legacy-sql-uuid', 1],
        );
        final gameBefore = await db.query('user_roms');
        final emulatorBefore = await db.query('app_emulators');
        final chosen = await RetroArchGameCoreSelection.resolve(
          systemFolderName: 'nes',
          systemId: 'nes-id',
          romname: 'game.nes',
          legacyEmulatorId: 'legacy-sql-uuid',
        );
        expect(chosen.identifier, 'nestopia');
        expect(await db.query('user_roms'), gameBefore);
        expect(await db.query('app_emulators'), emulatorBefore);
      } finally {
        await helper.tearDown();
      }
    },
  );
}
