import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:armsx2_internal_bridge/armsx2_internal_bridge.dart';
import 'package:neostation/services/armsx2_bios_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SharedPreferences prefs;
  late Armsx2BiosStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    root = await Directory.systemTemp.createTemp('armsx2-bios-');
    store = Armsx2BiosStore(root, prefs);
    // These are storage fixtures, not firmware dumps; the Core validates BIOS.
    await File('${root.path}/A-Japan.bin').writeAsBytes([1, 2]);
    await File('${root.path}/B-Europe.bin').writeAsBytes([3, 4]);
    await File('${root.path}/B-Europe.nvm').writeAsBytes([5, 6]);
  });
  tearDown(() async => root.delete(recursive: true));

  test('multiple imports are listed; NVRAM is never a boot candidate', () async {
    expect((await store.list()).map((bios) => bios.filename),
        ['A-Japan.bin', 'B-Europe.bin']);
    expect(await store.resolve(), isNull);
  });
  test('explicit Europe selection survives reopening and is not alphabetical', () async {
    await store.select('B-Europe.bin');
    expect(await Armsx2BiosStore(root, prefs).resolve(), 'B-Europe.bin');
    expect(prefs.getString(Armsx2BiosStore.preferenceKey), 'B-Europe.bin');
    expect(await File('${root.path}/B-Europe.nvm').readAsBytes(), [5, 6]);
  });
  test('removing the selected firmware cannot fall back to Japanese BIOS', () async {
    await store.select('B-Europe.bin');
    await File('${root.path}/B-Europe.bin').delete();
    await expectLater(store.resolve(), throwsA(isA<FileSystemException>()));
    expect(store.selectedFilename, 'B-Europe.bin');
  });
  test('basename selection survives a container relocation', () async {
    await store.select('B-Europe.bin');
    final moved = Directory('${root.path}/new-container');
    await moved.create();
    await File('${root.path}/B-Europe.bin').copy('${moved.path}/B-Europe.bin');
    expect(await Armsx2BiosStore(moved, prefs).resolve(), 'B-Europe.bin');
  });
  test('invalid paths and companion files do not overwrite a valid choice', () async {
    await store.select('B-Europe.bin');
    for (final name in ['../A-Japan.bin', '/tmp/bios.bin', 'x\\bios.bin', 'B-Europe.nvm']) {
      await expectLater(store.select(name), throwsFormatException);
    }
    expect(await store.resolve(), 'B-Europe.bin');
  });
  test('the native channel receives the same selected BIOS for both boot modes', () async {
    await store.select('B-Europe.bin');
    const channel = MethodChannel('neostation/armsx2_internal');
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return <String, dynamic>{'success': true};
    });
    try {
      for (final biosBoot in [false, true]) {
        await Armsx2InternalBridge.launch(
          transaction: biosBoot ? 2 : 1,
          gamePath: biosBoot ? '' : '/Games/example.iso',
          dataPath: '/ARMSX2',
          biosDirectory: '/ARMSX2/BIOS',
          biosFilename: await store.resolve(),
          bootBios: biosBoot,
        );
      }
      expect(calls.map((call) => call.arguments['biosFilename']),
          ['B-Europe.bin', 'B-Europe.bin']);
      expect(calls.map((call) => call.arguments['bootBios']), [false, true]);
      expect(calls.last.arguments['gamePath'], '');
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
  test('games and BIOS boot share one explicit selected filename before JIT', () {
    final launch = File('lib/services/stikjit_armsx2_service.dart').readAsStringSync();
    expect(launch, contains('biosFilename: biosFilename'));
    expect(launch.indexOf('biosStore.resolve()'), lessThan(launch.indexOf('prepareJit(')));
    expect(launch, contains('_launchTransaction(gamePath: gamePath, bootBios: false, uiLocale: uiLocale)'));
    expect(launch, contains("_launchTransaction(gamePath: '', bootBios: true, uiLocale: uiLocale)"));
  });
}
