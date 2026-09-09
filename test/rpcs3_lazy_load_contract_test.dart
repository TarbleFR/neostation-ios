import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RPCS3 lazy runtime contract', () {
    test('RPCS3 Core is not a CocoaPods vendored library', () {
      final podspec = File(
        'packages/rpcs3_internal_bridge/ios/rpcs3_internal_bridge.podspec',
      ).readAsStringSync();
      expect(podspec, isNot(contains('s.vendored_libraries')));
      expect(
        podspec,
        contains("s.preserve_paths   = 'Frameworks/libRPCS3Core.dylib'"),
      );
    });

    test('RPCS3 Core is opened only by the native bridge', () {
      final plugin = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
      ).readAsStringSync();
      expect(plugin, contains('dlopen('));
      expect(plugin, contains('libRPCS3Core.dylib'));
      expect(plugin, contains('RTLD_NOW | RTLD_LOCAL'));
    });

    test('embedded RPCS3 relies on NeoStation host process capabilities', () {
      final plugin = File(
        'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
      ).readAsStringSync();
      expect(plugin, contains('SecTaskCreateFromSelf'));
      expect(plugin, contains('RPCS3ProbeExecutableMemory'));
      expect(
        plugin,
        isNot(
          contains(
            'RPCS3 requires extended-virtual-addressing and increased-memory-limit entitlements in the signed NeoStation IPA.',
          ),
        ),
      );
      expect(
        plugin,
        contains('libRPCS3Core.dylib is loaded into NeoStation itself'),
      );
    });

    test('opening the PS3 import menu does not initialize RPCS3', () {
      final widget = File(
        'lib/widgets/rpcs3_internal_playlist_actions.dart',
      ).readAsStringSync();
      final start = widget.indexOf('Future<void> _opened() async');
      final end = widget.indexOf('void _notice', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final opened = widget.substring(start, end);
      expect(opened, isNot(contains('Rpcs3InternalService')));
      expect(opened, isNot(contains('hasFirmware')));
    });

    test('PS3 library performs firmware-first onboarding', () {
      final widget = File(
        'lib/widgets/rpcs3_internal_playlist_actions.dart',
      ).readAsStringSync();
      expect(widget, contains('rpcs3-library-firmware-gate'));
      expect(widget, isNot(contains('SharedPreferences')));
      expect(widget, contains('WidgetsBinding.instance.addPostFrameCallback'));
      expect(widget, contains('Rpcs3InternalService.firmwareVersion()'));
      expect(widget, contains('Rpcs3InternalService.importFirmware()'));
    });

    test('PS3 empty library does not expose recursive ROM scanning', () {
      final library = File(
        'lib/screens/game_screen/my_games_list.dart',
      ).readAsStringSync();
      expect(
        library,
        contains(
          "Platform.isIOS && widget.system.folderName.toLowerCase() == 'ps3'",
        ),
      );
      expect(library, contains('if (!isRpcs3Library)'));
    });

    test('distributed signing sidecar declares RPCS3 runtime entitlements', () {
      final configurator = File(
        'build-utils/configure_rpcs3_ios_v2.py',
      ).readAsStringSync();
      for (final key in <String>[
        'get-task-allow',
        'com.apple.developer.kernel.extended-virtual-addressing',
        'com.apple.developer.kernel.increased-memory-limit',
        'com.apple.developer.kernel.increased-debugging-memory-limit',
      ]) {
        expect(configurator, contains("'$key': True"));
      }
      expect(
        configurator,
        contains('payload.update(REQUIRED_RUNTIME_ENTITLEMENTS)'),
      );
      expect(configurator, isNot(contains('payload.pop(key, None)')));
    });
  });
}
