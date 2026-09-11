import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/rpcs3_internal_service.dart';
import 'package:neostation/widgets/rpcs3_internal_playlist_actions.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const core = MethodChannel('neostation/rpcs3_internal');
  const jit = MethodChannel('neostation/rpcs3_jit');
  late Directory support;
  late File versionFile;
  final nativeCalls = <String>[];

  setUp(() async {
    support = await Directory.systemTemp.createTemp('rpcs3-firmware-library-');
    versionFile = File(
      path.join(
        support.path,
        'NeoStation',
        'RPCS3',
        'Data',
        'dev_flash',
        'vsh',
        'etc',
        'version.txt',
      ),
    );
    nativeCalls.clear();
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(paths, (_) async => support.path);
    for (final channel in [core, jit]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add('${channel.name}/${call.method}');
        throw PlatformException(code: 'runtimeMustRemainDormant');
      });
    }
  });

  tearDown(() async {
    for (final channel in [paths, core, jit]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    await support.delete(recursive: true);
  });

  Future<void> writeVersion(String contents) async {
    await versionFile.parent.create(recursive: true);
    await versionFile.writeAsString(contents);
  }

  test(
    'recognizes a pre-existing firmware without a preference or Core',
    () async {
      await writeVersion('release:04.9100:\nbuild:50999,2025:');
      expect(await Rpcs3InternalService.firmwareVersion(), '4.91');
      expect(await Rpcs3InternalService.hasFirmware(), isTrue);
      expect(nativeCalls, isEmpty);
    },
  );

  test(
    'deletion and malformed metadata cannot reuse a stale installed flag',
    () async {
      SharedPreferences.setMockInitialValues({
        'rpcs3_internal_firmware_installed_v1': true,
        'rpcs3_internal_firmware_version_v1': '4.91',
      });
      expect(await Rpcs3InternalService.firmwareVersion(), isEmpty);
      await writeVersion('release:04.9000:\n');
      expect(await Rpcs3InternalService.firmwareVersion(), '4.90');
      await versionFile.delete();
      expect(await Rpcs3InternalService.hasFirmware(), isFalse);
      await writeVersion('release:broken:\n');
      expect(await Rpcs3InternalService.hasFirmware(), isFalse);
      expect(nativeCalls, isEmpty);
    },
  );

  Future<List<bool>> openLibrary(
    WidgetTester tester, {
    VoidCallback? onBack,
  }) async {
    final states = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ScreenUtil.init(context, designSize: const Size(800, 600));
            return Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(
                    child: Rpcs3InternalPlaylistActions(
                      onLibraryChanged: () async {},
                      onFirmwareChanged: states.add,
                      onBack: onBack ?? () {},
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    // Filesystem callbacks run on the real event loop, while widget callbacks
    // need the test clock to pump. Waiting on one completer inside runAsync
    // starves the fake microtask queue and cannot finish the firmware check.
    for (var frame = 0; states.isEmpty && frame < 200; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(states, isNotEmpty, reason: 'The firmware check must finish');
    await tester.pumpAndSettle();
    return states;
  }

  testWidgets(
    'missing firmware shows install screen immediately and can go back',
    (tester) async {
      var backedOut = false;
      final states = await openLibrary(tester, onBack: () => backedOut = true);
      expect(states, [false]);
      expect(find.text('PS3 firmware required'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('rpcs3-library-install-firmware')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('rpcs3-internal-import-menu')),
        findsNothing,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('Back'));
      expect(backedOut, isTrue);
      expect(nativeCalls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'installed firmware opens import menu directly, including on reopening',
    (tester) async {
      await tester.runAsync(() => writeVersion('release:04.9100:\n'));
      for (var opening = 0; opening < 2; opening++) {
        expect(await openLibrary(tester), [true]);
        expect(
          find.byKey(const ValueKey('rpcs3-library-firmware-gate')),
          findsNothing,
        );
        await tester.tap(
          find.byKey(const ValueKey('rpcs3-internal-import-menu')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Import games'), findsOneWidget);
        expect(find.text('Import decrypted game folder'), findsOneWidget);
        expect(find.text('Import PS3 firmware'), findsOneWidget);
        expect(find.text('Export save data'), findsOneWidget);
        expect(nativeCalls, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('a removed firmware brings back the gate on the next opening', (
    tester,
  ) async {
    await tester.runAsync(() => writeVersion('release:04.9100:\n'));
    expect(await openLibrary(tester), [true]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => versionFile.delete());
    expect(await openLibrary(tester), [false]);
    expect(find.text('PS3 firmware required'), findsOneWidget);
    expect(nativeCalls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
