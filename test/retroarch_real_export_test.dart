// Optional contract check with the supplied playlists and an offline DB copy.
// No live phone, folder access, core execution or scanner completion is inferred.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/retroarch_library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final source = Platform.environment['NEOSTATION_AUDIT_DATABASE'];
  final playlists = Platform.environment['NEOSTATION_AUDIT_PLAYLISTS'];
  test(
    '4842 real records: repeated exports leave every game row intact and 007 sends one exact URL',
    () async {
      final temp = await Directory.systemTemp.createTemp('retroarch-contract-');
      addTearDown(() => temp.delete(recursive: true));
      final copy = await File(source!).copy('${temp.path}/copy.sqlite');
      final db = sqlite.sqlite3.open(copy.path);
      addTearDown(db.close);
      SqliteService.setTestingDatabase(DatabaseAdapter(db));
      SharedPreferences.setMockInitialValues({});
      final before = db
          .select('SELECT * FROM user_roms ORDER BY rowid')
          .map((r) => Map<String, Object?>.from(r))
          .toList();
      expect(before, hasLength(8923));
      final archive = ZipDecoder().decodeBytes(
        await File(playlists!).readAsBytes(),
      );
      final entries = <Map<String, dynamic>>[];
      for (final file in archive.files) {
        if (!file.name.startsWith('playlists/') ||
            file.name.split('/').length != 2 ||
            !file.name.endsWith('.lpl'))
          continue;
        final data = jsonDecode(utf8.decode(file.content as List<int>)) as Map;
        final name = file.name.split('/').last;
        final items = data['items'] as List;
        for (var i = 0; i < items.length; i++) {
          final item = items[i] as Map;
          final full = item['path'] as String;
          final filename = full.contains('#')
              ? full.substring(full.indexOf('#') + 1)
              : full.split('/').last;
          entries.add({
            'filename': filename,
            'titleId': filename,
            'titleName': item['label'],
            'system': name.substring(0, name.length - 4),
            'gameId': '$name:$i',
          });
        }
      }
      expect(entries, hasLength(4842));
      final uri = Uri(
        scheme: 'neostation',
        host: 'retroarch',
        queryParameters: {
          'games': base64Url
              .encode(utf8.encode(jsonEncode(entries)))
              .replaceAll('=', ''),
        },
      );
      for (var i = 0; i < 2; i++)
        expect(await RetroArchLibraryService.handleIncomingUri(uri), isTrue);
      expect(
        await Future.wait([
          RetroArchLibraryService.handleIncomingUri(uri),
          RetroArchLibraryService.handleIncomingUri(uri),
        ]),
        [true, true],
      );
      expect(
        db
            .select('SELECT * FROM user_roms ORDER BY rowid')
            .map((r) => Map<String, Object?>.from(r))
            .toList(),
        before,
      );
      const filename = '007 - The World Is Not Enough (Europe) (En,Fr,De).n64';
      final matching = before.where(
        (r) =>
            r['filename'] == filename &&
            r['app_system_id'] == 'n64' &&
            !(r['rom_path'] as String).startsWith('retroarch-library://'),
      );
      expect(matching, hasLength(1));
      final sent = <String>[];
      final attempt = await RetroArchLibraryService.launchGameWithDiagnostics(
        matching.single['rom_path'] as String,
        openUrl: (url) async {
          sent.add(url);
          expect(Uri.parse(url).host, 'game');
          expect(Uri.parse(url).pathSegments, [filename]);
          return true;
        },
      );
      expect(sent, hasLength(1));
      expect(attempt.stage, RetroArchLaunchStage.handoffAccepted);
      expect(
        db
            .select('SELECT * FROM user_roms ORDER BY rowid')
            .map((r) => Map<String, Object?>.from(r))
            .toList(),
        before,
      );
    },
    skip: source == null || playlists == null
        ? 'Requires offline copies of the supplied data.sqlite and playlists.zip.'
        : false,
  );
}
