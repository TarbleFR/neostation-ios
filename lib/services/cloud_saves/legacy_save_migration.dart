import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

/// These identifiers are read ONLY to preserve older installations/catalogs.
/// There is no old backend, account, plan, network request or active provider.
abstract final class LegacySaveMigration {
  static const catalogKey = 'neosync';
  static const catalogColumn = 'neosync_json';
  static Future<void> ensureCatalogColumn(Database db) async {
    final columns = db.select('PRAGMA table_info(app_systems)').map((r) => r['name']).toSet();
    if (!columns.contains('save_sync_json')) db.execute('ALTER TABLE app_systems ADD COLUMN save_sync_json TEXT');
    if (columns.contains(catalogColumn)) {
      db.execute('UPDATE app_systems SET save_sync_json = $catalogColumn WHERE save_sync_json IS NULL');
    }
    // Additive migration: keep the historical column inert. In particular do
    // NOT increment user_version: older builds destructively recreate a newer
    // schema on downgrade. Saves and library rows are not deleted or renamed.
  }
  static Future<void> removeAccountCredential() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('auth_token');
    // This key belonged exclusively to the removed cloud account. Never use
    // deleteAll: other credentials (scraper, achievements, JIT) must survive.
    try { await const FlutterSecureStorage().delete(key: 'auth_token'); } catch (_) {}
  }
}
