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

    test('distributed IPA does not force user-specific entitlements', () {
      final configurator = File(
        'build-utils/configure_rpcs3_ios_v2.py',
      ).readAsStringSync();
      for (final key in <String>[
        'get-task-allow',
        'com.apple.developer.kernel.extended-virtual-addressing',
        'com.apple.developer.kernel.increased-memory-limit',
        'com.apple.developer.kernel.increased-debugging-memory-limit',
      ]) {
        expect(configurator, contains(key));
      }
      expect(configurator, contains('payload.pop(key, None)'));
      expect(configurator, isNot(contains("payload['get-task-allow'] = True")));
    });
  });
}
