import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/dolphin_internal_v2_service.dart';
import 'package:neostation/services/dolphin_system_files.dart';
import 'package:path/path.dart' as p;

// These fixtures exercise routing and exclusion only. Native validation still
// checks real installed contents; synthetic metadata is not a bootable NAND.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const host = MethodChannel('neostation/dolphin_internal');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  late Directory dolphin;
  late Directory nand;
  bool running = false;
  bool accepted = true;
  final calls = <String>[];
  Map<dynamic, dynamic>? arguments;

  Future<void> installMetadata() async {
    // Wii IOS is provided in HLE; the user's menu needs no installed IOS TMD.
    for (final id in [0x0000000100000002]) {
      final title = id.toRadixString(16).padLeft(16, '0');
      final file = File(p.join(nand.path, 'title', title.substring(0, 8),
          title.substring(8), 'content', 'title.tmd'));
      await file.parent.create(recursive: true);
      final bytes = Uint8List(0x1e4 + 36);
      final data = ByteData.sublistView(bytes);
      data.setUint32(0, 0x10001, Endian.big);
      data.setUint64(0x184, 0x0000000100000050, Endian.big);
      data.setUint64(0x18c, id, Endian.big);
      data.setUint16(0x1de, 1, Endian.big);
      data.setUint32(0x1e4, 1, Endian.big);
      await file.writeAsBytes(bytes);
    }
  }

  Future<void> notifyStopped(String token) async {
    final completed = Completer<void>();
    // ignore: deprecated_member_use
    await messenger.handlePlatformMessage(host.name, host.codec.encodeMethodCall(
      MethodCall('saveSessionStopped', {'token': token, 'savesFlushed': true}),
    ), (_) => completed.complete());
    await completed.future;
  }

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('dolphin-wii-menu-');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    messenger.setMockMethodCallHandler(host, (call) async {
      calls.add(call.method);
      if (call.method == 'isRunning') return running;
      if (call.method != 'launchGame') {
        throw PlatformException(code: 'unexpectedNativeCall', message: call.method);
      }
      arguments = Map<dynamic, dynamic>.from(call.arguments as Map);
      return {
        'success': accepted,
        'message': 'Mock native engine, no real emulation',
        if (!accepted) 'failedStage': 'wii.menu_missing',
        for (final gate in [
          'stikjitConnected', 'pidAttached', 'legacyHandshakeValidated',
          'executableMemoryValidated', 'jitArm64Initialized',
          'metalInitialized', 'imageAccepted', 'gameSubmitted',
        ]) gate: accepted,
      };
    });
    await File(p.join(root.path, 'pairingfile.plist'))
        .writeAsString(List.filled(256, 'x').join());
    await DolphinInternalV2Service.ensureLayout();
    dolphin = await DolphinInternalV2Service.rootDirectory();
    nand = Directory(p.join(dolphin.path, 'User', 'Wii'));
  });
  setUp(() { running = false; accepted = true; arguments = null; calls.clear(); });
  tearDownAll(() async {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(host, null);
    host.setMethodCallHandler(null);
    await root.delete(recursive: true);
  });

  test('a keys file alone cannot request a native Wii Menu launch', () async {
    await File(p.join(nand.path, 'keys.bin')).writeAsString('not a NAND');
    await expectLater(DolphinInternalV2Service.launchWiiMenu(),
        throwsA(isA<DolphinSystemFilesException>().having((e) => e.code, 'code', 'wiiMenuMissing')));
    expect(calls, ['isRunning']);
  });

  test('Wii Menu uses explicit native boot kind and all JIT gates without a ROM', () async {
    await installMetadata();
    final report = await DolphinInternalV2Service.launchWiiMenu();
    expect(report.ready, isTrue);
    expect(arguments!['system'], 'wii');
    expect(arguments!['bootKind'], 'wiiSystemMenu');
    expect(arguments!.containsKey('gamePath'), isFalse);
    expect(arguments!['gameTitle'], isNotEmpty);
    expect(arguments!['pairingFilePath'], endsWith('pairingfile.plist'));
    expect(arguments!['saveSessionToken'], isNotEmpty);
    expect(calls, ['isRunning', 'launchGame']);
    final marker = File(p.join(dolphin.path, 'CrashMarkers', 'active-session.json'));
    final payload = jsonDecode(await marker.readAsString()) as Map;
    expect(payload['bootKind'], 'wiiSystemMenu');
    expect(payload.containsKey('gamePath'), isFalse);
    await notifyStopped(arguments!['saveSessionToken'] as String);
    expect(await marker.exists(), isFalse);
  });

  test('native missing content refusal is preserved and releases the launch lock', () async {
    await installMetadata();
    accepted = false;
    final report = await DolphinInternalV2Service.launchWiiMenu();
    expect(report.ready, isFalse);
    expect(report.failedStage, 'wii.menu_missing');
    expect(await File(p.join(dolphin.path, 'CrashMarkers', 'active-session.json')).exists(), isFalse);
    accepted = true;
    expect((await DolphinInternalV2Service.launchWiiMenu()).ready, isTrue);
    await notifyStopped(arguments!['saveSessionToken'] as String);
  });

  test('a running console prevents a Wii Menu launch', () async {
    running = true;
    await expectLater(DolphinInternalV2Service.launchWiiMenu(),
        throwsA(isA<DolphinSystemFilesException>().having((e) => e.code, 'code', 'busy')));
    expect(calls, ['isRunning']);
  });

  test('Wii Menu does not inherit an ordinary game NeoSync upload callback', () async {
    await installMetadata();
    final library = await DolphinInternalV2Service.libraryDirectory('gc');
    final game = await File(p.join(library.path, 'fixture.rvz')).writeAsString('mock game');
    var uploaded = 0;
    expect((await DolphinInternalV2Service.launch(folderName: 'gc', gamePath: game.path,
        onSessionStopped: () async { uploaded++; })).ready, isTrue);
    final gameToken = arguments!['saveSessionToken'] as String;
    await notifyStopped(gameToken);
    expect(uploaded, 1);
    expect((await DolphinInternalV2Service.launchWiiMenu()).ready, isTrue);
    final menuToken = arguments!['saveSessionToken'] as String;
    await notifyStopped(gameToken);
    await notifyStopped(menuToken);
    expect(uploaded, 1);
  });

  test('Wii Menu waits for an in-progress save access transaction', () async {
    await installMetadata();
    final entered = Completer<void>();
    final release = Completer<void>();
    final saving = DolphinInternalV2Service.withSaveAccess((_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final launching = DolphinInternalV2Service.launchWiiMenu();
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call == 'launchGame'), isEmpty);
    release.complete();
    await saving;
    expect((await launching).ready, isTrue);
    await notifyStopped(arguments!['saveSessionToken'] as String);
  });
}
