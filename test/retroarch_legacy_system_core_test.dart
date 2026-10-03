import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/retroarch_core_preferences.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  setUp(() async {
    db = await helper.setUp();
    await db.execute('INSERT INTO app_os (id,name) VALUES (?,?)', [
      1,
      SqliteService.getCurrentOs(),
    ]);
    await db.execute(
      'INSERT INTO app_systems (id,real_name,folder_name) VALUES (?,?,?)',
      ['nes', 'Nintendo Entertainment System', 'nes'],
    );
    await db.execute(
      '''INSERT INTO app_emulators
      (system_id,os_id,name,unique_identifier,is_standalone,core_filename,is_default)
      VALUES (?,?,?,?,?,?,?)''',
      ['nes', 1, 'FCEUmm', 'old-default', 0, 'fceumm_libretro.so', 1],
    );
    await db.execute(
      '''INSERT INTO app_emulators
      (system_id,os_id,name,unique_identifier,is_standalone,core_filename,is_default)
      VALUES (?,?,?,?,?,?,?)''',
      ['nes', 1, 'Nestopia', 'old-user-choice', 0, 'nestopia_libretro.so', 0],
    );
    await db.execute(
      'INSERT INTO user_emulator_config (emulator_unique_id,is_user_default) VALUES (?,?)',
      ['old-user-choice', 1],
    );
  });
  tearDown(helper.tearDown);

  test(
    'old explicit SQL core wins the seeded default without rewriting data',
    () async {
      final before = await db.rawQuery('SELECT * FROM user_emulator_config');
      final chosen = await RetroArchCorePreferences.preferredCore(
        'nes',
        readLegacyCore: RetroArchCorePreferences.readLegacyCoreIdentifier,
      );
      expect(chosen.identifier, 'nestopia');
      expect(await RetroArchCorePreferences.systemCoreOverride('nes'), isNull);
      expect(await db.rawQuery('SELECT * FROM user_emulator_config'), before);
      await RetroArchCorePreferences.setPreferredCore('nes', 'fceumm');
      expect(
        (await RetroArchCorePreferences.preferredCore(
          'nes',
          readLegacyCore: RetroArchCorePreferences.readLegacyCoreIdentifier,
        )).identifier,
        'fceumm',
      );
      expect(await db.rawQuery('SELECT * FROM user_emulator_config'), before);
    },
  );

  test(
    'a standalone SQL choice is never interpreted as a libretro core',
    () async {
      await db.execute(
        'UPDATE app_emulators SET is_standalone = 1 WHERE unique_identifier = ?',
        ['old-user-choice'],
      );
      expect(
        await RetroArchCorePreferences.readLegacyCoreIdentifier('nes'),
        isNull,
      );
    },
  );
}
