import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/models/user.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';
import 'package:neostation/widgets/neo_sync_status_icon.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SignedIn extends AuthService {
  @override bool get isLoggedIn => true;
  @override User get currentUser => User.fromJson({'id': 'account-one'});
}

class _PreviouslyCheckedProvider extends NeoSyncProvider {
  _PreviouslyCheckedProvider(super.service);
  final states = <String, GameSyncState>{};
  @override GameSyncState? getGameSyncState(String gameId) => states[gameId];
}

GameModel game(String system) => GameModel.fromJson({
  'romname': '$system-game', 'realname': system, 'name': system,
  'system_folder_name': system, 'cloud_sync_enabled': true,
});

Future<void> showIcons(WidgetTester tester, ISyncProvider adapter, List<String> systems) async {
  await tester.pumpWidget(ScreenUtilInit(
    designSize: const Size(1920, 1080),
    builder: (context, child) => MaterialApp(home: Scaffold(body: Row(children: [
      for (final system in systems) NeoSyncStatusIcon(
        key: ValueKey(system),
        system: SystemModel(folderName: system, realName: system, iconImage: '',
          color: '#000000', screenscraperId: 1),
        game: game(system), syncProvider: adapter,
      ),
    ]))),
  ));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'auth_token': 'account-one'});
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'account-one'});
  });

  testWidgets('one unresolved historical file does not turn every emulator red', (tester) async {
    final provider = _PreviouslyCheckedProvider(NeoSyncService())..setAuthService(_SignedIn());
    final adapter = NeoSyncAdapter(provider);
    addTearDown(adapter.dispose);
    addTearDown(provider.dispose);
    const systems = ['snes', 'psp', 'ps2', 'ps3', 'switch', 'gc', 'wii'];
    for (final system in systems) {
      provider.states[game(system).romname] = GameSyncState(gameId: game(system).romname,
        gameName: system, status: GameSyncStatus.upToDate, cloudEnabled: true,
        lastSync: DateTime.utc(2026, 9, 5));
    }
    await http.runWithClient(() => provider.loadOnlineFiles(), () => MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v2/files');
      return http.Response(jsonEncode({'files': request.url.path == '/api/v2/files'
        ? [{'id': 'native-save', 'file_name': 'Game.srm'},
           {'id': 'unknown-origin', 'file_name': 'SYSDATA'}] : []}), 200);
    }));
    expect(provider.saveAuditMessage, contains('1 à identifier'));
    expect(provider.error, isNull);
    expect(adapter.status, SyncProviderStatus.connected);
    await showIcons(tester, adapter, systems);
    expect(find.byIcon(Symbols.check_circle_outline_rounded), findsNWidgets(systems.length));
    expect(find.byIcon(Symbols.error_outline_rounded), findsNothing);
  });

  testWidgets('a real cloud listing outage remains visible for unchecked saves', (tester) async {
    final provider = _PreviouslyCheckedProvider(NeoSyncService())..setAuthService(_SignedIn());
    final adapter = NeoSyncAdapter(provider);
    addTearDown(adapter.dispose);
    addTearDown(provider.dispose);
    await http.runWithClient(() => provider.loadOnlineFiles(),
      () => MockClient((_) async => http.Response('Unavailable', 503)));
    expect(provider.error, contains('503'));
    expect(provider.saveAuditMessage, contains('interrompue'));
    expect(adapter.status, SyncProviderStatus.error);
    await showIcons(tester, adapter, ['psp']);
    expect(find.byIcon(Symbols.error_outline_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.check_circle_outline_rounded), findsNothing);
  });

  test('typed v2 inventory needs no unavailable legacy deployment', () async {
    final provider = NeoSyncProvider(NeoSyncService())..setAuthService(_SignedIn());
    addTearDown(provider.dispose);
    var requests = 0;
    await http.runWithClient(() => provider.loadOnlineFiles(),
      () => MockClient((request) async {
        requests++;
        expect(request.url.host, 'sync.neosync.cloud');
        expect(request.url.path, '/api/v2/files');
        return http.Response(jsonEncode({'files': [
          {'id': 'n64-save', 'file_path': 'Mario.srm', 'type': 'save',
            'system_name': 'n64', 'emulator': 'retroarch.mupen64plus-next',
            'game_name': 'Mario', 'file_size': 4,
            'file_hash': '08d6c05a21512a79a1dfeb9d2a8f262f'},
        ]}), 200);
      }));
    expect(requests, 1);
    expect(provider.onlineFiles, hasLength(1));
    expect(provider.onlineFiles.single.sourceSavePath,
        'v2/saves/n64/retroarch.mupen64plus-next/game/Mario/Mario.srm');
    expect(provider.saveAuditMessage, isNull);
    expect(provider.error, isNull);
  });

  testWidgets('each game keeps its own pending or failed state during another error', (tester) async {
    final provider = _PreviouslyCheckedProvider(NeoSyncService())..setAuthService(_SignedIn());
    final adapter = NeoSyncAdapter(provider);
    addTearDown(adapter.dispose);
    addTearDown(provider.dispose);
    for (final item in {'snes': GameSyncStatus.upToDate, 'psp': GameSyncStatus.localOnly,
      'ps2': GameSyncStatus.cloudOnly, 'switch': GameSyncStatus.error}.entries) {
      provider.states[game(item.key).romname] = GameSyncState(gameId: game(item.key).romname,
        gameName: item.key, status: item.value, cloudEnabled: true);
    }
    await http.runWithClient(() => provider.loadFiles(),
      () => MockClient((_) async => http.Response('Unavailable', 503)));
    expect(adapter.status, SyncProviderStatus.error);
    await showIcons(tester, adapter, ['snes', 'psp', 'ps2', 'switch']);
    expect(find.byIcon(Symbols.check_circle_outline_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.cloud_upload_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.cloud_download_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.error_outline_rounded), findsOneWidget);
  });
}
