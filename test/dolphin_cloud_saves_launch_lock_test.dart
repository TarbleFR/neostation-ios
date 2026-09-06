import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/services/dolphin_internal_v2_service.dart';
import 'package:neostation/services/dolphin_system_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const host = MethodChannel('neostation/dolphin_internal');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  Object? running = false;
  final calls = <String>[];

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('dolphin-cloud-saves-lock');
    messenger.setMockMethodCallHandler(paths, (call) async => root.path);
    messenger.setMockMethodCallHandler(host, (call) async {
      calls.add(call.method);
      if (call.method == 'isRunning') return running;
      if (call.method == 'saveIdentity') return {'system': 'gc', 'gameId': 'GMSE01', 'region': 'USA'};
      throw PlatformException(code: 'unexpectedNativeCall', message: call.method);
    });
  });
  setUp(() { running = false; calls.clear(); });
  tearDownAll(() async {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(host, null);
    await root.delete(recursive: true);
  });

  test('running or unknown native core refuses ALL save filesystem work', () async {
    for (final state in [true, null]) {
      running = state;
      var entered = false;
      await expectLater(DolphinInternalV2Service.withSaveAccess((_) async { entered = true; }), throwsA(isA<DolphinSystemFilesException>()));
      expect(entered, isFalse);
      expect(calls, everyElement('isRunning'));
    }
  });

  test('stopped engine can access saves without attaching JIT or starting emulation', () async {
    await DolphinInternalV2Service.withSaveAccess((store) async {
      expect(store.userDirectory.path, endsWith(p.join('NeoStation', 'Dolphin', 'User')));
      final library = await DolphinInternalV2Service.libraryDirectory('gc');
      final rom = await File(p.join(library.path, 'renamed.rvz')).writeAsString('DiscIO mocked metadata only');
      final identity = await DolphinInternalV2Service.readSaveIdentity('gc', rom.path);
      expect(identity.gameId, 'GMSE01');
    });
    expect(calls, ['isRunning', 'saveIdentity']);
  });

  test('concurrent save transactions are serialized and errors release the lock', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final order = <int>[];
    final one = DolphinInternalV2Service.withSaveAccess((_) async {
      order.add(1); entered.complete(); await release.future; order.add(2);
    });
    await entered.future;
    final two = DolphinInternalV2Service.withSaveAccess((_) async { order.add(3); });
    await Future<void>.delayed(Duration.zero);
    expect(order, [1]);
    release.complete(); await Future.wait([one, two]);
    expect(order, [1, 2, 3]);
    await expectLater(DolphinInternalV2Service.withSaveAccess((_) async => throw StateError('fixture')), throwsStateError);
    expect(await DolphinInternalV2Service.withSaveAccess((_) async => 42), 42);
  });

  test('a foreign system or ROM path cannot request Dolphin save identity', () async {
    await expectLater(DolphinInternalV2Service.readSaveIdentity('ps2', 'foreign.iso'), throwsArgumentError);
    final foreign = await File(p.join(root.path, 'foreign.iso')).writeAsString('not in internal library');
    await expectLater(DolphinInternalV2Service.readSaveIdentity('gc', foreign.path), throwsFormatException);
    expect(calls, isEmpty);
  });
}
