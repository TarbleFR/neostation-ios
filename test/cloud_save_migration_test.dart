import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/services/cloud_saves/legacy_save_migration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('additive catalog migration is idempotent and preserves library and version', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    db.execute('PRAGMA user_version = 112');
    db.execute('CREATE TABLE app_systems (id INTEGER PRIMARY KEY, neosync_json TEXT)');
    db.execute('CREATE TABLE user_roms (id INTEGER PRIMARY KEY, name TEXT)');
    db.execute("INSERT INTO app_systems VALUES (1, '{\"sync\":true}')");
    db.execute("INSERT INTO user_roms VALUES (1, 'The Hobbit')");
    await LegacySaveMigration.ensureCatalogColumn(db);
    expect(db.select('SELECT save_sync_json FROM app_systems').single['save_sync_json'], '{"sync":true}');
    db.execute("UPDATE app_systems SET save_sync_json = '{\"sync\":false}'");
    await LegacySaveMigration.ensureCatalogColumn(db);
    expect(db.select('SELECT save_sync_json FROM app_systems').single['save_sync_json'], '{"sync":false}');
    expect(db.select('SELECT neosync_json FROM app_systems').single['neosync_json'], '{"sync":true}');
    expect(db.select('SELECT name FROM user_roms').single['name'], 'The Hobbit');
    expect(db.select('PRAGMA user_version').single['user_version'], 112);
  });
  test('fresh catalog without a historical column is supported', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    db.execute('CREATE TABLE app_systems (id INTEGER PRIMARY KEY)');
    await LegacySaveMigration.ensureCatalogColumn(db);
    await LegacySaveMigration.ensureCatalogColumn(db);
    expect(db.select('PRAGMA table_info(app_systems)').map((r)=>r['name']), contains('save_sync_json'));
  });
  test('only retired account token is removed; unrelated secrets and grants survive', () async {
    SharedPreferences.setMockInitialValues({'auth_token':'retired','ra_username':'user','screenscraper_password':'kept','external_folder':'kept'});
    const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async { calls.add(call); return null; });
    addTearDown(()=>TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await LegacySaveMigration.removeAccountCredential();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth_token'), isNull);
    expect(prefs.getString('ra_username'), 'user');
    expect(prefs.getString('screenscraper_password'), 'kept');
    expect(prefs.getString('external_folder'), 'kept');
    expect(calls.map((c)=>c.method), ['delete']);
    expect((calls.single.arguments as Map)['key'], 'auth_token');
  });
  test('native bookmark compatibility reads old grants without removing them', () {
    final native = File('packages/external_folder_access/ios/Classes/ExternalFolderAccessPlugin.swift').readAsStringSync();
    expect(native, contains('"armsx2-save-folder": "neosync-armsx2-saves"'));
    expect(native, contains('"melonx-save-folder": "neosync-melonx-saves"'));
    final migration = native.substring(native.indexOf('let oldKeys ='), native.indexOf('guard\n            let bookmarkData',native.indexOf('let oldKeys =')));
    expect(migration, contains('== nil'));
    expect(migration, isNot(contains('removeObject')));
  });
}
