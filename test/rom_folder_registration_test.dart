import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late SqliteConfigProvider provider;
  late Directory temp;

  setUp(() async {
    db = await helper.setUp();
    for (final column in [
      'legend_hidden INTEGER', 'hide_tab_achievements INTEGER',
      'hide_tab_scraper INTEGER', 'hide_tab_search INTEGER',
      'game_grid_columns TEXT', 'game_carousel_card_style TEXT',
      'dock_apps TEXT', 'dock_enabled INTEGER', 'dock_slot_count INTEGER',
      'now_playing_dim_delay INTEGER', 'now_playing_dim_level INTEGER',
      'fanart_dim_level INTEGER',
    ]) {
      await db.execute('ALTER TABLE user_config ADD COLUMN $column');
    }
    provider = SqliteConfigProvider();
    temp = await Directory.systemTemp.createTemp('retroarch-registration-');
  });
  tearDown(() async {
    provider.dispose();
    await helper.tearDown();
    await temp.delete(recursive: true);
  });

  test('seven old roots do not block a new RetroArch folder or its games', () async {
    final old = List.generate(7, (i) => '${temp.path}/old-container-$i');
    await provider.updateRomFolders(old);
    final root = Directory('${temp.path}/Bibliothe\u0300ques ');
    final folder = Directory('${root.path}/snes')..createSync(recursive: true);
    final rom = File('${folder.path}/Game.smc')..writeAsStringSync('fixture');
    await db.insert('app_systems', {
      'id': 'snes', 'real_name': 'SNES', 'folder_name': 'snes',
    });
    await db.insert('app_system_extensions', {'system_id': 'snes', 'extension': 'smc'});
    await provider.addRomFolder(root.path, scan: false);
    expect(provider.config.romFolders, [...old, root.path],
      reason: 'NEW_RETROARCH_ROOT_NOT_REGISTERED');
    expect(await SqliteService.getUserRomFolders(), [...old, root.path]);

    const system = SystemModel(id: 'snes', realName: 'SNES', folderName: 'snes',
      iconImage: '', color: '#000000', recursiveScan: true);
    await SqliteDatabaseService.scanSystemRoms(system, await SqliteService.getUserRomFolders());
    expect((await db.query('user_roms')).single['rom_path'], rom.path);
    await db.execute('UPDATE user_roms SET is_favorite=1, play_time=321');
    await provider.addRomFolder(root.path, scan: false);
    await SqliteDatabaseService.scanSystemRoms(system, await SqliteService.getUserRomFolders());
    final rows = await db.query('user_roms');
    expect(rows, hasLength(1));
    expect(rows.single['is_favorite'], 1);
    expect(rows.single['play_time'], 321);
    expect(await SqliteService.getUserRomFolders(), [...old, root.path]);
  });

  test('each additional console root persists without a fixed count limit', () async {
    final roots = List.generate(130, (i) => '${temp.path}/console-$i');
    for (final root in roots) {
      await provider.addRomFolder(root, scan: false);
    }
    expect(provider.config.romFolders, roots);
    expect(await SqliteService.getUserRomFolders(), roots);
  });

  test('failed persistence cannot masquerade as an active folder', () async {
    await provider.addRomFolder('${temp.path}/existing', scan: false);
    final before = List<String>.of(provider.config.romFolders);
    await db.execute('''CREATE TRIGGER reject_new_root BEFORE INSERT ON user_rom_folders
      WHEN NEW.path LIKE '%/rejected' BEGIN SELECT RAISE(ABORT, 'fixture_write_failure'); END''');
    await provider.addRomFolder('${temp.path}/rejected', scan: false);
    expect(provider.error, contains('fixture_write_failure'));
    expect(provider.config.romFolders, before);
    expect(await SqliteService.getUserRomFolders(), before);
  });
}
