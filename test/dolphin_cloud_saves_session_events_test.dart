import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/dolphin_internal_v2_service.dart';
import 'package:path/path.dart' as p;

/// Exercises only the Dart/native message contract with a mocked native engine.
/// A successful fixture response is NOT evidence of JIT, cloud or device support.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const host = MethodChannel('neostation/dolphin_internal');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  late String gamePath;
  String? nativeToken;
  Map<dynamic, dynamic>? nativeLaunchArguments;
  bool launchAccepted = true;
  final calls = <String>[];

  Future<void> notifyStopped(String? token, {bool flushed = true}) async {
    final acknowledged = Completer<void>();
    // Use the inbound platform channel, not a call to a private handler.
    // ignore: deprecated_member_use
    await messenger.handlePlatformMessage(
      host.name,
      host.codec.encodeMethodCall(MethodCall('saveSessionStopped', {
        'token': token, 'savesFlushed': flushed, 'reason': 'unit-test',
      })),
      (reply) {
        try {
          if (reply != null) host.codec.decodeEnvelope(reply);
          acknowledged.complete();
        } catch (error, stack) {
          acknowledged.completeError(error, stack);
        }
      },
    );
    await acknowledged.future;
  }

  Future<DolphinLaunchReport> launch(Future<void> Function() onStopped) =>
      DolphinInternalV2Service.launch(
        folderName: 'wii', gamePath: gamePath, onSessionStopped: onStopped,
      );

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('dolphin-cloud-saves-events-');
    messenger.setMockMethodCallHandler(paths, (call) async => root.path);
    messenger.setMockMethodCallHandler(host, (call) async {
      calls.add(call.method);
      if (call.method == 'isRunning') return false;
      if (call.method == 'launchGame') {
        nativeLaunchArguments = call.arguments as Map;
        nativeToken = (call.arguments as Map)['saveSessionToken'] as String;
        return {
          'success': launchAccepted,
          'message': 'Mock native launch; no real emulation',
          for (final gate in [
            'stikjitConnected', 'pidAttached', 'legacyHandshakeValidated',
            'executableMemoryValidated', 'jitArm64Initialized',
            'metalInitialized', 'imageAccepted', 'gameSubmitted',
          ]) gate: launchAccepted,
        };
      }
      throw PlatformException(code: 'unexpectedNativeCall', message: call.method);
    });
    // Harmless app-owned fixtures; no device pairing record or game is used.
    await File(p.join(root.path, 'pairingfile.plist'))
        .writeAsString(List.filled(256, 'x').join());
    await DolphinInternalV2Service.ensureLayout();
    final library = await DolphinInternalV2Service.libraryDirectory('wii');
    gamePath = (await File(p.join(library.path, 'fixture.rvz'))
        .writeAsString('Native engine is mocked')).path;
  });
  setUp(() { nativeToken = null; nativeLaunchArguments = null; launchAccepted = true; calls.clear(); });
  tearDownAll(() async {
    messenger.setMockMethodCallHandler(host, null);
    messenger.setMockMethodCallHandler(paths, null);
    host.setMethodCallHandler(null);
    await root.delete(recursive: true);
  });

  test('game title reaches the native menu without changing the image path', () async {
    final report = await DolphinInternalV2Service.launch(
      folderName: 'wii', gamePath: gamePath, gameTitle: '  Mario — Édition française  ',
    );
    expect(report.ready, isTrue);
    expect(nativeLaunchArguments?['gameTitle'], 'Mario — Édition française');
    expect(nativeLaunchArguments?['gamePath'], p.normalize(p.absolute(gamePath)));
    await notifyStopped(nativeToken);
    expect((await launch(() async {})).ready, isTrue);
    expect(nativeLaunchArguments?['gameTitle'], 'fixture');
    await notifyStopped(nativeToken);
  });

  test('only the active, flushed session triggers upload and only once', () async {
    var uploads = 0;
    expect((await launch(() async { uploads++; })).ready, isTrue);
    final token = nativeToken!;
    await notifyStopped('different-session');
    await notifyStopped(token, flushed: false);
    expect(uploads, 0);
    await notifyStopped(token);
    await notifyStopped(token);
    expect(uploads, 1);
  });

  test('a stale stop event cannot run the new session callback', () async {
    var first = 0;
    var second = 0;
    expect((await launch(() async { first++; })).ready, isTrue);
    final oldToken = nativeToken!;
    await notifyStopped(oldToken);
    expect((await launch(() async { second++; })).ready, isTrue);
    final newToken = nativeToken!;
    expect(newToken, isNot(oldToken));
    await notifyStopped(oldToken);
    expect(first, 1);
    expect(second, 0);
    await notifyStopped(newToken);
    expect(second, 1);
  });

  test('refused native launch never schedules a post-game upload', () async {
    launchAccepted = false;
    var uploads = 0;
    expect((await launch(() async { uploads++; })).ready, isFalse);
    await notifyStopped(nativeToken);
    expect(uploads, 0);
  });

  test('post-game sync errors release callback state for the next session', () async {
    var attempts = 0;
    expect((await launch(() async {
      attempts++;
      throw StateError('Simulated cloud unavailability');
    })).ready, isTrue);
    final oldToken = nativeToken!;
    await notifyStopped(oldToken);
    await notifyStopped(oldToken);
    expect(attempts, 1);
    expect((await launch(() async { attempts++; })).ready, isTrue);
    await notifyStopped(nativeToken);
    expect(attempts, 2);
  });

  test('a queued launch waits for the native-save transaction to finish', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final transaction = DolphinInternalV2Service.withSaveAccess((_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final nextLaunch = launch(() async {});
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call == 'launchGame'), isEmpty);
    release.complete();
    await transaction;
    expect((await nextLaunch).ready, isTrue);
    await notifyStopped(nativeToken);
  });
}
